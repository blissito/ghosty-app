import Foundation

/// UN stream por cuenta (`GET /api/v2/me/events`, sync v2): avisa que algo cambió en
/// cualquier conversación de cualquier agente —un mensaje nuevo, un turno que empieza o acaba,
/// un permiso— venga de donde venga (Android, la Mac, la web, un turno programado).
///
/// ⚠️ Existe porque sin él la lista de Chats sólo se enteraba al volver al frente: lo que
/// pasaba en otra superficie no llegaba en vivo (bliss, 8-oct, hablando con PowerGhosty desde
/// Android). No trae tokens: sólo el aviso; quien escucha decide qué pedir.
@MainActor
final class AccountEvents {
    enum Kind: String { case conversation, turn, permission, permissionResolved = "permission-resolved" }

    struct Event {
        let kind: Kind
        let agentID: String
        let sessionID: String
    }

    var onEvent: ((Event) -> Void)?
    /// Cada vez que el stream (re)abre.
    var onConnected: (() -> Void)?
    private var task: Task<Void, Never>?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 90 // latido cada 25 s
        c.timeoutIntervalForResource = 24 * 3600
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        var delay = 1.0
        while !Task.isCancelled {
            do {
                var req = URLRequest(url: Session.base.appendingPathComponent("api/v2/me/events"))
                req.setValue("Bearer \(try await Session.accessToken(rejected: nil))", forHTTPHeaderField: "Authorization")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.assumesHTTP3Capable = false
                let (bytes, resp) = try await Self.session.bytes(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                // Un gs sin la ruta, o sin sesión: no se insiste.
                if [401, 403, 404].contains(status) {
                    EasyBitsClient.diag("[cuenta] /me/events contestó \(status); no escucho")
                    task = nil
                    return
                }
                guard status == 200 else { throw URLError(.badServerResponse) }
                delay = 1.0
                EasyBitsClient.diag("[cuenta] escuchando /me/events")
                onConnected?()
                var event = ""
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.hasPrefix("event: ") { event = String(line.dropFirst(7)); continue }
                    guard line.hasPrefix("data: "), let kind = Kind(rawValue: event) else { continue }
                    let data = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))) as? [String: Any]
                    guard let agent = data?["agentId"] as? String, let sid = data?["id"] as? String else { continue }
                    onEvent?(Event(kind: kind, agentID: agent, sessionID: sid))
                }
            } catch {
                if Task.isCancelled { return }
                EasyBitsClient.diag("[cuenta] se cayó /me/events: \(error); reintento en \(Int(delay)) s")
            }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(30, delay * 2)
        }
    }
}
