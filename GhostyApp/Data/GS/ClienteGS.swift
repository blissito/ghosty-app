import Foundation

/// El transporte contra gs: HTTP para pedir, SSE para escuchar.
///
/// ⚠️ La diferencia con el WebSocket no es de tuberías, es de **quién es dueño del
/// trabajo**. Por socket el turno es del teléfono: medido contra la caja real el
/// 2026-09-10, cortar el socket a los 3 s de mandar y volver 25 s después devuelve CERO
/// caracteres —la caída del cliente cierra el socket hacia el motor y cancela el turno—.
/// Aquí el turno vive en gs, en su propia tarea, y el SSE es **re-suscribible**: al
/// conectarse manda primero todo lo que ya emitió y luego el directo. Irte deja de costar
/// el trabajo.
///
/// ⚠️ Lo que NO da: el backlog de un turno terminado se retiene unos minutos y vive en la
/// memoria de gs. Para «me fui una hora» lo correcto es pedir el hilo (`cargar`), no
/// confiar en el backlog.
actor ClienteGS: TransporteDeAgente {
    private let agentID: String
    /// Cuántos mensajes se piden al recuperar un hilo. La cola es lo que se lee al volver.
    private static let cola = 60

    init(agentID: String) {
        self.agentID = agentID
    }

    // MARK: - Fontanería

    /// ⚠️ Sesión propia y con las mismas curas que el SSE de EasyBits, que ya costaron una
    /// tarde: `identity` para que nadie comprima el flujo por trozos, y timeouts largos
    /// porque un turno puede tardar minutos y `URLSession` corta por su cuenta.
    private static let sesion: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 3600
        c.waitsForConnectivity = true
        c.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        return URLSession(configuration: c)
    }()

    private func base(_ sufijo: String) -> URL {
        Session.base.appendingPathComponent("api/v2/me/agents/\(agentID)\(sufijo)")
    }

    private func peticion(_ url: URL, metodo: String = "GET",
                          cuerpo: [String: Any]? = nil,
                          sse: Bool = false) async throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = metodo
        // ⚠️ El token se pide en CADA llamada, no se guarda: `Session.accessToken()` lo
        // refresca si caducó. Ningún cliente de esta app lo hacía —ver el aviso de
        // `Session.swift`— y una sesión caducada se veía como "el agente no contesta".
        r.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        // HTTP/3 fuera: por QUIC el cuerpo de un SSE puede no entregarse por trozos y el
        // turno se queda colgado SIN error. Ya mordió en dos clientes de este repo.
        r.assumesHTTP3Capable = false
        if sse { r.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        if let cuerpo {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: cuerpo)
        }
        return r
    }

    @discardableResult
    private func pedir(_ url: URL, metodo: String = "GET",
                       cuerpo: [String: Any]? = nil) async throws -> [String: Any] {
        let (d, resp) = try await Self.sesion.data(for: try await peticion(url, metodo: metodo, cuerpo: cuerpo))
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(codigo) else {
            throw ACPClient.Fallo.remoto(mensajeDeError(d, codigo))
        }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    /// Lo que se le enseña a una persona cuando el servidor dice que no.
    private func mensajeDeError(_ d: Data, _ codigo: Int) -> String {
        let cuerpo = String(decoding: d, as: UTF8.self).prefix(300)
        switch codigo {
        case 401, 403: return "Hay que volver a entrar a tu cuenta."
        case 404:      return "Ese agente o esa conversación ya no existe."
        case 409:      return "Ese agente no es de los que hablan por aquí."
        case 429:      return "Se acabó el cupo de turnos por ahora."
        default:       return cuerpo.isEmpty ? "El servidor contestó \(codigo)." : String(cuerpo)
        }
    }

    // MARK: - Conexión

    /// No hay socket que abrir: se comprueba que el agente responde y ya.
    @discardableResult
    func conectar() async throws -> String {
        _ = try await pedir(base("/conversations"))
        return "gs"
    }

    /// No hay nada que cerrar: cada llamada es su propia conexión. El turno sigue en gs,
    /// que es justo el punto de todo esto.
    func cerrar() {
        escuchas.values.forEach { $0.cancel() }
        escuchas.removeAll()
    }

    // MARK: - Conversaciones

    func sesiones() async throws -> [ACPClient.Session] {
        let r = try await pedir(base("/conversations"))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        return (r["conversaciones"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            let f = (c["actualizada"] as? String).flatMap { iso.date(from: $0) ?? iso2.date(from: $0) }
            return ACPClient.Session(id: id, title: c["titulo"] as? String ?? "Conversación",
                                     cwd: "/data/work", updatedAt: f, messageCount: nil)
        }
    }

    func nuevaSesion(cwd: String) async throws -> (id: String, modos: ACPClient.Modos?) {
        let r = try await pedir(base("/conversations"), metodo: "POST", cuerpo: [:])
        guard let id = r["id"] as? String else {
            throw ACPClient.Fallo.handshake("el servidor no devolvió la conversación")
        }
        // Los modos son cosa del socket: aquí el permiso se pide por turno.
        return (id, nil)
    }

    /// El hilo, por su cola.
    ///
    /// ⚠️ Devuelve `nil` si esa conversación está contestando ahora mismo: pisar un turno
    /// vivo con lo que había antes es el fallo que dejó conversaciones en blanco.
    func cargar(_ id: String, cwd: String) async throws -> [ACPClient.Replay]? {
        guard escuchas[id] == nil else { return nil }
        var c = URLComponents(url: base("/conversations/\(id)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "tail", value: "\(Self.cola)")]
        let r = try await pedir(c.url!)
        saltados[id] = r["saltados"] as? Int ?? 0
        return (r["messages"] as? [[String: Any]] ?? []).compactMap { m in
            guard let t = m["text"] as? String, !t.isEmpty else { return nil }
            return m["role"] as? String == "user" ? .user(t) : .agent(t)
        }
    }

    /// Cuántos mensajes quedaron atrás en el último `cargar`. Es lo que permite ofrecer
    /// «ver lo anterior» en vez de fingir que la conversación empieza ahí.
    private(set) var saltados: [String: Int] = [:]

    func borrarSesion(_ id: String) async throws {
        // Archiva, no borra: la memoria del hilo sigue en la caja y es reversible.
        _ = try await pedir(base("/conversations/\(id)"), metodo: "DELETE")
    }

    func fijarModo(_ modo: String, sessionID: String) async throws {
        // El modo no se fija por conversación: el permiso se pide turno a turno.
    }

    func cancelar(_ sessionID: String) async {
        _ = try? await pedir(base("/conversations/\(sessionID)/cancel"), metodo: "POST", cuerpo: [:])
    }

    func responderPermiso(_ id: String, opcion: String) async throws {
        _ = try await pedir(base("/conversations/\(sessionID(dePermiso: id))/permission"),
                            metodo: "POST", cuerpo: ["id": id, "optionId": opcion])
    }

    /// En qué conversación se pidió cada permiso, para saber a qué ruta contestar.
    private var conversacionDelPermiso: [String: String] = [:]
    private func sessionID(dePermiso id: String) -> String {
        conversacionDelPermiso[id] ?? ""
    }

    // MARK: - El turno

    /// Las escuchas SSE vivas, por conversación.
    private var escuchas: [String: Task<Void, Never>] = [:]
    var turnosVivos: Int { escuchas.count }

    private var permisoPendiente: (@Sendable (ACPClient.Permiso) -> Void)?
    func alPedirPermiso(_ handler: @escaping @Sendable (ACPClient.Permiso) -> Void) {
        permisoPendiente = handler
    }

    private var alCaerse: (@Sendable () -> Void)?
    func alPerderse(_ handler: @escaping @Sendable () -> Void) { alCaerse = handler }

    /// Manda el turno y escucha lo que gs vaya emitiendo.
    ///
    /// ⚠️ Son DOS operaciones y el ORDEN importa: primero se encarga el turno y **después**
    /// se escucha. Lo hice al revés —para no perderme nada— y el turno salía «cerró sin
    /// texto» siempre: quien se suscribe a una conversación en reposo recibe un `done` de
    /// entrada, porque eso es justo lo que necesita saber un cliente que llega nuevo. Ese
    /// `done` no era el mío, pero cerraba mi flujo antes de empezar.
    ///
    /// Escuchar después no pierde nada: el SSE es re-suscribible y entrega primero todo lo
    /// que el turno ya emitió. Ésa es la propiedad por la que se hizo esta mudanza.
    nonisolated func prompt(sessionID: String, texto: String,
                            adjuntos: [Adjunto]) -> AsyncThrowingStream<ACPClient.Replay, Error> {
        AsyncThrowingStream { cont in
            let tarea = Task {
                do {
                    try await self.encargar(sessionID, texto: texto, adjuntos: adjuntos)
                    try await self.escuchar(sessionID, cont)
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { motivo in
                tarea.cancel()
                Task { await self.dejarDeEscuchar(sessionID) }
                // Cancelar de verdad: irse de la pantalla no para el turno, pero pulsar
                // «detener» sí — y eso lo dice el motivo, no el que cierra el flujo.
                guard case .cancelled = motivo else { return }
                Task { await self.cancelar(sessionID) }
            }
        }
    }

    /// Engancharse a lo que ya esté pasando en esa conversación.
    ///
    /// Si no hay turno vivo, gs manda `done` de entrada y el flujo se cierra solo: quien
    /// llama no tiene que preguntar primero si hay algo. Si lo hay, llega el backlog
    /// —todo lo que el turno emitió mientras no mirábamos— y después el directo.
    nonisolated func seguir(sessionID: String) -> AsyncThrowingStream<ACPClient.Replay, Error>? {
        AsyncThrowingStream { cont in
            let tarea = Task {
                do { try await self.escuchar(sessionID, cont) }
                catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in
                tarea.cancel()
                // ⚠️ Irse de una conversación NO cancela su turno: eso es justo lo que se
                // gana con este transporte. Sólo se deja de escuchar.
                Task { await self.dejarDeEscuchar(sessionID) }
            }
        }
    }

    private func dejarDeEscuchar(_ sesion: String) {
        escuchas[sesion]?.cancel()
        escuchas[sesion] = nil
    }

    private func encargar(_ sesion: String, texto: String, adjuntos: [Adjunto]) async throws {
        // ⚠️ Los adjuntos van en base64 y gs decide qué entra inline y qué se le entrega
        // al agente como URL con su comando (`attachments.server.ts`). Es lo mismo que
        // hacía `BloqueDeAdjuntos` en el teléfono, pero del lado que conoce a la caja.
        let archivos: [[String: Any]] = adjuntos.map { a in
            var d: [String: Any] = ["name": a.nombre, "mimeType": a.mime,
                                    "data": a.datos.base64EncodedString()]
            if let url = a.remoto?.url { d["uri"] = url }
            return d
        }
        var cuerpo: [String: Any] = ["content": texto]
        if !archivos.isEmpty { cuerpo["images"] = archivos }
        // Se pide `preguntar` porque esta app SÍ sabe pintar la tarjeta y contestarla. Un
        // cliente que lo pida sin poder contestar deja el turno detenido diez minutos.
        cuerpo["permisos"] = "preguntar"
        let r = try await pedir(base("/conversations/\(sesion)/messages"), metodo: "POST", cuerpo: cuerpo)
        EasyBitsClient.diag("[gs] turno encargado \(sesion): \(r["turnId"] as? String ?? "?") estado=\(r["estado"] as? String ?? "?")")
    }

    /// Abre el SSE y traduce lo que llega.
    private func escuchar(_ sesion: String, _ cont: AsyncThrowingStream<ACPClient.Replay, Error>.Continuation) async throws {
        dejarDeEscuchar(sesion)
        let req = try await peticion(base("/conversations/\(sesion)/events"), sse: true)
        let listo = Semaforo()
        escuchas[sesion] = Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, resp) = try await Self.sesion.bytes(for: req)
                let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard codigo == 200 else {
                    await listo.abrir()
                    cont.finish(throwing: ACPClient.Fallo.remoto("El servidor contestó \(codigo) al escuchar."))
                    return
                }
                await listo.abrir()
                var evento = ""
                for try await linea in bytes.lines {
                    if Task.isCancelled { break }
                    if linea.hasPrefix("event: ") { evento = String(linea.dropFirst(7)); continue }
                    guard linea.hasPrefix("data: ") else { continue }
                    let crudo = String(linea.dropFirst(6))
                    if await self.traducir(evento, crudo, sesion: sesion, cont) { break }
                }
                cont.finish()
                await self.soltar(sesion)
            } catch {
                await listo.abrir()
                cont.finish(throwing: error)
                await self.soltar(sesion)
            }
        }
        // No se vuelve hasta que el SSE está de verdad abierto, para que quien llame sepa
        // que ya hay quien escuche.
        await listo.esperar()
    }

    private func soltar(_ sesion: String) { escuchas[sesion] = nil }

    /// Traduce un evento de gs. Devuelve `true` si el turno terminó.
    private func traducir(_ evento: String, _ crudo: String, sesion: String,
                          _ cont: AsyncThrowingStream<ACPClient.Replay, Error>.Continuation) -> Bool {
        let p = (try? JSONSerialization.jsonObject(with: Data(crudo.utf8))) as? [String: Any] ?? [:]
        switch evento {
        case "chunk":
            if let t = p["text"] as? String, !t.isEmpty { cont.yield(.agent(t)) }
        case "thought":
            if let t = p["text"] as? String, !t.isEmpty { cont.yield(.thought(t)) }
        case "tool":
            if let id = p["id"] as? String {
                cont.yield(.tool(ACPClient.herramienta([
                    "title": p["title"] as Any, "kind": p["kind"] as Any,
                    "status": p["status"] as Any, "locations": p["path"].map { [["path": $0]] } as Any,
                ], id: id)))
            }
        case "artifact":
            // ⚠️ El payload viene TAL CUAL lo emite el relé, sin normalizar: si gs lo
            // tradujera habría que tocarlo cada vez que el MCP aprenda una forma nueva, y
            // mientras tanto la entrega se perdería en silencio. `entregaDesde` ya es
            // tolerante, que es justo lo que hace falta aquí.
            if let e = ACPClient.entregaDesde(p, agentID: agentID) {
                var entrega = e
                entrega.sesionID = p["sessionId"] as? String ?? sesion
                cont.yield(.entrega(entrega))
            }
        case "usage":
            // ⚠️ SÓLO si vienen los de entrada/salida. `used`/`size` son el acumulado de
            // la sesión contra el límite del modelo, y tras una compactación `used` puede
            // pasarse de `size`: pintarlo como si fueran tokens del turno es lo que puso
            // «14xxk» en pantalla. Si la caja no los sabe, gs los OMITE — así que aquí se
            // distingue «cero» de «no lo sé», y ante «no lo sé» no se pinta nada.
            if let i = p["input"] as? Int, let o = p["output"] as? Int {
                cont.yield(.usage(input: i, output: o))
            }
        case "permission":
            if let id = p["id"] as? String {
                conversacionDelPermiso[id] = sesion
                let opciones = (p["options"] as? [[String: Any]] ?? []).compactMap { o -> (String, String, String)? in
                    guard let oid = o["optionId"] as? String else { return nil }
                    return (oid, o["name"] as? String ?? oid, o["kind"] as? String ?? "")
                }
                permisoPendiente?(ACPClient.Permiso(
                    id: id, sessionID: sesion,
                    titulo: p["title"] as? String ?? "una herramienta",
                    herramienta: p["tool"] as? String ?? "",
                    opciones: opciones))
            }
        case "permission-resolved":
            if let id = p["id"] as? String { conversacionDelPermiso[id] = nil }
        case "error":
            cont.finish(throwing: ACPClient.Fallo.remoto(p["message"] as? String ?? "Falló el turno."))
            return true
        case "done":
            return true
        default:
            // `title`, `caps`, `status`, `models`… todavía no se usan. No se tiran a la
            // basura en silencio: que aparezca uno nuevo tiene que poder verse.
            EasyBitsClient.diag("[gs] evento sin usar: \(evento)")
        }
        return false
    }
}

/// Una espera de un solo uso. Sirve para no encargar el turno antes de estar escuchando.
private actor Semaforo {
    private var abierto = false
    private var esperando: [CheckedContinuation<Void, Never>] = []

    func abrir() {
        guard !abierto else { return }
        abierto = true
        esperando.forEach { $0.resume() }
        esperando = []
    }

    func esperar() async {
        if abierto { return }
        await withCheckedContinuation { esperando.append($0) }
    }
}
