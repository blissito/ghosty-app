import Foundation

/// El ÚNICO camino del turno: AG-UI sobre HTTP. Un `POST <url>` con `RunAgentInput` que contesta SSE
/// de eventos AG-UI (`~/ghostykit/docs/protocol.md`). No hay GET de eventos, ni `/cancel`, ni
/// `/permission`: detener, aprobar y reconectar son otro POST al mismo endpoint.
///
/// ⚠️ Irse NUNCA detiene nada. Cortar este flujo (pantalla, fondo, red) deja el run corriendo en el
/// servidor; lo detiene sólo `forwardedProps.cancel`. Es la misma regla que ya tenía el SSE de gs.
struct AGUITransport: Sendable {
    /// El servidor dijo que no antes de empezar (§6 del contrato).
    struct HTTPError: LocalizedError, Sendable {
        let status: Int
        /// `run_active`, `interrupt_pending`, `bad_request`…
        let code: String?
        let message: String
        let retryAfter: Double?
        var errorDescription: String? { message }
    }

    /// Las piezas de un `RunAgentInput`. Sólo se manda lo nuevo: el hilo es del servidor.
    struct Input: Sendable {
        var threadId: String
        var runId: String
        /// El mensaje nuevo de la persona, si lo hay (`messages: []` = abrir o reconectar).
        var text: String?
        var attachments: [Part] = []
        var context: [(description: String, value: String)] = []
        /// Respuestas a las aprobaciones abiertas.
        var resume: [Resume] = []
        /// `forwardedProps.cancel`: el run a detener.
        var cancel: String?
        /// Lo demás de `forwardedProps` (gs lee aquí lo suyo).
        var forwarded: [String: String] = [:]

        struct Resume: Sendable {
            var interruptId: String
            /// `nil` = `cancelled` (venció o se escribió otra cosa): el servidor NO corre la acción.
            var approved: Bool?
            /// La opción elegida (gs: gana sobre `approved`, para «siempre»).
            var optionId: String? = nil
        }

        /// Una parte de contenido AG-UI que no es texto.
        struct Part: @unchecked Sendable {
            var json: [String: Any]
        }

        var json: [String: Any] {
            var messages: [[String: Any]] = []
            if text?.isEmpty == false || !attachments.isEmpty {
                let content: Any = attachments.isEmpty
                    ? (text ?? "")
                    : ([["type": "text", "text": text ?? ""]] + attachments.map(\.json))
                // El id del mensaje es el del run: reintentar no lo duplica.
                messages.append(["id": "u-\(runId)", "role": "user", "content": content])
            }
            var fp: [String: Any] = forwarded
            if let cancel { fp["cancel"] = cancel }
            var o: [String: Any] = [
                "threadId": threadId, "runId": runId, "messages": messages, "tools": [],
                "context": context.map { ["description": $0.description, "value": $0.value] },
                "state": [String: Any](), "forwardedProps": fp,
            ]
            if !resume.isEmpty {
                o["resume"] = resume.map { r -> [String: Any] in
                    guard let ok = r.approved else { return ["interruptId": r.interruptId, "status": "cancelled"] }
                    var payload: [String: Any] = ["approved": ok]
                    if let o = r.optionId { payload["optionId"] = o }
                    return ["interruptId": r.interruptId, "status": "resolved", "payload": payload]
                }
            }
            return o
        }
    }

    let url: URL
    /// Arma la petición con la auth de la app (token refrescado por llamada).
    let authorize: @Sendable (inout URLRequest, _ rejected: String?) async throws -> Void
    var session: URLSession = AGUITransport.defaultSession
    /// Reintentos de un 503 (deploy de gs) con el MISMO run.
    var retries = 6

    /// ⚠️ Mismas curas que el SSE viejo: `identity` para que nadie comprima el flujo por trozos, y
    /// topes largos porque un turno puede tardar minutos y `URLSession` corta por su cuenta.
    nonisolated(unsafe) static var defaultSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 3600
        c.waitsForConnectivity = true
        c.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        return URLSession(configuration: c)
    }()

    /// Corre un run. Los eventos llegan en orden; el flujo termina cuando el servidor cierra.
    func run(_ input: Input) -> AsyncThrowingStream<AGUIEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    try await self.stream(input, cont)
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func request(_ input: Input, rejected: String?) async throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // HTTP/3 fuera: por QUIC el cuerpo de un SSE puede no entregarse por trozos y el turno se
        // queda colgado SIN error. Ya mordió en dos clientes de este repo.
        r.assumesHTTP3Capable = false
        r.httpBody = try JSONSerialization.data(withJSONObject: input.json)
        try await authorize(&r, rejected)
        return r
    }

    private func stream(_ input: Input, _ cont: AsyncThrowingStream<AGUIEvent, Error>.Continuation) async throws {
        var rejected: String?
        var attempt = 0
        while true {
            let req = try await request(input, rejected: rejected)
            let (bytes, resp) = try await session.bytes(for: req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let retryAfter = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            if status == 401, rejected == nil {
                // Una vez con token nuevo; si vuelve a rechazar, la sesión murió de verdad.
                rejected = req.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) } ?? ""
                continue
            }
            // Deploy en curso: el mismo run (mismo runId, idempotente) en un momento.
            if [502, 503, 504].contains(status), attempt < retries {
                attempt += 1
                try await Task.sleep(for: .seconds(retryAfter ?? Double(min(8, 1 << (attempt - 1)))))
                continue
            }
            guard (200..<300).contains(status) else {
                var body = Data()
                for try await b in bytes { body.append(b); if body.count > 4096 { break } }
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                throw HTTPError(status: status, code: json?["error"] as? String,
                                message: (json?["message"] as? String) ?? (json?["error"] as? String) ?? "El servidor contestó \(status).",
                                retryAfter: retryAfter)
            }
            // La hora del servidor (`Date`): a los eventos sin `timestamp` se les pone, para que la
            // cuenta regresiva de una aprobación no dependa del reloj del teléfono.
            let skew = (http?.value(forHTTPHeaderField: "Date")).flatMap(Self.httpDate).map { $0.timeIntervalSinceNow }
            var parser = SSEParser()
            var line: [UInt8] = []
            func deliver(_ m: SSEParser.Message?) {
                guard let m, var e = AGUIEvent(json: m.data) else { return }
                if e.timestamp == nil, let skew { e = e.withTimestamp((Date().timeIntervalSince1970 + skew) * 1000) }
                cont.yield(e)
            }
            for try await b in bytes {
                if Task.isCancelled { return }
                if b == 0x0A {
                    deliver(parser.line(String(decoding: line, as: UTF8.self)))
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(b)
                }
            }
            if !line.isEmpty { deliver(parser.line(String(decoding: line, as: UTF8.self))) }
            deliver(parser.finish())
            return
        }
    }

    private static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }
}
