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
            case .noConectado:      return "No hay conexión con la caja del agente."
            case .timeout(let m):   return "La caja no contestó a \(m)."
            case .remoto(let m):    return m
            case .handshake(let m): return "No pude abrir la sesión: \(m)"
            }
        }
    }

    private let agentID: String
    private let token: String
    private var tarea: URLSessionWebSocketTask?
    private var lector: Task<Void, Never>?
    private var siguienteID = 0
    private var pendientes: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    /// Las notificaciones del replay se acumulan aquí mientras `session/load` corre.
    private var replayEnCurso: [Replay] = []
    private var capturandoReplay = false

    private let sesion: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    init(agentID: String, token: String) {
        self.agentID = agentID
        self.token = token
    }

    var url: URL {
        // El dominio es fijo por agente y el router del host lo sigue de caja en
        // caja, así que sobrevive a que la recreen.
        URL(string: "wss://acp-\(agentID).sandboxes.easybits.cloud/acp")!
    }

    // MARK: - Conexión

    /// Abre el socket y hace `initialize`. Devuelve el nombre y versión del agente.
    @discardableResult
    func conectar() async throws -> String {
        if tarea != nil { cerrar() }

        var req = URLRequest(url: url)
        // El `agt_` del agente vale como Bearer: no hace falta ticket firmado ni el
        // secreto de la plataforma. Comprobado contra la caja.
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

        // Notificación del agente
        guard m["method"] as? String == "session/update",
              let params = m["params"] as? [String: Any],
              let u = params["update"] as? [String: Any],
              let tipo = u["sessionUpdate"] as? String
        else { return }

        guard capturandoReplay else { return }
        let texto = (u["content"] as? [String: Any])?["text"] as? String ?? ""

        switch tipo {
        case "user_message_chunk":    replayEnCurso.append(.user(texto))
        case "agent_message_chunk":   replayEnCurso.append(.agent(texto))
        case "agent_thought_chunk":   replayEnCurso.append(.thought(texto))
        case "tool_call":
            if let id = u["toolCallId"] as? String {
                replayEnCurso.append(.toolCall(id: id, title: u["title"] as? String ?? "herramienta"))
            }
        case "tool_call_update":
            if let id = u["toolCallId"] as? String {
                replayEnCurso.append(.toolDone(id: id, ok: (u["status"] as? String) == "completed"))
            }
        default: break
        }
    }
}
