import Foundation
import Observation

/// El brief de la mañana (gs `api/v2/me/digest`): a su hora, gs junta lo que está en curso y lo que
/// te necesita y lo deja como mensaje del agente principal en tu hilo más reciente, con un audio si
/// «Con voz» está prendido. No corre turno ni gasta saldo. Viene PRENDIDO por default.
///
/// Es el único aviso matutino desde el 2-nov (reemplaza al «Resumen de la mañana» del 22-oct).
/// Lo comparten iOS, Android, `/c` y el CLI (`ghosty brief`).
struct DailyDigest: Equatable, Sendable {
    var enabled = true
    var voice = true
    var hour = 7
    var minute = 30
    /// 0 = domingo … 6 = sábado, como `Date.getDay()` en gs.
    var days: [Int] = Self.everyDay
    var timeZone = TimeZone.current.identifier

    static let weekdays = [1, 2, 3, 4, 5]
    static let everyDay = [0, 1, 2, 3, 4, 5, 6]

    init() {}

    /// Tolerante: un gs que todavía no manda `voice`, hora o días deja los defaults.
    init(_ j: [String: Any]) {
        enabled = j["enabled"] as? Bool ?? true
        voice = j["voice"] as? Bool ?? true
        hour = j["hour"] as? Int ?? 7
        minute = j["minute"] as? Int ?? 30
        days = (j["days"] as? [Int]).flatMap { $0.isEmpty ? nil : $0.sorted() } ?? Self.everyDay
        timeZone = j["timeZone"] as? String ?? TimeZone.current.identifier
    }

    /// «7:30 · Todos los días», para el subtítulo del renglón de Perfil.
    var summary: String {
        guard enabled else { return "Apagado" }
        let hora = String(format: "%d:%02d", hour, minute)
        switch days {
        case Self.weekdays: return "\(hora) · L–V"
        case Self.everyDay: return "\(hora) · Todos los días"
        default:
            let letras = ["D", "L", "M", "M", "J", "V", "S"]
            return "\(hora) · " + days.filter { (0...6).contains($0) }.map { letras[$0] }.joined(separator: " ")
        }
    }

    /// Lo que cambió de `a` a `b`: gs acepta subconjuntos. La zona va siempre (quien viaja lo
    /// recibe a SU hora).
    static func patch(from a: DailyDigest, to b: DailyDigest) -> [String: Any] {
        var p: [String: Any] = [:]
        if a.enabled != b.enabled { p["enabled"] = b.enabled }
        if a.voice != b.voice { p["voice"] = b.voice }
        if a.hour != b.hour { p["hour"] = b.hour }
        if a.minute != b.minute { p["minute"] = b.minute }
        if a.days != b.days { p["days"] = b.days }
        p["timeZone"] = TimeZone.current.identifier
        return p
    }
}

/// El cliente de `/me/digest` y del pie del mensaje (`/digest/r/:token`).
enum DailyDigestAPI {
    private static var url: URL { Session.base.appendingPathComponent("api/v2/me/digest") }

    static func load() async throws -> DailyDigest {
        DailyDigest(try await request(url, auth: true))
    }

    static func save(_ patch: [String: Any]) async throws -> DailyDigest {
        DailyDigest(try await request(url, method: "PUT", body: patch, auth: true))
    }

    /// Un toque del pie (`yes|no|off|on`). Sin sesión: la firma del token basta.
    static func react(token: String, action: String) async throws {
        let u = Session.base.appendingPathComponent("api/v2/digest/r").appendingPathComponent(token)
        _ = try await request(u, method: "POST", body: ["a": action], auth: false)
    }

    private static func request(_ url: URL, method: String = "GET", body: [String: Any]? = nil, auth: Bool) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.assumesHTTP3Capable = false
        if auth { req.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization") }
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw GhostyAPI.Fallo.mensaje("Sin conexión. Inténtalo de nuevo.") }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            throw GhostyAPI.Fallo.mensaje((j["detalle"] as? String) ?? (j["error"] as? String) ?? "El servidor contestó \(code).")
        }
        return j
    }
}

/// La preferencia del brief (el renglón de Perfil y su hoja) y lo que ya contestaste en el pie de
/// cada brief. En demo vive sólo en memoria y no toca la red.
@MainActor @Observable
final class DailyDigestStore {
    static let shared = DailyDigestStore()

    /// `nil` hasta leerla (o si gs no la tiene): entonces Perfil no enseña el renglón.
    private(set) var digest: DailyDigest?
    private(set) var saving = false
    var error: String?
    @ObservationIgnored private var loadedAt: Date?

    /// Lo contestado por token (`yes|no|off|on`). Se guarda en el teléfono para que el pie no
    /// vuelva a preguntar al reabrir el hilo.
    private(set) var reactions: [String: String] = DemoData.encendido ? [:]
        : UserDefaults.standard.dictionary(forKey: reactionsKey) as? [String: String] ?? [:]
    private static let reactionsKey = "app.digest.reactions"

    func load(force: Bool = false) async {
        if DemoData.encendido {
            if digest == nil { digest = DailyDigest() }
            return
        }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        do {
            digest = try await DailyDigestAPI.load()
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? GhostyAPI.Fallo)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Optimista: se pinta ya y, si gs dice que no, regresa a lo de antes. Sin botón «Guardar».
    func update(_ change: (inout DailyDigest) -> Void) async {
        guard var nuevo = digest else { return }
        let antes = nuevo
        change(&nuevo)
        guard nuevo != antes else { return }
        digest = nuevo
        if DemoData.encendido { return }
        saving = true
        defer { saving = false }
        do {
            digest = try await DailyDigestAPI.save(DailyDigest.patch(from: antes, to: nuevo))
            error = nil
        } catch {
            digest = antes
            self.error = (error as? GhostyAPI.Fallo)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Un toque del pie, sin salir del chat. Devuelve si gs lo tomó.
    func react(token: String, action: String) async -> Bool {
        if !DemoData.encendido {
            do { try await DailyDigestAPI.react(token: token, action: action) } catch { return false }
        }
        reactions[token] = action
        if !DemoData.encendido { UserDefaults.standard.set(reactions, forKey: Self.reactionsKey) }
        // «Ya no me lo mandes» / «Volver a prenderlo» también cambian el renglón de Perfil.
        if action == "off" || action == "on" { digest?.enabled = action == "on" }
        return true
    }
}
