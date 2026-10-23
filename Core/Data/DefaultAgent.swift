import Foundation
import Observation

/// El agente principal (gs `defaultAgentId` en `/api/v2/me`), como `default_agent` de OpenCode:
/// el que se usa cuando nadie eligió otro. Lo usan el resumen de la mañana, «Nueva conversación»
/// y lo que llega sin agente. Cambiarlo no mueve los hilos que ya existen.
///
/// `saved` es lo que eligió la persona (`nil` = automático) y `resolved` el que gs usa de verdad:
/// el elegido → el último que usaste → el más antiguo.
@MainActor @Observable
final class DefaultAgentStore {
    static let shared = DefaultAgentStore()

    private(set) var saved: String?
    private(set) var resolved: String?
    var error: String?
    @ObservationIgnored private var loadedAt: Date?

    func isDefault(_ agentId: String) -> Bool { resolved == agentId }

    func load(force: Bool = false) async {
        if DemoData.encendido {
            if resolved == nil { resolved = DemoData.cuentas.first?.id }
            return
        }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        do {
            let j = try await pedir("GET", nil)
            saved = j["defaultAgentId"] as? String
            resolved = j["resolvedDefaultAgentId"] as? String ?? saved
            loadedAt = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// `nil` vuelve a automático. Optimista: si gs dice que no, regresa a lo de antes.
    func set(_ agentId: String?) async {
        let (antes, antesResuelto) = (saved, resolved)
        saved = agentId
        if let agentId { resolved = agentId }
        if DemoData.encendido { return }
        do {
            let j = try await pedir("PATCH", ["defaultAgentId": agentId ?? NSNull()])
            saved = j["defaultAgentId"] as? String
            resolved = j["resolvedDefaultAgentId"] as? String ?? saved
            error = nil
        } catch {
            (saved, resolved) = (antes, antesResuelto)
            self.error = error.localizedDescription
        }
        // El resumen que sigue al principal cambia de autor: que lo relea.
        await MorningBriefStore.shared.load(force: true)
    }

    private func pedir(_ metodo: String, _ cuerpo: [String: Any]?) async throws -> [String: Any] {
        var req = URLRequest(url: Session.base.appendingPathComponent("api/v2/me"))
        req.httpMethod = metodo
        req.assumesHTTP3Capable = false
        req.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        if let cuerpo {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: cuerpo)
        }
        let datos: Data, resp: URLResponse
        do { (datos, resp) = try await URLSession.shared.data(for: req) }
        catch { throw GhostyAPI.Fallo.mensaje("Sin conexión. Inténtalo de nuevo.") }
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any] ?? [:]
        guard (200..<300).contains(codigo) else {
            throw GhostyAPI.Fallo.mensaje((j["detalle"] as? String) ?? (j["error"] as? String) ?? "El servidor contestó \(codigo).")
        }
        return j
    }
}
