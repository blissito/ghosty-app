import Foundation
import Observation

// «Dev»: los pendientes que un agente trabaja en la nube sobre tus repos (gs `/c/desarrollo`).
// Reemplaza a la pestaña Fábrica (bliss, 22-nov). Una sola fuente: `GET/POST /api/v2/me/dev-runs`,
// la misma de la web y del CLI (`ghosty dev ls|show|merge|resume`). Nada se recalcula distinto aquí:
// la columna (`column`) y la pastilla (`status.label` / `status.category`) las calcula gs en un solo sitio
// (`board-status.ts`) y aquí sólo se pintan; `phase`/`stage` quedan de respaldo para servidores viejos.

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

    /// Una fila de Actividad: el evento más reciente de una racha igual (mismo tipo y commit).
    struct Group: Identifiable { let event: DevEvent; let count: Int; var id: Int { event.seq } }

    /// Junta los consecutivos iguales («Smoke en verde ×5»). Recibe los eventos en el orden en que se pintan.
    static func grouped<S: Sequence>(_ events: S) -> [Group] where S.Element == DevEvent {
        var out: [Group] = []
        for e in events {
            if let last = out.last, last.event.kind == e.kind, last.event.commit == e.commit {
                out[out.count - 1] = Group(event: last.event, count: last.count + 1)
            } else {
                out.append(Group(event: e, count: 1))
            }
        }
        return out
    }

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

/// La pregunta que el escritor dejó sin responder (`asked` de gs, fase `needs_person`): con opciones salen como botones.
struct DevAsk: Hashable {
    let question: String
    let options: [String]
    let reason: String?

    /// Lo que se manda con «Decide tú» (el mismo texto que la web).
    static let decideForMe = "No quiero decidir esto: decide tú con tu mejor criterio, dime qué elegiste y sigue."

