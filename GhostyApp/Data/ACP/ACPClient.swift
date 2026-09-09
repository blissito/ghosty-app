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
        case toolCall(id: String, title: String)
        case toolDone(id: String, ok: Bool)
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
    /// Las notificaciones del replay se acumulan aquí mientras `session/load` corre.
    private var replayEnCurso: [Replay] = []
    private var capturandoReplay = false
    /// Por dónde salen los eventos del turno en vuelo.
    private var enVivo: AsyncStream<Replay>.Continuation?
    /// Los permisos que el agente pidió y nadie ha contestado.
    private var permisoPendiente: ((Permiso) -> Void)?

    private let sesion: URLSession = {
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
        URL(string: "wss://\(host ?? "acp-\(agentID).sandboxes.easybits.cloud")/acp")!
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

        let t = sesion.webSocketTask(with: req)
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
    func cargar(_ id: String, cwd: String) async throws -> [Replay] {
        replayEnCurso = []
        capturandoReplay = true
        defer { capturandoReplay = false }
        _ = try await pedir("session/load",
                            ["sessionId": id, "cwd": cwd, "mcpServers": []],
                            timeout: 90)
        return replayEnCurso
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
    nonisolated func prompt(sessionID: String, texto: String) -> AsyncThrowingStream<Replay, Error> {
        AsyncThrowingStream { cont in
            let tarea = Task {
                let (flujo, sink) = AsyncStream<Replay>.makeStream()
                await self.abrirEnVivo(sink)
                let bombeo = Task { for await e in flujo { cont.yield(e) } }
                do {
                    _ = try await self.pedir("session/prompt", [
                        "sessionId": sessionID,
                        "prompt": [["type": "text", "text": texto]],
                    ], timeout: 900)
                    await self.cerrarEnVivo()
                    bombeo.cancel()
                    cont.finish()
                } catch {
                    await self.cerrarEnVivo()
                    bombeo.cancel()
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in tarea.cancel() }
        }
    }

    /// Se avisa por aquí cuando el agente pide permiso.
    func alPedirPermiso(_ handler: @escaping (Permiso) -> Void) {
        permisoPendiente = handler
    }

    /// Contesta una petición de permiso. El turno está detenido hasta esto.
    func responderPermiso(_ id: Int, opcion: String) async throws {
        guard let t = tarea else { throw Fallo.noConectado }
        let sobre: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                    "result": ["outcome": ["outcome": "selected", "optionId": opcion]]]
        let d = try JSONSerialization.data(withJSONObject: sobre)
        try await t.send(.string(String(decoding: d, as: UTF8.self)))
    }

    private func abrirEnVivo(_ sink: AsyncStream<Replay>.Continuation) { enVivo = sink }
    private func cerrarEnVivo() { enVivo?.finish(); enVivo = nil }

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
            pendientes[id] = c
        }
    }

    private func expirar(_ id: Int, _ metodo: String) {
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

    private func romper(_ error: Error) {
        for (_, c) in pendientes { c.resume(throwing: error) }
        pendientes.removeAll()
    }

    private func recibir(_ texto: String) {
        guard let d = texto.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return }

        // Respuesta a algo que pedimos
        if let id = m["id"] as? Int, let c = pendientes.removeValue(forKey: id) {
            if let e = m["error"] as? [String: Any] {
                c.resume(throwing: Fallo.remoto(e["message"] as? String ?? "\(e)"))
            } else {
                c.resume(returning: m["result"] as? [String: Any] ?? [:])
            }
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

        // Notificación del agente
        guard m["method"] as? String == "session/update",
              let params = m["params"] as? [String: Any],
              let u = params["update"] as? [String: Any],
              let tipo = u["sessionUpdate"] as? String
        else { return }

        let texto = (u["content"] as? [String: Any])?["text"] as? String ?? ""
        let evento: Replay?
        switch tipo {
        case "user_message_chunk":    evento = .user(texto)
        case "agent_message_chunk":   evento = .agent(texto)
        case "agent_thought_chunk":   evento = .thought(texto)
        case "tool_call":
            evento = (u["toolCallId"] as? String).map {
                .toolCall(id: $0, title: u["title"] as? String ?? "herramienta")
            }
        case "tool_call_update":
            evento = (u["toolCallId"] as? String).map {
                .toolDone(id: $0, ok: (u["status"] as? String) == "completed")
            }
        default: evento = nil
        }
        guard let evento else { return }

        // El mismo evento sirve para el replay de `session/load` y para el turno en
        // vivo: la caja usa `session/update` para los dos.
        if capturandoReplay { replayEnCurso.append(evento) }
        enVivo?.yield(evento)
    }
}
