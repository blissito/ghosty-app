import Foundation

/// Cliente ACP por WebSocket contra la caja del agente.
///
/// Convive con el HTTP de EasyBits en vez de reemplazarlo, y es a propósito:
/// `POST /agents/:id/message` **despierta la caja** si el reaper la suspendió y la
/// marca ocupada para que no la duerman a media respuesta. Un WebSocket no hace nada
/// de eso. Así que el turno sigue yendo por HTTP y esto sirve para lo que HTTP no
/// puede: `session/list`, `session/load` y las peticiones que el agente hace al
/// cliente.
///
/// Verificado contra la caja real (`ghosty-lite 1.48.0`): declara
/// `loadSession: true` y `sessionCapabilities: { list, delete, close }`.
actor ACPClient {

    struct Session: Identifiable, Sendable, Equatable {
        let id: String            // sessionId
        var title: String
        var cwd: String
        var updatedAt: Date?
        var messageCount: Int?
    }

    /// Modo de la sesión. `session/new` los devuelve: `auto` aprueba las herramientas
    /// solo; `approve` hace que el agente PIDA permiso, que es lo que enciende la
    /// tarjeta de permisos.
    struct Modos: Sendable, Equatable {
        var actual: String
        var disponibles: [(id: String, nombre: String, descripcion: String)]

        static func == (a: Modos, b: Modos) -> Bool {
            a.actual == b.actual && a.disponibles.map(\.id) == b.disponibles.map(\.id)
        }
    }

    /// Una petición de permiso del agente AL cliente. Hay que contestarla o el turno
    /// se queda esperando.
    struct Permiso: Sendable, Identifiable {
        let id: Int              // el id JSON-RPC con el que hay que responder
        let sessionID: String
        let titulo: String
        let herramienta: String
        /// Las opciones que ofrece el agente, con su `optionId` real.
        var opciones: [(id: String, nombre: String, tipo: String)]
    }

    /// Lo que trae el replay de `session/load`. Los `*_chunk` llegan **partidos**, así
    /// que hay que pegarlos por turno antes de mostrarlos.
    enum Replay: Sendable {
        case user(String)
        case agent(String)
        case thought(String)
        /// Una herramienta que empieza o que cambia. Llega varias veces por la misma:
        /// ACP manda `tool_call` al crearla y `tool_call_update` cada vez que avanza.
        case tool(Herramienta)
        /// El agente entregó algo: un archivo suyo o un artefacto que escribió.
        case entrega(Entrega)
        /// Lo que costó el turno. Llega UNA vez, al cerrar.
        ///
        /// ⚠️ Sale de la RESPUESTA de `session/prompt`, no de una notificación: el agente
        /// manda `usage_update` mientras trabaja, pero el número bueno —el acumulado del
        /// turno— viene con el `stopReason`. Antes esa respuesta se descartaba con un
        /// `_ =`, así que el panel de actividad decía **0 tokens** para siempre por más
        /// turnos que se hicieran.
        case usage(input: Int, output: Int)
    }

    enum Fallo: LocalizedError {
        case noConectado
        case timeout(String)
        case remoto(String)
        case handshake(String)

        var errorDescription: String? {
            switch self {
            case .noConectado:      return "No hay conexión con tu agente."
            case .timeout(let m):   return "Tu agente no contestó a \(m)."
            case .remoto(let m):    return m
            case .handshake(let m): return "No pude abrir la sesión: \(m)"
            }
        }
    }

    private let agentID: String
    private let token: String
    /// Host de la caja tal como lo da el servidor. `nil` = derivarlo del id.
    private let host: String?
    private var tarea: URLSessionWebSocketTask?
    private var lector: Task<Void, Never>?
    private var siguienteID = 0
    private var pendientes: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    /// Respuestas que llegaron ANTES de que su continuación existiera.
    ///
    /// ⚠️ Con una petición a la vez esto no se notaba; con varias es un cuelgue seguro.
    /// `pedir` manda y sólo DESPUÉS registra su continuación —entre las dos cosas hay un
    /// `await`, así que el actor puede atender al lector—, y una caja rápida contesta en
    /// ese hueco. La respuesta no encontraba a nadie y se tiraba: la petición esperaba al
    /// reloj para morir de timeout, con la caja habiendo contestado bien.
    private var buzon: [Int: Result<[String: Any], Error>] = [:]
    /// Las notificaciones del replay, POR HILO: se puede estar cargando uno mientras
    /// otro contesta.
    private var replayEnCurso: [String: [Replay]] = [:]
    /// Por dónde salen los eventos de cada turno en vuelo, POR HILO.
    ///
    /// ⚠️ Esto era **una sola** continuación y un solo flag de replay, y ahí estaba el
    /// fallo más grave que ha tenido la app: `session/update` trae `sessionId` y se
    /// **ignoraba**, así que todo evento que llegaba se volcaba en el flujo que hubiera
    /// abierto. Cargar un hilo mientras otro contestaba metía la respuesta del segundo
    /// dentro del primero — dos conversaciones distintas cosidas en pantalla, sin que
    /// nada lo dijera.
    private var enVivo: [String: AsyncStream<Replay>.Continuation] = [:]
    /// Los permisos que el agente pidió y nadie ha contestado.
    private var permisoPendiente: ((Permiso) -> Void)?

    /// ⚠️ COMPARTIDA por todos los clientes. Era una por instancia y **nadie la
    /// invalidaba**: una `URLSession` viva retiene sus tareas, así que cada reconexión
    /// dejaba una sesión colgada. Compartida no hay nada que invalidar, y la configuración
    /// es idéntica para todos.
    private static let sesion: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    init(agentID: String, token: String, host: String? = nil) {
        self.agentID = agentID
        self.token = token
        self.host = host
    }

    var url: URL {
        // El dominio es fijo por agente y el router del host lo sigue de caja en
        // caja, así que sobrevive a que la recreen.
        //
        // El host lo manda el servidor cuando lo sabe (`/api/v2/me/agents`). El
        // derivado se queda como respaldo para lo conectado a mano: cablearlo como
        // único camino ataría la app a UN dominio de cajas, y ya hay dos fierros.
        // ⚠️ `?tools=1` no es opcional: es lo que hace que el relé le monte al agente el
        // servidor MCP de Ghosty, o sea `entregar_archivo` y `crear_artefacto`. Sin eso el
        // agente escribe en el disco de su máquina y no tiene forma de hacerte llegar
        // nada — se limita a describir lo que hizo. Comprobado contra la caja: con la
        // bandera, entregar un artefacto llega como `ghosty/artifact` por este socket.
        URL(string: "wss://\(host ?? "acp-\(agentID).sandboxes.easybits.cloud")/acp?tools=1")!
    }

    // MARK: - Conexión

    /// Abre el socket y hace `initialize`. Devuelve el nombre y versión del agente.
    @discardableResult
    func conectar() async throws -> String {
        if tarea != nil { cerrar() }

        var req = URLRequest(url: url)
        // ⚠️ HTTP/3 APAGADO, y no es paranoia: `EasyBitsClient` ya lleva esta misma línea
        // porque QUIC mataba el SSE en silencio. Aquí es peor — un WebSocket sobre HTTP/3
        // necesita CONNECT extendido, y si el proxy no lo soporta iOS aborta el socket con
        // «Software caused connection abort», SIEMPRE y sólo en el teléfono: desde una Mac
        // con un cliente que no habla HTTP/3 la misma URL conecta a la primera, así que
        // parece un problema del servidor cuando es de transporte.
        req.assumesHTTP3Capable = false
        // El token del agente vale como Bearer tal cual: no hace falta ticket firmado
        // ni el secreto de la plataforma. Vale igual para un `agt_` de EasyBits que
        // para el `gat_` de un agente nativo. Comprobado contra la caja.
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let t = Self.sesion.webSocketTask(with: req)
        tarea = t
        t.resume()
        arrancarLector()

        let r = try await pedir("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
        ])
        let info = r["agentInfo"] as? [String: Any]
        let nombre = info?["name"] as? String ?? "agente"
        let version = info?["version"] as? String ?? "?"
        return "\(nombre) \(version)"
    }

    func cerrar() {
        lector?.cancel(); lector = nil
        tarea?.cancel(with: .goingAway, reason: nil); tarea = nil
        for (_, c) in pendientes { c.resume(throwing: Fallo.noConectado) }
        pendientes.removeAll()
        buzon.removeAll()
        // ⚠️ Los turnos en vuelo TAMBIÉN se cierran. Sin esto, cerrar el socket dejaba
        // sus flujos colgados y quien los estuviera leyendo esperaba para siempre.
        for (_, c) in enVivo { c.finish() }
        enVivo.removeAll()
        replayEnCurso.removeAll()
    }

    // MARK: - Sesiones

    func sesiones() async throws -> [Session] {
        let r = try await pedir("session/list", [:])
        let crudas = r["sessions"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()

        return crudas.compactMap { s in
            guard let id = s["sessionId"] as? String else { return nil }
            let meta = s["_meta"] as? [String: Any]
            let fecha = (s["updatedAt"] as? String).flatMap { iso.date(from: $0) ?? iso2.date(from: $0) }
            return Session(
                id: id,
                title: (s["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Sin título",
                cwd: s["cwd"] as? String ?? "/data/work",
                updatedAt: fecha,
                messageCount: meta?["messageCount"] as? Int
            )
        }
        .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// Carga un hilo y devuelve su replay. La caja lo manda como notificaciones
    /// `session/update` **antes** de contestar la petición, así que hay que
    /// capturarlas mientras la llamada está en vuelo.
    /// ⚠️ `nil` si ese hilo está contestando AHORA. El replay llega por el mismo
    /// `session/update` que el streaming, así que recargar el hilo vivo le inyectaría la
    /// conversación entera dentro del turno en curso. Quien llama ya tiene sus mensajes en
    /// memoria: lo correcto es cambiar de hilo sin recargar.
    func cargar(_ id: String, cwd: String) async throws -> [Replay]? {
        guard enVivo[id] == nil else { return nil }
        replayEnCurso[id] = []
        defer { replayEnCurso[id] = nil }
        _ = try await pedir("session/load",
                            ["sessionId": id, "cwd": cwd, "mcpServers": []],
                            timeout: 90)
        return replayEnCurso[id] ?? []
    }

    // MARK: - Turno

    /// Crea un hilo nuevo. **Por HTTP esto no se puede**: EasyBits siempre usa la
    /// única sesión ACP del agente, así que "nueva conversación" apendaba a la misma.
    func nuevaSesion(cwd: String = "/data/work") async throws -> (id: String, modos: Modos?) {
        let r = try await pedir("session/new", ["cwd": cwd, "mcpServers": []], timeout: 60)
        guard let id = r["sessionId"] as? String else { throw Fallo.handshake("sin sessionId") }
        return (id, leerModos(r["modes"]))
    }

    /// Pide al agente que PIDA permiso antes de usar herramientas. Sin esto el modo
    /// es `auto` y nunca llega un `session/request_permission`.
    func fijarModo(_ modo: String, sessionID: String) async throws {
        _ = try await pedir("session/set_mode", ["sessionId": sessionID, "modeId": modo])
    }

    /// Manda un turno y va soltando lo que llega. El `stopReason` cierra el flujo.
    nonisolated func prompt(sessionID: String, texto: String,
                            adjuntos: [Adjunto] = []) -> AsyncThrowingStream<Replay, Error> {
        AsyncThrowingStream { cont in
            let tarea = Task {
                let (flujo, sink) = AsyncStream<Replay>.makeStream()
                await self.abrirEnVivo(sink, hilo: sessionID)
                let bombeo = Task { for await e in flujo { cont.yield(e) } }
                do {
                    // El orden es el de Teams y no es casual: primero las imágenes (que
                    // el modelo VE), después el bloque que dice cómo abrir los archivos, y
                    // el mensaje de la persona AL FINAL y solo en su bloque — es lo único
                    // que escribió un humano.
                    var bloques: [[String: Any]] = []
                    var lineas: [String] = []
                    for a in adjuntos {
                        if a.esImagen {
                            bloques.append([
                                "type": "image",
                                "mimeType": a.mime,
                                "data": a.datos.base64EncodedString(),
                            ])
                        }
                        if let r = a.remoto {
                            bloques.append(["type": "resource_link", "uri": r.url,
                                            "name": r.nombre, "mimeType": r.mime])
                            lineas.append(BloqueDeAdjuntos.linea(
                                nombre: r.nombre, mime: r.mime, url: r.url, bytes: r.bytes,
                                yaTranscrito: a.transcripcion != nil))
                        } else {
                            // No se calla: un archivo que no llegó y no se anuncia es el
                            // fallo mudo de siempre.
                            lineas.append(BloqueDeAdjuntos.noEntregado(a.nombre))
                        }
                    }
                    if let aviso = BloqueDeAdjuntos.texto(lineas) {
                        bloques.append(["type": "text", "text": aviso])
                    }
                    bloques.append(["type": "text", "text": texto])
                    let fin = try await self.pedir("session/prompt", [
                        "sessionId": sessionID,
                        "prompt": bloques,
                    ], timeout: 900)
                    // El cierre trae el gasto. Se emite ANTES de terminar el flujo para
                    // que el store lo tenga cuando anote el turno.
                    if let u = fin["usage"] as? [String: Any] {
                        let entrada = (u["inputTokens"] as? Int) ?? 0
                        let salida = (u["outputTokens"] as? Int) ?? 0
                        // Algunos motores sólo mandan el total. Se atribuye a entrada, que
                        // es donde está el grueso: inventarle un reparto sería peor.
                        let total = (u["totalTokens"] as? Int) ?? 0
                        cont.yield(.usage(input: entrada > 0 ? entrada : total, output: salida))
                    }
                    await self.cerrarEnVivo(sessionID)
                    bombeo.cancel()
                    cont.finish()
                } catch {
                    await self.cerrarEnVivo(sessionID)
                    bombeo.cancel()
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in
                tarea.cancel()
                // Y que la caja lo sepa: cancelar aquí sin decírselo la deja trabajando.
                Task { await self.cancelar(sessionID) }
            }
        }
    }

    /// Se avisa por aquí cuando el agente pide permiso.
    func alPedirPermiso(_ handler: @escaping (Permiso) -> Void) {
        permisoPendiente = handler
    }

    /// Le dice a la caja que **pare** el turno de ese hilo.
    ///
    /// ⚠️ Esto no existía, y por eso "Detener" era cosmético: se cancelaba la `Task` del
    /// teléfono y el agente seguía trabajando —y cobrando— hasta terminar, con su hueco
    /// ocupado. Va como notificación (sin `id`): el protocolo no contesta a esto.
    func cancelar(_ sessionID: String) async {
        guard let t = tarea else { return }
        let sobre: [String: Any] = ["jsonrpc": "2.0", "method": "session/cancel",
                                    "params": ["sessionId": sessionID]]
        guard let d = try? JSONSerialization.data(withJSONObject: sobre) else { return }
        try? await t.send(.string(String(decoding: d, as: UTF8.self)))
    }

    /// Contesta una petición de permiso. El turno está detenido hasta esto.
    func responderPermiso(_ id: Int, opcion: String) async throws {
        guard let t = tarea else { throw Fallo.noConectado }
        let sobre: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                    "result": ["outcome": ["outcome": "selected", "optionId": opcion]]]
        let d = try JSONSerialization.data(withJSONObject: sobre)
        try await t.send(.string(String(decoding: d, as: UTF8.self)))
    }

    /// Traduce un `tool_call` / `tool_call_update` a una herramienta.
    ///
    /// ⚠️ `content` de una herramienta es un **ARRAY**, no un objeto. Ahí estaba el fallo:
    /// el resto del cliente lo lee como `content.text` —que es la forma de los chunks de
    /// mensaje— y por eso el resultado no aparecía nunca. No es que no llegara: es que se
    /// leía mal.
    nonisolated static func herramienta(_ u: [String: Any], id: String) -> Herramienta {
        let estado: Herramienta.Estado
        switch u["status"] as? String {
        case "completed": estado = .hecha
        case "failed":    estado = .fallida
        default:          estado = .corriendo   // `pending` e `in_progress`
        }

        // El primer archivo que toca, para poder decir SOBRE QUÉ trabaja.
        let donde = (u["locations"] as? [[String: Any]])?
            .compactMap { $0["path"] as? String }.first
            .map { ($0 as NSString).lastPathComponent }

        return Herramienta(
            id: id,
            titulo: (u["title"] as? String) ?? "herramienta",
            clase: .init(u["kind"] as? String),
            estado: estado,
            salida: Self.salidaDe(u["content"]),
            donde: donde)
    }

    /// El texto legible de lo que devolvió una herramienta, si lo hay.
    private nonisolated static func salidaDe(_ crudo: Any?) -> String? {
        guard let partes = crudo as? [[String: Any]] else { return nil }
        var trozos: [String] = []
        for p in partes {
            // `content` envuelve un bloque; `diff` y `terminal` traen lo suyo.
            if let c = p["content"] as? [String: Any], let t = c["text"] as? String { trozos.append(t) }
            else if let t = p["text"] as? String { trozos.append(t) }
            else if let d = p["newText"] as? String { trozos.append(d) }
        }
        let junto = trozos.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return junto.isEmpty ? nil : junto
    }

    /// Traduce el payload de `ghosty/artifact` a una entrega.
    ///
    /// El relé manda dos formas (ver `mcp.ts` de la plantilla):
    ///   • `{tipo:"archivo", nombre, contenidoBase64}`
    ///   • `{tipo:"artefacto", subtipo:"doc"|"sheet"|"artifact", titulo, contenido}`
    ///
    /// ⚠️ Un `subtipo` que no reconozcamos NO se descarta: entra como página. Tirar una
    /// entrega porque el nombre de su forma es nuevo la haría desaparecer sin dejar
    /// rastro, y el agente ya le dijo al usuario que se la entregó.
    nonisolated static func entregaDesde(_ p: [String: Any], agentID: String) -> Entrega? {
        // ⚠️ El id es DETERMINISTA, no un `UUID()` nuevo. La entrega del relé no trae
        // `sessionId`, así que con varios turnos vivos se reparte a todos los flujos, y
        // cada uno la registraba: la misma entrega tres veces en Artefactos, y en disco.
        // Con un id derivado de su contenido, registrarla dos veces es la misma fila.
        let huella = [p["tipo"] as? String, p["subtipo"] as? String, p["nombre"] as? String,
                      p["titulo"] as? String,
                      (p["contenido"] as? String).map { String($0.prefix(200)) },
                      (p["contenidoBase64"] as? String).map { String($0.prefix(200)) }]
            .compactMap { $0 }.joined(separator: "|")
        let id = "e\(abs(huella.hashValue))"
        switch p["tipo"] as? String {
        case "archivo":
            let nombre = (p["nombre"] as? String) ?? "Archivo"
            let datos = (p["contenidoBase64"] as? String).flatMap { Data(base64Encoded: $0) }
            return Entrega(id: id, agentID: agentID, forma: .archivo, titulo: nombre,
                           recibida: Date(), contenido: nil, datos: datos)
        case "artefacto":
            let forma: Entrega.Forma
            switch p["subtipo"] as? String {
            case "doc":   forma = .doc
            case "sheet": forma = .sheet
            default:      forma = .artifact
            }
            return Entrega(id: id, agentID: agentID, forma: forma,
                           titulo: (p["titulo"] as? String) ?? "Sin título",
                           recibida: Date(),
                           contenido: (p["contenido"] as? String) ?? "", datos: nil)
        default:
            return nil
        }
    }

    private func abrirEnVivo(_ sink: AsyncStream<Replay>.Continuation, hilo: String) {
        enVivo[hilo] = sink
    }

    private func cerrarEnVivo(_ hilo: String) {
        enVivo[hilo]?.finish()
        enVivo[hilo] = nil
    }

    /// ¿Cuántos turnos hay corriendo ahora mismo en esta caja?
    var turnosVivos: Int { enVivo.count }

    private func leerModos(_ crudo: Any?) -> Modos? {
        guard let m = crudo as? [String: Any],
              let actual = m["currentModeId"] as? String else { return nil }
        let lista = (m["availableModes"] as? [[String: Any]] ?? []).compactMap { d -> (String, String, String)? in
            guard let id = d["id"] as? String else { return nil }
            return (id, d["name"] as? String ?? id, d["description"] as? String ?? "")
        }
        return Modos(actual: actual, disponibles: lista)
    }

    // MARK: - JSON-RPC

    private func pedir(_ metodo: String,
                       _ params: [String: Any],
                       timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard let t = tarea else { throw Fallo.noConectado }
        siguienteID += 1
        let id = siguienteID

        let sobre: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": metodo, "params": params]
        let datos = try JSONSerialization.data(withJSONObject: sobre)
        try await t.send(.string(String(decoding: datos, as: UTF8.self)))

        // El reloj va aparte: si la caja se suspendió, el socket queda a medio morir
        // y la petición esperaría para siempre sin error.
        let reloj = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.expirar(id, metodo)
        }
        defer { reloj.cancel() }

        return try await withCheckedThrowingContinuation { c in
            // Si ya contestó mientras íbamos de camino, está en el buzón.
            if let ya = buzon.removeValue(forKey: id) { c.resume(with: ya); return }
            pendientes[id] = c
        }
    }

    private func expirar(_ id: Int, _ metodo: String) {
        buzon[id] = nil
        guard let c = pendientes.removeValue(forKey: id) else { return }
        c.resume(throwing: Fallo.timeout(metodo))
    }

    private func arrancarLector() {
        lector = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let t = await self.tarea else { return }
                    let m = try await t.receive()
                    if case .string(let s) = m { await self.recibir(s) }
                    else if case .data(let d) = m {
                        await self.recibir(String(decoding: d, as: UTF8.self))
                    }
                } catch {
                    await self.romper(error)
                    return
                }
            }
        }
    }

    /// El socket se cayó. Deja el cliente **declaradamente muerto**.
    ///
    /// ⚠️ Antes sólo resolvía `pendientes` y dejaba `tarea` puesta. Como el store da por
    /// bueno el cliente mientras tenga `infoDeLaCaja`, un corte de red mataba TODAS las
    /// conversaciones de ese agente y ninguna se recuperaba sola: había que pasar por el
    /// historial, que era el único sitio que lo limpiaba.
    private func romper(_ error: Error) {
        for (_, c) in pendientes { c.resume(throwing: error) }
        pendientes.removeAll()
        buzon.removeAll()
        for (_, c) in enVivo { c.finish() }
        enVivo.removeAll()
        replayEnCurso.removeAll()
        tarea = nil
        alCaerse?()
    }

    /// Aviso hacia arriba de que este cliente ya no sirve.
    private var alCaerse: (() -> Void)?
    func alPerderse(_ handler: @escaping () -> Void) { alCaerse = handler }

    private func recibir(_ texto: String) {
        guard let d = texto.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return }

        // Respuesta a algo que pedimos. Puede llegar antes de que su continuación esté
        // registrada, así que si no hay a quién dársela se guarda en el buzón — pero sólo
        // si es un id NUESTRO, o guardaríamos las peticiones que nos hace el agente.
        if let id = m["id"] as? Int, m["method"] == nil {
            let salida: Result<[String: Any], Error>
            if let e = m["error"] as? [String: Any] {
                salida = .failure(Fallo.remoto(e["message"] as? String ?? "\(e)"))
            } else {
                salida = .success(m["result"] as? [String: Any] ?? [:])
            }
            if let c = pendientes.removeValue(forKey: id) { c.resume(with: salida) }
            else if id <= siguienteID { buzon[id] = salida }
            return
        }

        // Petición del AGENTE al cliente: hay que contestar o el turno se cuelga.
        if let metodo = m["method"] as? String, let id = m["id"] as? Int {
            if metodo == "session/request_permission",
               let p = m["params"] as? [String: Any] {
                let tc = p["toolCall"] as? [String: Any]
                let opciones = (p["options"] as? [[String: Any]] ?? []).compactMap { o -> (String, String, String)? in
                    guard let oid = o["optionId"] as? String else { return nil }
                    return (oid, o["name"] as? String ?? oid, o["kind"] as? String ?? "")
                }
                permisoPendiente?(Permiso(
                    id: id,
                    sessionID: p["sessionId"] as? String ?? "",
                    titulo: tc?["title"] as? String ?? "una herramienta",
                    herramienta: tc?["kind"] as? String ?? "",
                    opciones: opciones))
            }
            return
        }

        // La entrega viaja como notificación PROPIA del relé, no como `session/update`:
        // no lleva `sessionId` ni respuesta, y un cliente que no la conozca la ignora sin
        // romperse (que es lo que le pasa a Zed). Ver `relay.ts` → `entregar()`.
        if m["method"] as? String == "ghosty/artifact",
           let p = m["params"] as? [String: Any] {
            if let e = Self.entregaDesde(p, agentID: agentID) {
                // ⚠️ La entrega del relé NO trae `sessionId` (ver `relay.ts` → `entregar()`),
                // así que no hay a quién dirigirla. Con un solo turno vivo es obvio; con
                // varios se manda al hilo que la pidió sólo si lo podemos saber, y si no,
                // a todos: una entrega repetida se ve, una perdida no.
                if enVivo.count == 1, let solo = enVivo.first?.value {
                    solo.yield(.entrega(e))
                } else {
                    // A todos: perderla es peor que verla dos veces, y su id determinista
                    // hace que registrarla N veces sea una sola fila en Artefactos.
                    for (_, c) in enVivo { c.yield(.entrega(e)) }
                }
            }
            return
        }

        // Notificación del agente
        guard m["method"] as? String == "session/update",
              let params = m["params"] as? [String: Any],
              let u = params["update"] as? [String: Any],
              let tipo = u["sessionUpdate"] as? String
        else { return }

        // A QUÉ hilo pertenece. Venía en el sobre desde siempre y se ignoraba.
        let hilo = params["sessionId"] as? String

        let texto = (u["content"] as? [String: Any])?["text"] as? String ?? ""
        let evento: Replay?
        switch tipo {
        case "user_message_chunk":    evento = .user(texto)
        case "agent_message_chunk":   evento = .agent(texto)
        case "agent_thought_chunk":   evento = .thought(texto)
        case "tool_call", "tool_call_update":
            evento = (u["toolCallId"] as? String).map { .tool(Self.herramienta(u, id: $0)) }
        default: evento = nil
        }
        guard let evento else { return }

        // El mismo evento sirve para el replay de `session/load` y para el turno en
        // vivo: la caja usa `session/update` para los dos. Lo que los separa es el hilo.
        guard let hilo else {
            // Sin `sessionId` no se puede dirigir. Antes esto caía en el único flujo
            // abierto; ahora se descarta, porque adivinar es justo lo que mezclaba
            // conversaciones. Pero se DICE: si una versión de la caja dejara de mandarlo,
            // el síntoma sería "el agente no contesta nunca" sin un solo rastro.
            EasyBitsClient.diag("⚠️ session/update sin sessionId — evento descartado (\(tipo))")
            return
        }
        if replayEnCurso[hilo] != nil { replayEnCurso[hilo]?.append(evento) }
        enVivo[hilo]?.yield(evento)
    }
}