    /// `question` puede venir nulo (p. ej. «se detuvo»): entonces la pregunta es la nota del run.
    static func from(json j: Any?, note: String? = nil) -> DevAsk? {
        guard let d = j as? [String: Any] else { return nil }
        let given = (d["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = (given?.isEmpty == false ? given : nil) ?? note ?? "El agente espera tu respuesta."
        // Las opciones llegan como textos o como `{id, label}`; sin duplicados ni vacías.
        var seen = Set<String>()
        let opts = (d["options"] as? [Any] ?? []).compactMap { o -> String? in
            let t = (o as? String) ?? ((o as? [String: Any]).flatMap { ($0["label"] ?? $0["name"] ?? $0["text"]) as? String })
            guard let t = t?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, seen.insert(t).inserted else { return nil }
            return t
        }
        return DevAsk(question: q, options: opts, reason: d["reason"] as? String)
    }
}

struct DevRun: Identifiable, Hashable {
    let id: String
    let repo: String
    let issue: Int?
    let title: String
    let phase: String
    var estado: String
    let pr: Int?
    let prURL: URL?
    let commit: String?
    let rounds: Int
    let note: String?
    /// El PR que bloquea a este run (`phase == "blocked"`, «Esperando #N»).
    var blockedBy: Int? = nil
    /// La pregunta pendiente del escritor, con sus opciones.
    var asked: DevAsk? = nil
    let createdAt: Date
    let updatedAt: Date
    var events: [DevEvent] = []

    // SwiftUI repinta una tarjeta sólo si su `==` cambia: tienen que entrar los datos que se corrigen con el detalle.
    static func == (a: DevRun, b: DevRun) -> Bool {
        a.id == b.id && a.phase == b.phase && a.updatedAt == b.updatedAt && a.events.count == b.events.count
            && a.estado == b.estado && a.column == b.column && a.statusLabel == b.statusLabel && a.serverReady == b.serverReady && a.serverCanMerge == b.serverCanMerge
            && a.serverStage == b.serverStage && a.statusCategory == b.statusCategory && a.blockedBy == b.blockedBy && a.asked == b.asked
    }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Bumps de bots y repos retirados del factory: no se muestran (bliss, 23-nov: ghosty-studio y easybits arrancan de cero).
    var isHiddenHistory: Bool {
        title.hasPrefix("Bump ") || ["ghosty-studio", "easybits"].contains(repo.split(separator: "/").last.map(String.init) ?? repo)
    }
    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    static let closedPhases: Set<String> = ["merged", "done", "stopped", "failed"]
    var isLive: Bool { !Self.closedPhases.contains(phase) }

    /// Calculados en gs (`?detail=1`): el cliente no decide fases. La lista no los trae: ahí se lee sólo la fase.
    var serverReady: Bool?
    var serverStage: Int?
    var serverCanMerge: Bool?

    /// Columna del tablero que manda gs: todo | writing | review | ready | done | halted. Un valor nuevo no esconde la tarjeta.
    var column: String?

    /// Un PR sin DevRun (escrito en una terminal o por una persona): tarjeta `prs` de gs, id `pr:<repo>#<n>`.
    /// No tiene chat ni Merge desde aquí: el merge se hace en GitHub.
    var isPR = false
    /// Lo que gs dice que pasa ahora (`status.label` de la tarjeta, en todo pendiente y PR): «CI falló: Prueba en vivo».
    var statusLabel: String?
    /// not_started | in_progress | needs_action | failed | ready | done (otro valor cae a un tono neutro).
    var statusCategory: String?

    /// Con `column` del servidor sólo `done` y `halted` salen del tablero; un valor desconocido sigue a la vista.
    var isOnBoard: Bool {
        if let c = column { return c != "done" && c != "halted" }
        return isLive
    }

    /// CI y revisión en verde y sólo falta tu merge (habilita los botones; el texto lo dice `phaseLabel`).
    var readyToMerge: Bool { isPR ? isLive && (statusCategory == "ready" || serverReady == true) : (serverReady ?? false) }
    var canMerge: Bool { isPR ? false : (serverCanMerge ?? readyToMerge) }

    static let knownColumns = ["ready", "review", "writing", "todo", "done", "halted"]

    /// La columna de la tarjeta: la del servidor ("other" si es una nueva); sólo sin ella (gs viejo) se aproxima por fase.
    var boardColumn: String {
        if let c = column { return Self.knownColumns.contains(c) ? c : "other" }
        switch phase {
        case "stopped", "failed": return "halted"
        case "merged", "done": return "done"
        default: break
        }
        if readyToMerge { return "ready" }
        if pr != nil { return "review" }
        return ["queued", "blocked"].contains(phase) ? "todo" : "writing"
    }

    /// En cuál de las cuatro etapas va. Con `column` del servidor manda; `stage` (deprecado) sólo la afina en revisión.
    var stage: DevStage {
        switch column {
        case "todo", "writing", "halted": return .code
        case "ready", "done": return .merge
        default: break
        }
        if let s = serverStage, let st = DevStage(rawValue: min(3, max(0, s))) { return st }
        switch phase {
        case "merged", "merging": return .merge
        case "reviewing": return .review
        case "waiting_ci": return .ci
        default: return .code
        }
    }

    /// El texto de la pastilla: el `status.label` de gs, tal cual. Sin él (gs viejo) el `estado` de la lista.
    var phaseLabel: String {
        if let l = statusLabel, !l.isEmpty { return l }
        if !estado.isEmpty { return estado }
        return readyToMerge ? "Listo para merge" : phase.replacingOccurrences(of: "_", with: " ").capitalized
    }

    enum Tone { case working, needsYou, ready, merged, failed, closed }
    /// El color sale de `status.category`; una categoría desconocida cae a gris neutro (`closed`) y conserva el `label` del servidor.
    var tone: Tone {
        if let c = statusCategory {
            switch c {
            case "in_progress": return .working
            case "needs_action": return .needsYou
            case "failed": return .failed
            case "ready": return .ready
            case "done": return .merged
            default: return .closed
            }
        }
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
                      serverReady: j["ready"] as? Bool, serverStage: j["stage"] as? Int, serverCanMerge: j["canMerge"] as? Bool,
                      column: j["column"] as? String,
                      isPR: (j["kind"] as? String) == "pr",
                      statusLabel: (j["status"] as? [String: Any])?["label"] as? String,
                      statusCategory: (j["status"] as? [String: Any])?["category"] as? String)
        .withBlockedBy((j["blockedBy"] as? [String: Any])?["pr"] as? Int)
        .withAsked(DevAsk.from(json: j["asked"], note: (j["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
    }

    fileprivate func withAsked(_ a: DevAsk?) -> DevRun { var r = self; r.asked = a; return r }

    fileprivate func withBlockedBy(_ n: Int?) -> DevRun { var r = self; r.blockedBy = n; return r }

    /// Detenido con su PR todavía abierto: se puede retomar (`reopen`, misma rama, caja nueva).
    var canReopen: Bool { phase == "stopped" && pr != nil && !isPR }
    /// Esperando a otro PR: se puede soltar la espera sin cerrarlo (`resume` sin nota).
    var isBlocked: Bool { phase == "blocked" }

    /// Una tarjeta `prs` de la lista: PR abierto (o recién cerrado) sin DevRun vivo.
    static func from(card j: [String: Any]) -> DevRun? {
        guard let id = j["id"] as? String, let repo = j["repo"] as? String, let pr = j["pr"] as? Int else { return nil }
        let closed = j["closed"] as? [String: Any]
        let status = j["status"] as? [String: Any]
        let updated = DevDate.parse(j["updatedAt"] as? String) ?? .distantPast
        return DevRun(id: id, repo: repo, issue: j["issue"] as? Int, title: j["title"] as? String ?? "PR #\(pr)",
                      phase: closed == nil ? "pr_open" : ((closed?["merged"] as? Bool) == true ? "merged" : "stopped"),
                      estado: status?["label"] as? String ?? "", pr: pr, prURL: (j["url"] as? String).flatMap(URL.init(string:)),
                      commit: (j["sha"] as? String).map { String($0.prefix(7)) }, rounds: 0, note: nil,
                      createdAt: updated, updatedAt: updated,
                      serverStage: j["stage"] as? Int, column: j["column"] as? String, isPR: true,
                      statusLabel: status?["label"] as? String, statusCategory: status?["category"] as? String)
    }

    /// El issue en GitHub (`repo` llega como `owner/nombre`).
    var issueURL: URL? {
        guard let n = issue, n > 0, repo.contains("/") else { return nil }
        return URL(string: "https://github.com/\(repo)/issues/\(n)")
    }

    /// El id de la tarjeta de un PR (el mismo que arma gs en `prCardId`).
    static func prID(repo: String, pr: Int) -> String { "pr:\(repo.lowercased())#\(pr)" }
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
    var deploy: [String: Any]?
    var networkMode: String?
    var denied: [Denied] = []
    var writerAgentID: String?
    var writerSessionID: String?
    var writerName: String?
    /// Comentarios del PR (sólo PRs sin DevRun: no hay chat con un agente).
    var thread: [Comment] = []
    /// Hallazgos de la revisión de Ghosty en el commit actual (PRs sin DevRun).
    var findings: Int?
    struct Comment: Identifiable { let id: Int; let by: String; let bot: Bool; let text: String; let at: Date? }
    /// La mesa de trabajo de gs (`ficha`): la misma que ven el escritor, GitHub y Teams. Los estados
    /// (ci, review, smoke, evidence, preview) se leen de aquí; el cliente no los deduce.
    var sheet: Sheet?

    struct Sheet {
        /// ok | bad | running | none
        var ci = "none", review = "none", smoke = "none"
        var evidence = false
        /// ready | building | failed | none
        var previewState = "none"
        var previewURL: URL?
        var previewError: String?
        /// Lo que la persona pidió desde el último push y sigue abierto.
        var asks: [String] = []
    }

    static func from(json j: [String: Any]) -> DevDetail {
        var d = DevDetail()
        if let f = j["ficha"] as? [String: Any] {
            var sh = Sheet()
            sh.ci = f["ci"] as? String ?? "none"
            sh.review = f["review"] as? String ?? "none"
            sh.smoke = f["smoke"] as? String ?? "none"
            sh.evidence = f["evidence"] as? Bool ?? false
            if let p = f["preview"] as? [String: Any] {
                sh.previewState = p["state"] as? String ?? "none"
                sh.previewURL = (p["url"] as? String).flatMap(URL.init(string:))
                sh.previewError = p["error"] as? String
            }
            sh.asks = f["asks"] as? [String] ?? []
            d.sheet = sh
        }
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
                // Las puertas de ghosty-dev (`ghosty-dev/evidencia`, `ghosty-dev/redisparo`) son de Ghosty aunque corran en Actions.
                return Check(name: n, state: $0["state"] as? String ?? "none", url: ($0["url"] as? String).flatMap(URL.init(string:)), ghosty: ($0["ghosty"] as? Bool ?? false) || n.hasPrefix("ghosty-dev/"))
            }
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
        // Un PR sin DevRun no trae ficha: sus cuatro estados salen de los checks, la revisión y la vista previa.
        if d.sheet == nil, (j["kind"] as? String) == "pr" {
            var sh = Sheet()
            // El CI es el del repo: sin los checks de Ghosty ni sus puertas (`ghosty-dev/*`, que son la evidencia).
            // `checks.state` de gs no sirve aquí: dice «success» con la puerta de evidencia en rojo (#101, 22-nov).
            let repoCI = d.checks.filter { !$0.ghosty && $0.state != "neutral" && $0.state != "skipped" }
            sh.ci = repoCI.isEmpty ? "none"
                : repoCI.contains { $0.state == "failure" || $0.state == "error" } ? "bad"
                : repoCI.allSatisfy { $0.state == "success" } ? "ok" : "running"
            if let r = j["review"] as? [String: Any] {
                let n = (r["findings"] as? [Any])?.count ?? 0
                d.findings = n
                sh.review = switch r["state"] as? String { case "clean": "ok"; case "findings": "bad"; case "running", "pending": "running"; default: n > 0 ? "bad" : "none" }
            }
            if let p = j["previewInfo"] as? [String: Any] {
                sh.previewState = p["state"] as? String ?? "none"
                sh.previewError = p["note"] as? String
            }
            sh.previewURL = ((j["preview"] as? [String: Any])?["link"] as? String).flatMap(URL.init(string:))
            d.sheet = sh
            d.thread = (j["thread"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? Int, let t = $0["text"] as? String else { return nil }
                return Comment(id: id, by: $0["by"] as? String ?? "", bot: $0["bot"] as? Bool ?? false, text: t, at: DevDate.parse($0["at"] as? String))
            }
        }
        if let w = j["writer"] as? [String: Any] {
            d.writerAgentID = w["agentId"] as? String
            d.writerSessionID = w["sessionId"] as? String
            d.writerName = w["name"] as? String
        }
        return d
    }

    /// Algún check del commit (de Ghosty o del repo) en rojo o corriendo; los neutrales y omitidos no cuentan.
    var checksBlockMerge: Bool {
        checks.contains { ["failure", "error", "pending"].contains($0.state) }
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
    /// Problemas ya redactados para pintar: pasos fallidos y fallas de la página con su ruta.
    var problems: [String] { failedSteps + issues.map { i in i.whereText.map { "\(i.what) · \($0)" } ?? i.what } }
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

/// Un pendiente que alguien trabaja en SU terminal con ghosty-dev (Claude Code, Cursor, Codex).
/// Vive en el issue de GitHub: gs no tiene su detalle ni su chat, así que tocarlo abre GitHub.
struct DevLocalRun: Identifiable {
    let id: String
    let repo: String
    let issue: Int
    let title: String
    let url: URL?
    let writer: String?
    let phase: String  // "working" | "waiting_ci"
    let pr: Int?
    let prURL: URL?
    let updatedAt: Date
    /// Lo que gs calcula para el pendiente de terminal (`column`, `status`); sin ellos se usa `phase`.
    var column: String? = nil
    var statusLabel: String? = nil

    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    /// Un issue que nadie ha empezado: sale en «Pendientes», no en «En una terminal».
    var notStarted: Bool { column.map { $0 == "todo" } ?? (phase != "working" && phase != "waiting_ci") }
    /// Lo que se abre al tocarlo: el PR si ya existe, si no el issue.
    var openURL: URL? { prURL ?? url }
    var phaseLabel: String {
        if let l = statusLabel, !l.isEmpty { return l }
        switch phase {
        case "waiting_ci": return "Esperando CI"
        case "working": return "Trabajando"
        default: return "En cola"
        }
    }
    /// Con PR, se abre su detalle dentro de la app; sin PR sólo existe el issue en GitHub.
    var prID: String? { pr.map { DevRun.prID(repo: repo, pr: $0) } }

    static func from(json j: [String: Any]) -> DevLocalRun? {
        guard let id = j["id"] as? String, let repo = j["repo"] as? String else { return nil }
        return DevLocalRun(id: id, repo: repo, issue: j["issue"] as? Int ?? 0,
                           title: j["title"] as? String ?? "Pendiente",
                           url: (j["url"] as? String).flatMap(URL.init(string:)),
                           writer: j["writer"] as? String,
                           phase: j["phase"] as? String ?? "working",
                           pr: j["pr"] as? Int,
                           prURL: (j["prUrl"] as? String).flatMap(URL.init(string:)),
                           updatedAt: DevDate.parse(j["updatedAt"] as? String) ?? .distantPast,
                           column: j["column"] as? String,
                           statusLabel: (j["status"] as? [String: Any])?["label"] as? String)
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
    /// PRs sin DevRun vivo (los de una terminal o de una persona), con su detalle dentro de la app.
    private(set) var prs: [DevRun] = []
    private(set) var loaded = false
    private(set) var error: String?
    /// Detalles ya leídos: abrir un pendiente pinta lo de la vez pasada y luego refresca (como la web).
    private(set) var details: [String: DevDetail] = [:]
    private(set) var full: [String: DevRun] = [:]
    /// Abrir un pendiente desde fuera (push del escritor).
    var pendingRunID: String?

    var needsYouCount: Int { runs.filter { $0.isOnBoard && $0.tone == .needsYou }.count }

    /// ¿La GitHub App de gs llega a algún repo tuyo? `nil` = todavía no se sabe.
    private(set) var hasGitHub: Bool?
    /// La pestaña sale sólo con GitHub conectado (con al menos un repo) o con pendientes que ver (bliss, 22-nov).
    var available: Bool { hasGitHub == true || !runs.isEmpty || !prs.isEmpty || !local.isEmpty }
    /// Los que se trabajan en la terminal de alguien (siempre vivos: gs sólo manda los abiertos).
    private(set) var local: [DevLocalRun] = []

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
            // Gancho: `GHOSTY_DEV_EMPTY=1` pinta la lista sin pendientes (para revisar el vacío).
            let empty = Gancho.encendido("GHOSTY_DEV_EMPTY")
            runs = empty ? [] : list.compactMap(DevRun.from(json:))
            // Gancho: `GHOSTY_DEV_ASK=1` le pone una pregunta con opciones al primer pendiente que te necesita
            // (hasta que gs mande `asked` real; sirve para ver los botones en el teléfono).
            if Gancho.encendido("GHOSTY_DEV_ASK"), let i = runs.firstIndex(where: { $0.tone == .needsYou && $0.asked == nil }) {
                runs[i].asked = Self.demoAsk
                demoAskID = runs[i].id
            }
            local = empty ? [] : (((j as? [String: Any])?["local"] as? [[String: Any]]) ?? []).compactMap(DevLocalRun.from(json:))
            prs = empty ? [] : (((j as? [String: Any])?["prs"] as? [[String: Any]]) ?? []).compactMap(DevRun.from(card:))
            error = nil
        } catch {
            if !loaded { self.error = "No pude cargar tus pendientes." }
        }
        loaded = true
        // La lista de gs no trae los checks y puede decir «listo» con el CI en rojo: se confirma en el detalle.
        let ready = (runs + prs).filter { $0.isLive && $0.readyToMerge }.map(\.id)
        for id in ready.prefix(8) { await loadDetail(id) }
    }

    private static let demoAsk = DevAsk(question: "¿Esto lo mergeo a main o lo dejo en la rama para que lo veas primero?",
                                        options: ["Merge a main", "Dejarlo en la rama", "Cerrar sin PR"], reason: nil)
    /// Pendiente al que el gancho `GHOSTY_DEV_ASK` le puso la pregunta de prueba.
    private var demoAskID: String?

    /// Un pendiente de la lista, de cualquier tipo.
    func row(_ id: String) -> DevRun? { runs.first { $0.id == id } ?? prs.first { $0.id == id } }

    func loadDetail(_ id: String) async {
        let path: String
        if id.hasPrefix("pr:"), let hash = id.lastIndex(of: "#") {
            // `pr:<owner>/<name>#<n>` → `pr/<owner>/<name>/<n>` (mismo detalle que la web `/c/dev/pr/...`).
            path = "api/v2/me/dev-runs/pr/\(id[id.index(id.startIndex, offsetBy: 3)..<hash])/\(id[id.index(after: hash)...])"
        } else {
            path = "api/v2/me/dev-runs/\(id)"
        }
        guard let j = try? await request(path, query: [URLQueryItem(name: "detail", value: "1")]) as? [String: Any] else { return }
        let d = DevDetail.from(json: j)
        if var run = DevRun.from(json: j) {
            // Si el detalle no trae `status`/`column` (gs viejo), se conservan los de la lista.
            if let card = prs.first(where: { $0.id == id }) ?? runs.first(where: { $0.id == id }) {
                if run.statusLabel == nil { run.statusLabel = card.statusLabel; run.statusCategory = card.statusCategory }
                if run.column == nil { run.column = card.column }
            }
            // Un check del commit en rojo o corriendo apaga el botón de merge (gs lo rechaza: «El CI sigue corriendo»,
            // #114 de formmy). Sólo se deshabilita la acción; el texto y la columna son los del servidor.
            if d.checksBlockMerge {
                run.serverReady = false
                run.serverCanMerge = false
            }
            if id == demoAskID { run.asked = Self.demoAsk }
            full[id] = run
            if let i = runs.firstIndex(where: { $0.id == id }) { runs[i] = run }
            else if let i = prs.firstIndex(where: { $0.id == id }) {
                // La tarjeta de un PR conserva su «qué pasa ahora», pero toma la corrección de los checks.
                prs[i].serverReady = run.serverReady
                prs[i].serverCanMerge = run.serverCanMerge
                prs[i].statusLabel = run.statusLabel
                prs[i].statusCategory = run.statusCategory
                prs[i].column = run.column
                prs[i].estado = run.estado
                prs[i].serverStage = run.serverStage
            }
        }
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
