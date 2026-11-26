import Foundation

/// Latido «estoy viendo esta conversación» a gs (`POST …/conversations/:sid/presence`), el mismo
/// de /c y de la app de Mac.
///
/// Dos efectos en gs: mientras late, el push de fin de turno de ESTA conversación no suena (la
/// respuesta ya se ve aquí), y el latido NUEVO (abrir el hilo o volver a la app) precalienta la
/// caja del agente para que el siguiente mensaje no pague el arranque en frío (25-nov-2026).
/// Contrato: `app/lib/push/watching.server.ts` en gs. Sólo late con la app al frente: iOS
/// suspende la app en el fondo y el latido vence solo a los ~45 s.
enum WatchingBeat {
    private static let interval: Duration = .seconds(20)

    /// Late cada 20 s hasta que se cancele la tarea (cambio de hilo, fondo, salir del chat) y
    /// entonces retira el latido.
    static func run(agentID: String, sessionID: String) async {
        while !Task.isCancelled {
            await send(agentID: agentID, sessionID: sessionID, watching: true)
            try? await Task.sleep(for: interval)
        }
        // La tarea ya está cancelada: el «ya no miro» sale en una tarea propia.
        Task.detached { await send(agentID: agentID, sessionID: sessionID, watching: false) }
    }

    private static func send(agentID: String, sessionID: String, watching: Bool) async {
        guard Session.haySesion else { return }
        let url = Session.base.appendingPathComponent("api/v2/me/agents/\(agentID)/conversations/\(sessionID)/presence")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.assumesHTTP3Capable = false
        req.timeoutInterval = 10
        guard let token = try? await Session.accessToken() else { return }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["watching": watching])
        _ = try? await URLSession.shared.data(for: req)
    }
}
