import Foundation

/// Cliente de la API de agentes de EasyBits.
///
/// Se habla por HTTP y no por ACP crudo a propósito: `POST /agents/:id/message`
/// ya hace el trabajo sucio —despierta la caja si el reaper la suspendió, marca el
/// agente ocupado para que no la duerma a media respuesta, y reemite el SSE del
/// agente verbatim—. Montar el WebSocket ACP desde el teléfono duplicaría eso y
/// además obligaría a llevar el ticket firmado en el cliente.
struct EasyBitsClient: Sendable {

    /// Un evento del stream, tal como llega. Los nombres salen de leer la caja de
    /// verdad, no de la documentación: `chunk` · `usage` · `done` · `error`.
    enum Event: Sendable, Equatable {
        case chunk(String)
        case usage(inputTokens: Int, outputTokens: Int, totalTokens: Int)
        case done(stopReason: String?)
        case newSession(String)
        case error(String)
        /// Cualquier tipo que la caja mande y este cliente aún no conozca. Se
        /// guarda en vez de tirarse: un tipo nuevo no debe romper un turno.
        case unknown(type: String, raw: String)
    }

    struct Agent: Sendable, Identifiable, Decodable, Equatable {
        let agentId: String
        let name: String?
        let template: String?
        let protocolName: String?
        let status: String?

        var id: String { agentId }

        enum CodingKeys: String, CodingKey {
            case agentId, name, template, status
            case protocolName = "protocol"
        }
    }

    var baseURL = URL(string: "https://www.easybits.cloud")!
    var apiKey: String

    /// Sesión propia y no `URLSession.shared`: para un SSE hay que desactivar
    /// HTTP/3 —por QUIC el cuerpo puede no entregarse por trozos— y la caché.
    private static let sesion: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 1800
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        return URLSession(configuration: cfg)
    }()

    // MARK: - Listado

    func agents() async throws -> [Agent] {
        var req = URLRequest(url: baseURL.appending(path: "/api/v2/agents"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await Self.sesion.data(for: req)
        try Self.comprobar(resp, data)
        struct Sobre: Decodable { let agents: [Agent] }
        return try JSONDecoder().decode(Sobre.self, from: data).agents
    }

    // MARK: - Turno

    /// Abre el turno y va soltando eventos conforme llegan. El texto viene partido
    /// en muchos `chunk` (130 para una respuesta de 367 caracteres, medido), así que
    /// quien consuma esto tiene que concatenar.
    func message(
        agentID: String,
        content: String,
        sessionID: String? = nil
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let tarea = Task {
                do {
                    var req = URLRequest(url: baseURL.appending(path: "/api/v2/agents/\(agentID)/message"))
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Un turno puede tardar minutos: sin esto URLSession lo corta.
                    req.timeoutInterval = 600
                    // HTTP/3 fuera: por QUIC el cuerpo del SSE puede no entregarse
                    // por trozos y el turno se queda colgado sin error.
                    req.assumesHTTP3Capable = false

                    var cuerpo: [String: Any] = ["content": content]
                    if let sessionID { cuerpo["sessionId"] = sessionID }
                    req.httpBody = try JSONSerialization.data(withJSONObject: cuerpo)

                    Self.diag("POST /message → abriendo")
                    let (bytes, resp) = try await Self.sesion.bytes(for: req)
                    Self.diag("cabeceras: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                    if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                        var detalle = ""
                        for try await linea in bytes.lines { detalle += linea; if detalle.count > 500 { break } }
                        throw Fallo.http(status: http.statusCode, body: detalle)
                    }

                    var lineas = 0
                    for try await linea in bytes.lines {
                        lineas += 1
                        if lineas <= 3 { Self.diag("línea \(lineas): \(linea.prefix(80))") }
                        guard linea.hasPrefix("data: ") else { continue }
                        let payload = String(linea.dropFirst(6))
                        if let evento = Self.decodificar(payload) {
                            continuation.yield(evento)
                            if case .done = evento { break }
                        }
                    }
                    Self.diag("stream cerrado tras \(lineas) líneas")
                    continuation.finish()
                } catch {
                    Self.diag("FALLO: \(error)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in tarea.cancel() }
        }
    }

    /// Diagnóstico del transporte. Va a `os_log` para poder leerlo con
    /// `simctl spawn … log show`, que es la única forma de ver qué pasa dentro
    /// del simulador sin depurador.
    static let diagnosticoEncendido =
        ProcessInfo.processInfo.environment["GHOSTY_DIAG"] == "1"

    static func diag(_ mensaje: String) {
        guard diagnosticoEncendido else { return }
        NSLog("[ghosty-acp] %@", mensaje)
    }

    // MARK: - Interno

    private static func decodificar(_ payload: String) -> Event? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tipo = obj["type"] as? String else { return nil }

        switch tipo {
        case "chunk", "token":
            // el contrato g.studio usa `value`; algunos arneses mandan `text`
            let texto = (obj["value"] as? String) ?? (obj["text"] as? String) ?? ""
            return texto.isEmpty ? nil : .chunk(texto)
        case "usage":
            return .usage(
                inputTokens: obj["inputTokens"] as? Int ?? 0,
                outputTokens: obj["outputTokens"] as? Int ?? 0,
                totalTokens: obj["totalTokens"] as? Int ?? 0
            )
        case "done":
            return .done(stopReason: obj["stopReason"] as? String)
        case "error":
            return .error((obj["value"] as? String) ?? (obj["message"] as? String) ?? "error sin detalle")
        default:
            if let nueva = obj["newSessionId"] as? String { return .newSession(nueva) }
            return .unknown(type: tipo, raw: payload)
        }
    }

    private static func comprobar(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard http.statusCode < 400 else {
            throw Fallo.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    enum Fallo: LocalizedError {
        case http(status: Int, body: String)
        case sinLlave

        var errorDescription: String? {
            switch self {
            case .http(let s, let b):
                return "La caja contestó \(s). \(b.prefix(300))"
            case .sinLlave:
                return "Falta la llave de EasyBits. Ponla en EASYBITS_API_KEY o en ~/.ghosty-app.json"
            }
        }
    }
}
