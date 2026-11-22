import Foundation
import Observation

// «Dev»: los pendientes que un agente trabaja en la nube sobre tus repos (gs `/c/desarrollo`).
// Reemplaza a la pestaña Fábrica (bliss, 22-nov). Una sola fuente: `GET/POST /api/v2/me/dev-runs`,
// la misma de la web y del CLI (`ghosty dev ls|show|merge|resume`). Nada se recalcula distinto aquí:
// las etapas, «listo para merge» y lo que se puede hacer en cada fase calcan `DevRunDetail.tsx`.

/// Las cuatro etapas de un pendiente, las mismas de la web.
enum DevStage: Int, CaseIterable {
    case code, ci, review, merge
    var label: String {
        switch self {
        case .code: "Código"
        case .ci: "CI"
        case .review: "Revisión"
        case .merge: "Merge"
        }
    }
}

struct DevEvent: Identifiable, Hashable {
    let seq: Int
    let kind: String
    let commit: String?
    let at: Date
    let data: [String: Any]
    var id: Int { seq }
    static func == (a: DevEvent, b: DevEvent) -> Bool { a.seq == b.seq && a.kind == b.kind }
    func hash(into h: inout Hasher) { h.combine(seq) }

    /// Cómo se lee en Actividad.
    var label: String {
        switch kind {
        case "started": "Empezó"
        case "pushed": "Subió cambios"
        case "ci_green": "CI en verde"
        case "ci_red": "CI en rojo"
        case "review_clean": "Revisión sin hallazgos"
        case "review_findings": "La revisión encontró algo"
        case "evidence": "Evidencia publicada en el PR"
        case "smoke_green": "Smoke en verde"
        case "smoke_red": "Smoke con fallas"
        case "asked_person": "Te pidió algo"
        case "resumed": "Le mandaste una nota"
        case "merged": "Merge hecho"
        case "stopped": "Lo detuviste"
        case "failed": "Falló"
        case "done": "Listo · sin cambios"
        case "tests_touched": "Tocó pruebas o CI"
        case "budget_exceeded": "Llegó a su tope"
        case "network": "Red de la caja"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct DevRun: Identifiable, Hashable {
    let id: String
    let repo: String
    let issue: Int?
    let title: String
    let phase: String
    let estado: String
    let pr: Int?
    let prURL: URL?
    let commit: String?
    let rounds: Int
    let note: String?
    let createdAt: Date
    let updatedAt: Date
    var events: [DevEvent] = []

    static func == (a: DevRun, b: DevRun) -> Bool { a.id == b.id && a.phase == b.phase && a.updatedAt == b.updatedAt && a.events.count == b.events.count }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let closedPhases: Set<String> = ["merged", "done", "stopped", "failed"]
    var isLive: Bool { !Self.closedPhases.contains(phase) }

    /// Calculados en gs (`?detail=1`): el cliente no decide fases. La lista no los trae: ahí se lee sólo la fase.
    var serverReady: Bool?
    var serverStage: Int?
    var serverCanMerge: Bool?

    /// CI y revisión en verde y sólo falta tu merge.
    var readyToMerge: Bool { serverReady ?? false }
    var canMerge: Bool { serverCanMerge ?? readyToMerge }

    /// En cuál de las cuatro etapas va. Sin dato de gs (la lista), una aproximación por fase.
    var stage: DevStage {
        if let s = serverStage, let st = DevStage(rawValue: min(3, max(0, s))) { return st }
        switch phase {
        case "merged", "merging": return .merge
        case "reviewing": return .review
        case "waiting_ci": return .ci
        default: return .code
        }
    }

    /// El nombre de la fase para la pastilla (el `estado` de gs, salvo «listo»).
    var phaseLabel: String { readyToMerge ? "Listo para merge" : estado }

    enum Tone { case working, needsYou, ready, merged, failed, closed }
    var tone: Tone {
        if readyToMerge { return .ready }
        switch phase {
        case "needs_person": return .needsYou
        case "merged": return .merged
        case "failed": return .failed
        case "done", "stopped": return .closed
        default: return .working
        }
    }

    static func from(json j: [String: Any]) -> DevRun? {
        guard let id = j["id"] as? String, let repo = j["repo"] as? String else { return nil }
        let events = (j["events"] as? [[String: Any]] ?? []).compactMap { e -> DevEvent? in
            guard let seq = e["seq"] as? Int, let kind = e["kind"] as? String else { return nil }
            return DevEvent(seq: seq, kind: kind, commit: e["commit"] as? String,
                            at: DevDate.parse(e["at"] as? String) ?? .now, data: e["data"] as? [String: Any] ?? [:])
        }
        return DevRun(id: id, repo: repo, issue: j["issue"] as? Int, title: j["title"] as? String ?? "Pendiente",
                      phase: j["phase"] as? String ?? "queued", estado: j["estado"] as? String ?? "",
                      pr: j["pr"] as? Int, prURL: (j["prUrl"] as? String).flatMap(URL.init(string:)),
                      commit: j["commit"] as? String, rounds: j["rounds"] as? Int ?? 0,
                      note: (j["note"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                      createdAt: DevDate.parse(j["createdAt"] as? String) ?? .now,
                      updatedAt: DevDate.parse(j["updatedAt"] as? String) ?? .now, events: events,
                      serverReady: j["ready"] as? Bool, serverStage: j["stage"] as? Int, serverCanMerge: j["canMerge"] as? Bool)
    }
}

/// Lo que sólo trae `?detail=1`: cambios, checks, vista previa, deploy, red y el escritor.
struct DevDetail {
    struct FileChange: Identifiable { let file: String; let status: String; let additions: Int; let deletions: Int; let patch: String?; var id: String { file } }
    struct Check: Identifiable { let name: String; let state: String; let url: URL?; let ghosty: Bool; var id: String { name } }
    struct Denied: Identifiable { let host: String; let count: Int; var id: String { host } }
    struct Lighthouse { let performance: Double?; let accessibility: Double?; let bestPractices: Double?; let seo: Double? }
    struct SmokeIssue: Identifiable { let what: String; let whereText: String?; var id: String { what + (whereText ?? "") } }
    struct Finding: Identifiable { let title: String; let file: String?; let line: Int?; var id: String { title + (file ?? "") } }

    var files: [FileChange] = []
    var additions = 0
    var deletions = 0
    var checksState: String?
    var checks: [Check] = []
    var previewPhase: String?
    var previewURL: URL?
    var deploy: [String: Any]?
    var networkMode: String?
    var denied: [Denied] = []
    var writerAgentID: String?
    var writerSessionID: String?
    var writerName: String?

    static func from(json j: [String: Any]) -> DevDetail {
        var d = DevDetail()
        if let c = j["changes"] as? [String: Any] {
            d.additions = c["additions"] as? Int ?? 0
            d.deletions = c["deletions"] as? Int ?? 0
            d.files = (c["files"] as? [[String: Any]] ?? []).compactMap {
                guard let f = $0["file"] as? String else { return nil }
                return FileChange(file: f, status: $0["status"] as? String ?? "modified", additions: $0["additions"] as? Int ?? 0,
                                  deletions: $0["deletions"] as? Int ?? 0, patch: $0["patch"] as? String)
            }
        }
        if let c = j["checks"] as? [String: Any] {
            d.checksState = c["state"] as? String
            d.checks = (c["checks"] as? [[String: Any]] ?? []).compactMap {
                guard let n = $0["name"] as? String else { return nil }
                return Check(name: n, state: $0["state"] as? String ?? "none", url: ($0["url"] as? String).flatMap(URL.init(string:)), ghosty: $0["ghosty"] as? Bool ?? false)
            }
        }
        if let p = j["preview"] as? [String: Any] {
            d.previewPhase = p["phase"] as? String
            d.previewURL = (p["link"] as? String).flatMap(URL.init(string:))
        }
        d.deploy = j["deploy"] as? [String: Any]
        if let n = j["network"] as? [String: Any] {
            d.networkMode = n["mode"] as? String
            // El firewall anota por IP: el mismo host sale varias veces. Una pastilla por host.
            var seen = Set<String>()
            d.denied = (n["denied"] as? [[String: Any]] ?? []).compactMap {
                guard let h = $0["host"] as? String, !h.isEmpty, seen.insert(h).inserted else { return nil }
                return Denied(host: h, count: $0["count"] as? Int ?? 1)
            }
        }
        if let w = j["writer"] as? [String: Any] {
            d.writerAgentID = w["agentId"] as? String
            d.writerSessionID = w["sessionId"] as? String
            d.writerName = w["name"] as? String
        }
        return d
    }

    /// El deploy tras el merge: «desplegando», «en producción» o «falló» (`deploy.ts` de gs).
    var deployLabel: (text: String, ok: Bool?)? {
        guard let s = deploy?["state"] as? String else { return nil }
        switch s {
        case "success": return ("En producción", true)
        case "failure": return ("Falló el deploy", false)
        case "pending": return ("Desplegando", nil)
        case "cancelled": return ("Deploy cancelado", false)
        case "timeout": return ("El deploy no terminó", false)
        default: return nil
        }
    }
}

/// El último reporte del smoke (evento `smoke_green|smoke_red`): rutas, problemas de la página y Lighthouse.
struct DevSmoke {
    let green: Bool
    let issues: [DevDetail.SmokeIssue]
    let failedSteps: [String]
    let lighthouse: DevDetail.Lighthouse?

    static func latest(in events: [DevEvent]) -> DevSmoke? {
        guard let e = events.last(where: { $0.kind == "smoke_green" || $0.kind == "smoke_red" }) else { return nil }
        let page = e.data["page"] as? [String: Any]
        let issues = (page?["issues"] as? [[String: Any]] ?? []).compactMap { i -> DevDetail.SmokeIssue? in
            guard let w = i["what"] as? String else { return nil }
            return .init(what: w, whereText: i["where"] as? String)
        }
        let steps = (e.data["steps"] as? [[String: Any]] ?? []).filter { ($0["ok"] as? Bool) == false }.map {
            "\($0["method"] as? String ?? "GET") \($0["path"] as? String ?? "/") · \($0["why"] as? String ?? "")"
        }
        var lh: DevDetail.Lighthouse?
        if let l = e.data["lighthouse"] as? [String: Any] {
            lh = .init(performance: l["performance"] as? Double, accessibility: l["accessibility"] as? Double,
                       bestPractices: l["bestPractices"] as? Double, seo: l["seo"] as? Double)
        }
        return DevSmoke(green: e.kind == "smoke_green", issues: issues, failedSteps: steps, lighthouse: lh)
    }
}

enum DevDate {
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    static func ago(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: .now)
    }
}

@MainActor @Observable
final class DevStore {
    static let shared = DevStore()

    private(set) var runs: [DevRun] = []
    private(set) var loaded = false
    private(set) var error: String?
    /// Detalles ya leídos: abrir un pendiente pinta lo de la vez pasada y luego refresca (como la web).
    private(set) var details: [String: DevDetail] = [:]
    private(set) var full: [String: DevRun] = [:]
    /// Abrir un pendiente desde fuera (push del escritor).
    var pendingRunID: String?

    var needsYouCount: Int { runs.filter { $0.tone == .needsYou }.count }

    /// ¿La GitHub App de gs llega a algún repo tuyo? `nil` = todavía no se sabe.
    private(set) var hasGitHub: Bool?
    /// La pestaña sale sólo con GitHub conectado (con al menos un repo) o con pendientes que ver (bliss, 22-nov).
    var available: Bool { hasGitHub == true || !runs.isEmpty }

    /// Lo que decide si la pestaña existe: repos de la GitHub App + la lista. Falla callado.
    func refreshAvailability() async {
        if let j = try? await request("api/v2/me/dev-runs/repos") as? [String: Any] {
            hasGitHub = (j["installed"] as? Bool) == true && !((j["repos"] as? [Any]) ?? []).isEmpty
        } else if hasGitHub == nil {
            hasGitHub = false
        }
        await refresh()
    }

    func refresh() async {
        do {
            let j = try await request("api/v2/me/dev-runs", query: [URLQueryItem(name: "all", value: "1")])
            // La lista llega como arreglo (CLI) o como `{ runs }`.
            let list = (j as? [[String: Any]]) ?? ((j as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
            runs = list.compactMap(DevRun.from(json:))
            error = nil
        } catch {
            if !loaded { self.error = "No pude cargar tus pendientes." }
        }
        loaded = true
    }

    func loadDetail(_ id: String) async {
        guard let j = try? await request("api/v2/me/dev-runs/\(id)", query: [URLQueryItem(name: "detail", value: "1")]) as? [String: Any] else { return }
        if let run = DevRun.from(json: j) {
            full[id] = run
            if let i = runs.firstIndex(where: { $0.id == id }) { runs[i] = run }
        }
        let d = DevDetail.from(json: j)
        details[id] = d
    }

    /// `merge` | `resume` (con nota) | `stop`. Devuelve el error para la UI, `nil` si salió.
    func act(_ id: String, op: String, note: String? = nil) async -> String? {
        var body: [String: Any] = ["op": op, "from": "ios"]
        if let note, !note.isEmpty { body["note"] = note }
        do {
            let j = try await request("api/v2/me/dev-runs/\(id)", method: "POST", body: body) as? [String: Any]
            if let err = j?["error"] as? String, !err.isEmpty, (j?["ok"] as? Bool) != true, j?["phase"] == nil { return (j?["message"] as? String) ?? err }
            await loadDetail(id)
            return nil
        } catch {
            return (error as? DevError)?.message ?? "No se pudo. Intenta otra vez."
        }
    }

    struct DevError: Error { let message: String }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Any {
        var c = URLComponents(url: Session.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        guard let url = c.url else { throw DevError(message: "URL inválida") }
        let token = try await Session.accessToken()
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.assumesHTTP3Capable = false
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(code) else {
            let msg = ((json as? [String: Any])?["message"] as? String) ?? ((json as? [String: Any])?["error"] as? String) ?? "Error \(code)"
            throw DevError(message: msg)
        }
        return json ?? [:]
    }
}
