import Foundation
import Observation

/// El resumen de la mañana (gs `api/v2/me/brief`): a la hora elegida, el agente revisa correo,
/// agenda y pendientes por su cuenta y deja de 3 a 5 tarjetas y un audio en una conversación fija.
///
/// Es de la PERSONA, no de un agente: hay uno por cuenta y `agentId` dice cuál lo escribe.
/// Viene apagado; se ofrece una vez (`offered`) y se prende a mano. Lo comparten la app de
/// iOS, la de Android y `/c`, así que un «Ahora no» en un lado vale para todos.
struct MorningBrief: Equatable, Sendable {
    var enabled = false
    var hour = 8
    var minute = 0
    /// 0 = domingo … 6 = sábado, como `Date.getDay()` en gs.
    var days: [Int] = [1, 2, 3, 4, 5]
    /// `nil` = lo escribe el agente principal (`resolvedAgentId`).
    var agentId: String?
    /// Quién lo escribe de verdad: `agentId` o, si es `nil`, el principal.
    var resolvedAgentId: String?
    var timeZone = TimeZone.current.identifier
    /// La conversación «Resumen de la mañana». `nil` hasta que corre la primera vez.
    var sessionId: String?
    var offered = false
    /// ¿El agente tiene correo o agenda conectados? Sin ellos el resumen sale de lo que gs ya
    /// sabe (agenda, pendientes, preguntas sin contestar) y se sugiere conectar el correo.
    var hasSources = true

    static let weekdays = [1, 2, 3, 4, 5]
    static let everyDay = [0, 1, 2, 3, 4, 5, 6]

    init() {}

    init(_ j: [String: Any]) {
        enabled = j["enabled"] as? Bool ?? false
        hour = j["hour"] as? Int ?? 8
        minute = j["minute"] as? Int ?? 0
        days = (j["days"] as? [Int]).flatMap { $0.isEmpty ? nil : $0.sorted() } ?? Self.weekdays
        agentId = j["agentId"] as? String
        resolvedAgentId = j["resolvedAgentId"] as? String ?? agentId
        timeZone = j["timeZone"] as? String ?? TimeZone.current.identifier
        sessionId = j["sessionId"] as? String
        offered = j["offered"] as? Bool ?? false
        hasSources = j["hasSources"] as? Bool ?? true
    }

    /// «8:00 · L–V», para el subtítulo del renglón de Perfil.
    var summary: String {
        guard enabled else { return "Apagado" }
        let hora = String(format: "%d:%02d", hour, minute)
        switch days {
        case Self.weekdays: return "\(hora) · L–V"
        case Self.everyDay: return "\(hora) · Todos los días"
        default:
            let letras = ["D", "L", "M", "M", "J", "V", "S"]
            return "\(hora) · " + days.map { letras[$0] }.joined(separator: " ")
        }
    }
}

/// El cliente de `/me/brief`. Los errores llegan legibles de gs (`{error, detalle}`).
enum MorningBriefAPI {
    private static var url: URL { Session.base.appendingPathComponent("api/v2/me/brief") }

    static func load() async throws -> MorningBrief {
        MorningBrief(try await pedir(url))
    }

    /// Sólo manda lo que cambió: gs acepta un cuerpo parcial y toma la zona de `X-Timezone`.
    static func save(_ patch: [String: Any]) async throws -> MorningBrief {
        MorningBrief(try await pedir(url, metodo: "PUT", cuerpo: patch))
    }

    /// «Probar ahora»: corre ya, sin esperar a la hora. Devuelve dónde quedó.
    static func runNow() async throws -> (agentId: String, sessionId: String) {
        let j = try await pedir(url.appendingPathComponent("run"), metodo: "POST", cuerpo: [:])
        guard let a = j["agentId"] as? String, let s = j["sessionId"] as? String else {
            throw GhostyAPI.Fallo.mensaje("No pude arrancar el resumen.")
        }
        return (a, s)
    }

    private static func pedir(_ url: URL, metodo: String = "GET", cuerpo: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = metodo
        req.assumesHTTP3Capable = false
        req.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
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

/// El estado compartido del resumen: lo leen el renglón de Perfil, la oferta de Chats y la barra
/// del hilo del resumen. En demo vive sólo en memoria y no toca la red.
@MainActor @Observable
final class MorningBriefStore {
    static let shared = MorningBriefStore()

    private(set) var brief: MorningBrief?
    private(set) var saving = false
    var error: String?
    @ObservationIgnored private var loadedAt: Date?

    /// El kill switch remoto (`/admin/settings` → `brief`). Apagado, nada del resumen se enseña.
    var available: Bool { AppConfig.shared.isOn("brief") }

    /// La oferta de Chats: sale una sola vez, mientras esté apagado y nunca se haya contestado.
    var shouldOffer: Bool {
        guard available, let b = brief else { return false }
        return !b.enabled && !b.offered
    }

    func isBriefThread(_ sessionId: String?) -> Bool {
        guard let sessionId, let s = brief?.sessionId else { return false }
        return s == sessionId
    }

    /// Lee de gs como mucho cada 60 s (la entrada a Chats lo llama seguido).
    func load(force: Bool = false) async {
        if DemoData.encendido {
            if brief == nil { brief = DemoData.morningBrief }
            return
        }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        do {
            brief = try await MorningBriefAPI.load()
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? GhostyAPI.Fallo)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Guarda en optimista: se pinta ya y, si gs dice que no, se regresa a lo de antes.
    func update(_ change: (inout MorningBrief) -> Void) async {
        guard var nuevo = brief else { return }
        let antes = nuevo
        change(&nuevo)
        // Prenderlo cuenta como contestar la oferta.
        if nuevo.enabled { nuevo.offered = true }
        brief = nuevo
        if DemoData.encendido { return }
        saving = true
        defer { saving = false }
        do {
            brief = try await MorningBriefAPI.save(Self.patch(from: antes, to: nuevo))
            error = nil
        } catch {
            brief = antes
            self.error = (error as? GhostyAPI.Fallo)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// «Probar ahora». Devuelve dónde abrir el resultado.
    func runNow() async -> (agentId: String, sessionId: String)? {
        if DemoData.encendido {
            guard let b = brief, let a = b.resolvedAgentId ?? b.agentId, let s = b.sessionId else { return nil }
            return (a, s)
        }
        do {
            let r = try await MorningBriefAPI.runNow()
            brief?.sessionId = r.sessionId
            return r
        } catch {
            self.error = (error as? GhostyAPI.Fallo)?.localizedDescription ?? error.localizedDescription
            return nil
        }
    }

    static func patch(from a: MorningBrief, to b: MorningBrief) -> [String: Any] {
        var p: [String: Any] = [:]
        if a.enabled != b.enabled { p["enabled"] = b.enabled }
        if a.hour != b.hour { p["hour"] = b.hour }
        if a.minute != b.minute { p["minute"] = b.minute }
        if a.days != b.days { p["days"] = b.days }
        if a.agentId != b.agentId { p["agentId"] = b.agentId ?? NSNull() }
        if a.offered != b.offered { p["offered"] = b.offered }
        // La zona va siempre: quien viaja recibe el resumen a SU hora.
        p["timeZone"] = TimeZone.current.identifier
        return p
    }
}
