import Foundation
import Observation

/// Un aviso que te llegó (push), tal como lo guarda gs en `GET /api/v2/me/notifications`.
struct NoticeItem: Identifiable, Equatable, Sendable {
    let id: String
    /// `crm` (ventas: escalado, respuesta fallida, archivo sin entregar), `reply`, `error`,
    /// `permission`, `doc`, `novedad`…
    let kind: String
    let title: String
    let body: String
    let date: Date
    let url: String?
    let agentID: String?
    let sessionID: String?
    /// Aviso de un pendiente de Desarrollo: tocarlo abre el pendiente en Dev.
    var devRunID: String? = nil
    let conversationID: String?
    let namespace: String?
    let urgent: Bool
    /// Algo de ventas que todavía espera a la persona.
    let pending: Bool

    /// El SF Symbol de cada clase de aviso.
    var symbol: String {
        switch kind {
        case "crm": "person.crop.circle.badge.exclamationmark"
        case "reply": "bubble.left.fill"
        case "error": "exclamationmark.triangle.fill"
        case "permission": "hand.raised.fill"
        case "doc": "doc.text.fill"
        case "novedad": "sparkles"
        default: "bell.fill"
        }
    }

    /// El mismo diccionario que trae el push, para que tocar la fila haga exactamente lo
    /// que hace tocar el aviso (`Avisos.openNotice`).
    var payload: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = ["tipo": kind]
        if let url { info["url"] = url }
        if let agentID { info["agentId"] = agentID }
        if let sessionID { info["sessionId"] = sessionID }
        if let devRunID { info["devRunId"] = devRunID }
        return info
    }

    static func from(json j: [String: Any]) -> NoticeItem? {
        guard let id = j["id"] as? String,
              let at = j["at"] as? String, let date = parseDate(at) else { return nil }
        func text(_ k: String) -> String? { (j[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var item = NoticeItem(id: id, kind: text("kind") ?? "aviso", title: text("title") ?? "Aviso",
                              body: text("body") ?? "", date: date, url: text("url"),
                              agentID: text("agentId"), sessionID: text("sessionId"),
                              conversationID: text("conversationId"), namespace: text("namespace"),
                              urgent: j["urgent"] as? Bool ?? false, pending: j["pending"] as? Bool ?? false)
        item.devRunID = text("devRunId")
        return item
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// El hilo «Avisos»: cada push de los últimos 30 días, guardado en gs.
///
/// A diferencia de `ActivityFeed` (una foto de ahora), esto SÍ es historial: lo que te
/// avisaron aunque ya lo hayas visto o borrado del centro de notificaciones. Se repregunta
/// al abrir la hoja, al volver del fondo y cuando llega un push.
@MainActor @Observable
final class NoticeHistory {
    static let shared = NoticeHistory()

    /// Del más nuevo al más viejo; gs ya los manda sin duplicados.
    private(set) var items: [NoticeItem] = []
    /// Lo que gs cuenta como pendiente (ventas urgentes sin atender).
    private(set) var pendingCount = 0
    private(set) var loaded = false
    private var inFlight = false

    /// Pendientes que no son permisos: los permisos ya los cuenta el feed en vivo.
    var pendingNonPermission: Int {
        max(0, pendingCount - items.filter { $0.pending && $0.kind == "permission" }.count)
    }

    func refresh() async {
        guard !DemoData.encendido, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        var c = URLComponents(url: Session.base.appendingPathComponent("api/v2/me/notifications"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "limit", value: "100")]
        guard let url = c.url, let token = try? await Session.accessToken() else { return }
        var req = URLRequest(url: url)
        req.assumesHTTP3Capable = false
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Un fallo de red deja lo último que se leyó: el historial no se vacía por un túnel.
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["items"] as? [[String: Any]] else {
            EasyBitsClient.diag("[avisos] no pude leer /me/notifications")
            return
        }
        items = list.compactMap(NoticeItem.from(json:))
        pendingCount = j["pendingCount"] as? Int ?? items.filter(\.pending).count
        loaded = true
    }
}
