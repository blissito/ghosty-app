import Foundation

// La Software Factory de un espacio, vista desde el teléfono: los pedidos (`runs`), su plan y
// las decisiones que le tocan a una persona (firmar el plan, decidir un escalado, merge).
//
// Contrato de gs (19-oct, el mismo que usa `ghosty factory`):
//   GET  /api/v2/workspaces                                   → tus espacios
//   GET  /api/v2/workspaces/:slug/factory/runs?limit=30       → pedidos
//   GET  /api/v2/workspaces/:slug/factory/runs/:id            → pedido con plan, bitácora y quién trabaja
//   POST /api/v2/workspaces/:slug/factory/runs/:id/act        → approve | changes | merge | card
//   POST /api/v2/workspaces/:slug/factory/runs                → pedido nuevo («@plan …» en el room)
// Auth: el mismo bearer OAuth de la app (`agents:read`/`agents:write`); nunca el `gat_` de un agente.
// Va en `Core/` a propósito: la app Work (Teams) la va a querer igual.

/// Un valor JSON cualquiera: los `data` de la bitácora cambian de forma según el evento.
enum FactoryJSON: Decodable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: FactoryJSON]), array([FactoryJSON]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([FactoryJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: FactoryJSON].self)) }
    }

    subscript(_ key: String) -> FactoryJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// Las etapas de un pedido, con lo que la app necesita saber de cada una.
enum FactoryStage: String {
    case planning, planReview = "plan_review", building, checking, escalated
    case prReview = "pr_review", done, cancelled, unknown

    init(_ raw: String) { self = FactoryStage(rawValue: raw) ?? .unknown }

    /// Le toca a una persona: firmar, decidir o mergear.
    var needsYou: Bool { [.planReview, .escalated, .prReview].contains(self) }
    /// Un agente tiene la estafeta.
    var working: Bool { [.planning, .building, .checking].contains(self) }
    var closed: Bool { self == .done || self == .cancelled }

    var label: String {
        switch self {
        case .planning:   "Planeando"
        case .planReview: "Firma el plan"
        case .building:   "Construyendo"
        case .checking:   "Revisando"
        case .escalated:  "Te toca decidir"
        case .prReview:   "PR listo"
        case .done:       "Terminado"
        case .cancelled:  "Cancelado"
        case .unknown:    "—"
        }
    }

    /// En qué paso de la barra va (Plan 0 · Aprobación 1 · Build 2 · Check 3 · PR 4).
    var step: Int {
        switch self {
        case .planning: 0
        case .planReview: 1
        case .building: 2
        case .checking, .escalated: 3
        case .prReview, .done: 4
        case .cancelled, .unknown: -1
        }
    }
}

/// Por qué un pedido escaló y qué lo resuelve (gs `escalation`, 20-oct). Antes la tarjeta decía «Te
/// toca decidir» sin decir qué: de los 8 escalados de easybits, 5 eran la preview atorada —falla
/// de la plataforma, nada que decidir— y los otros 3 pedían botones distintos.
struct FactoryEscalation: Decodable, Hashable {
    enum Kind: String {
        /// Faltan variables o credenciales: las da la persona y @check revisa otra vez.
        case env
        /// @build lo puede arreglar en la rama.
        case fix
        /// Este bump no conviene: cerrar (e ignorar la versión).
        case skip
        /// Una persona elige.
        case decision
        /// Falla de la plataforma (la preview no arranca): no te toca, se reintenta sola.
        case platform
    }

    /// La ficha de decisión (gs `escalation.brief`, 21-oct): qué pasa en una frase, lo que el agente
    /// ya verificó, qué conviene y por qué, y la pregunta que de verdad queda para la persona. Así la
    /// tarjeta deja de enseñar los hallazgos crudos de @check como si fueran la decisión.
    struct Brief: Decodable, Hashable {
        struct Recommend: Decodable, Hashable {
            /// `fix` | `replan` | `close` | `close_ignore` | `recheck` | `env` | `retry_preview`.
            let action: String
            let why: String?
        }
        let summary: String?
        let verified: [String]
        let recommend: Recommend?
        let question: String?
        let at: String?

        init(summary: String?, verified: [String], recommend: Recommend?, question: String?, at: String?) {
            self.summary = summary; self.verified = verified; self.recommend = recommend
            self.question = question; self.at = at
        }

        // Tolerante: un campo con otra forma se ignora, nunca tumba el pedido entero.
        private enum CodingKeys: String, CodingKey { case summary, verified, recommend, question, at }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? nil
            verified = ((try? c.decodeIfPresent([String].self, forKey: .verified)) ?? nil) ?? []
            recommend = (try? c.decodeIfPresent(Recommend.self, forKey: .recommend)) ?? nil
            question = (try? c.decodeIfPresent(String.self, forKey: .question)) ?? nil
            at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? nil
        }

        /// Algo que enseñar: sin resumen ni recomendación, la tarjeta se queda como antes.
        var usable: Bool {
            !(summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recommend != nil
        }
    }

    let kind: String?
    let reason: String?
    let points: [String]?
    let findings: String?
    let at: String?
    let actions: [String]?
    /// gs viejo no la manda; null o con otra forma = sin ficha.
    let brief: Brief?

    init(kind: String?, reason: String?, points: [String]?, findings: String?, at: String?, actions: [String]?,
         brief: Brief? = nil) {
        self.kind = kind; self.reason = reason; self.points = points; self.findings = findings
        self.at = at; self.actions = actions; self.brief = brief
    }

    private enum CodingKeys: String, CodingKey { case kind, reason, points, findings, at, actions, brief }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        points = try c.decodeIfPresent([String].self, forKey: .points)
        findings = try c.decodeIfPresent(String.self, forKey: .findings)
        at = try c.decodeIfPresent(String.self, forKey: .at)
        actions = try c.decodeIfPresent([String].self, forKey: .actions)
        brief = ((try? c.decodeIfPresent(Brief.self, forKey: .brief)) ?? nil).flatMap { $0.usable ? $0 : nil }
    }

    var type: Kind { kind.flatMap(Kind.init) ?? .decision }

    var label: String {
        switch type {
        case .env:      "Faltan variables"
        case .fix:      "@build lo puede arreglar"
        case .skip:     "No conviene"
        case .decision: "Te toca decidir"
        case .platform: "Esperando preview"
        }
    }
}

/// La preview de un pedido abierto que no está lista (gs `previewStatus`, 20-oct): en camino,
/// esperando lugar de caja o fallida, en CUALQUIER etapa. El #131 de easybits pasó horas en revisión
/// con la preview atorada, sin escalado, y la app no ofrecía nada. `stuck` = ofrecer «Reintentar».
struct FactoryPreviewStatus: Decodable, Hashable {
    /// `pending` | `waiting` | `failed` | `needs_env`.
    let state: String
    let since: String?
    let minutes: Int?
    /// «Esperando lugar de caja (3 ocupados)», «Falló: …», «Lleva 40 min en camino».
    let reason: String
    let stuck: Bool

    var failed: Bool { state == "failed" }
}

/// La nota de lugar de un pedido (gs `slotNote`, 21-oct, «cortesía de lugar»): el plan no tenía
/// lugar y gs prestó la caja una vez en el mes (`courtesy`), o el pedido espera en la fila
/// (`queued`) porque la cortesía ya se usó. No es un error: dice quién ocupa cada lugar y lleva a
/// los planes. Todo opcional: un campo que falte no tumba el pedido entero.
struct FactorySlotNote: Decodable, Hashable {
    struct Occupant: Decodable, Hashable {
        let label: String
        let detail: String?

        init(label: String, detail: String?) { self.label = label; self.detail = detail }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? "—"
            detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        }
        private enum CodingKeys: String, CodingKey { case label, detail }
    }

    /// `courtesy` | `queued`.
    let kind: String
    let title: String
    let message: String
    let occupants: [Occupant]
    /// En la fila: 1 = el siguiente.
    let position: Int?
    /// Los pedidos que van delante en la fila.
    let ahead: [Int]
    /// «Cortesía usada · se renueva el 1-nov».
    let chip: String?
    /// Tres meses seguidos con cortesía: el botón dice «Subir de plan».
    let suggestUpgrade: Bool
    let plansUrl: String?

    var queued: Bool { kind == "queued" }

    init(kind: String, title: String, message: String, occupants: [Occupant], position: Int?, ahead: [Int],
         chip: String?, suggestUpgrade: Bool, plansUrl: String?) {
        self.kind = kind; self.title = title; self.message = message; self.occupants = occupants
        self.position = position; self.ahead = ahead; self.chip = chip; self.suggestUpgrade = suggestUpgrade
        self.plansUrl = plansUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "courtesy"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? (kind == "queued" ? "En fila por un lugar" : "Cortesía de lugar")
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? ""
        occupants = (try? c.decodeIfPresent([Occupant].self, forKey: .occupants)) ?? []
        position = try? c.decodeIfPresent(Int.self, forKey: .position)
        ahead = (try? c.decodeIfPresent([Int].self, forKey: .ahead)) ?? []
        chip = try? c.decodeIfPresent(String.self, forKey: .chip)
        suggestUpgrade = (try? c.decodeIfPresent(Bool.self, forKey: .suggestUpgrade)) ?? false
        plansUrl = try? c.decodeIfPresent(String.self, forKey: .plansUrl)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, title, message, occupants, position, ahead, chip, suggestUpgrade, plansUrl
    }
}

struct FactoryRun: Identifiable, Decodable, Hashable {
    let id: Int
    let title: String
    let status: String
    let kind: String?
    let room: String?
    let thread: Int?
    let repo: String?
    let branch: String?
    let pr: String?
    let preview: String?
    let previewState: String?
    let planVersion: Int
    let loops: Int
    let createdAt: String?
    let updatedAt: String?
    let durationMin: Double?
    let usd: Double?
    var escalation: FactoryEscalation? = nil
    /// Lo decide gs (`needsYou`): una escalada de plataforma o un PR en automerge no te tocan.
    var serverNeedsYou: Bool? = nil
    var previewStatus: FactoryPreviewStatus? = nil
    /// Cortesía de lugar o fila (gs viejo no la manda).
    var slotNote: FactorySlotNote? = nil

    private enum CodingKeys: String, CodingKey {
        case id, title, status, kind, room, thread, repo, branch, pr, preview, previewState, planVersion,
             loops, createdAt, updatedAt, durationMin, usd, escalation, previewStatus, slotNote
        case serverNeedsYou = "needsYou"
    }

    var stage: FactoryStage { FactoryStage(status) }
    var isDependabot: Bool { kind == "dependabot" }

    /// Le toca a una persona. gs viejo no lo manda: entonces es la etapa sola.
    var needsYou: Bool { serverNeedsYou ?? (stage.needsYou && escalation?.type != .platform) }
    /// Escaló por una falla de la plataforma: se pinta como trabajo, no como «Te toca».
    var waitingOnPlatform: Bool { stage == .escalated && escalation?.type == .platform }

    /// «#64» de `https://github.com/o/n/pull/64`.
    var prNumber: String? {
        guard let pr, let n = pr.split(separator: "/").last, Int(n) != nil else { return nil }
        return "#\(n)"
    }

    var updated: Date? { FactoryAPI.date(updatedAt) }
}

struct FactoryRunDetail: Decodable {
    struct Plan: Decodable, Hashable {
        let version: Int
        let decision: String?
        let markdown: String
    }
    struct PlanSummary: Decodable, Hashable {
        let version: Int
        let decision: String?
        let title: String?
    }
    struct Event: Decodable, Hashable {
        let at: String?
        let actor: String?
        let type: String
        let data: FactoryJSON?
    }
    struct Running: Decodable, Hashable {
        let role: String?
        let since: String
    }

    let id: Int
    let title: String
    let status: String
    let kind: String?
    let room: String?
    let thread: Int?
    let repo: String?
    let branch: String?
    let pr: String?
    let preview: String?
    let previewState: String?
    let planVersion: Int
    let loops: Int
    let updatedAt: String?
    let plan: Plan?
    let plans: [PlanSummary]
    let events: [Event]
    let running: [Running]
    var escalation: FactoryEscalation? = nil
    var serverNeedsYou: Bool? = nil
    /// El CI del PR (checks de GitHub) mientras el PR te toca o el merge espera. `nil` = gs viejo o
    /// GitHub no contestó.
    let ci: CI?
    /// La preview atorada o fallida en cualquier etapa (gs viejo no la manda).
    var previewStatus: FactoryPreviewStatus? = nil
    /// Cortesía de lugar o fila (gs viejo no la manda).
    var slotNote: FactorySlotNote? = nil

    private enum CodingKeys: String, CodingKey {
        case id, title, status, kind, room, thread, repo, branch, pr, preview, previewState, planVersion,
             loops, updatedAt, plan, plans, events, running, escalation, ci, previewStatus, slotNote
        case serverNeedsYou = "needsYou"
    }

    struct CI: Decodable, Hashable {
        struct Check: Decodable, Hashable { let name: String; let url: String? }
        let total: Int
        let passed: Int
        let running: [Check]
        let failed: [Check]
        let startedAt: String?

        /// «CI 3 de 5 ✓ · corre test, e2e» / «CI en rojo: typecheck» / «CI en verde».
        var line: String? {
            guard total > 0 else { return nil }
            if !failed.isEmpty { return "CI en rojo: " + failed.map(\.name).joined(separator: ", ") }
            if running.isEmpty { return "CI en verde · \(total) de \(total) ✓" }
            let names = running.prefix(2).map(\.name).joined(separator: ", ") + (running.count > 2 ? "…" : "")
            let since = FactoryFormat.ago(FactoryAPI.date(startedAt)).map { " · arrancó \($0)" } ?? ""
            return "CI \(passed) de \(total) ✓ · corre \(names)\(since)"
        }
    }

    var stage: FactoryStage { FactoryStage(status) }

    private var findingsEvent: Event? {
        events.first { ["check_blocked", "check_fail", "ci_red_help"].contains($0.type) }
    }

    /// Lo que encontró @check la última vez que escaló o regresó hallazgos. Los renglones que Teams
    /// guardó como JSON crudo (`(preview):0 — {"file":…,"text":…}`, #125) se leen como texto.
    ///
    /// ⚠️ Primero `escalation` de gs: los eventos son sólo los últimos 15 y un pedido con mucha
    /// preview o «sin avanzar» después del escalado se quedaba sin motivo.
    var findings: String? {
        (escalation?.findings ?? findingsEvent?.data?["findings"]?.string).map(Self.readableFindings)
    }

    /// @check escaló porque le falta algo que @build no puede dar (variables, un acceso): otra
    /// vuelta de @build sólo gasta tokens. Lo resuelve la persona y @check revisa otra vez.
    var blocked: Bool {
        guard stage == .escalated else { return false }
        if let e = escalation?.kind.flatMap(FactoryEscalation.Kind.init) { return e == .env || e == .platform }
        return findingsEvent?.type == "check_blocked"
    }

    /// El tipo de escalado. gs viejo no lo manda: se deduce como antes (bloqueado = variables).
    var escalationKind: FactoryEscalation.Kind? {
        guard stage == .escalated else { return nil }
        if let k = escalation?.kind.flatMap(FactoryEscalation.Kind.init) { return k }
        return blocked ? .env : .decision
    }

    /// Ya pediste el merge y GitHub lo hará solo en cuanto pase el CI: el PR ya no te toca.
    /// Vale mientras nada lo regrese (CI en rojo, conflicto, más trabajo) después de la cola.
    var mergeQueued: Bool {
        guard stage == .prReview else { return false }
        let undo: Set = ["ci_red", "ci_red_help", "conflict", "rework", "head_moved", "check_fail",
                         "preview_blocking", "smoke_fail", "reopened"]
        return events.first { $0.type == "merge_queued" || undo.contains($0.type) }?.type == "merge_queued"
    }

    /// Las variables de entorno que nombran los hallazgos (`DATABASE_URL`, `SESSION_SECRET`…).
    var missingEnv: [String] {
        guard blocked, let f = findings else { return [] }
        let ns = f as NSString
        var out: [String] = []
        for m in Self.envName.matches(in: f, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range)
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    private static let envName = try! NSRegularExpression(pattern: "\\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\\b")
    private static let rawFinding = try! NSRegularExpression(pattern: "^(?:-\\s*)?(.*?)\\s+—\\s+(\\{.*\\})\\s*$", options: [.anchorsMatchLines])

    static func readableFindings(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let l = String(line)
            let ns = l as NSString
            guard let m = rawFinding.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)),
                  let o = try? JSONSerialization.jsonObject(with: Data(ns.substring(with: m.range(at: 2)).utf8)) as? [String: Any],
                  let text = ["text", "issue", "message", "finding", "description", "problem", "detail", "title"]
                    .lazy.compactMap({ o[$0] as? String }).first
            else { return l }
            // Sin ubicación cuando no es un archivo de verdad (`(preview):0`).
            let file = o["file"] as? String
            let line = (o["line"] as? Int).map { $0 > 0 ? ":\($0)" : "" } ?? ""
            let at = file.flatMap { $0.hasPrefix("(") ? nil : "`\($0)\(line)` — " } ?? ""
            return "- \(at)\(text)"
        }.joined(separator: "\n")
    }

    /// El pedido en la forma corta de la lista (para pintar mientras llega el detalle).
    var summary: FactoryRun {
        FactoryRun(id: id, title: title, status: status, kind: kind, room: room, thread: thread, repo: repo,
                   branch: branch, pr: pr, preview: preview, previewState: previewState,
                   planVersion: planVersion, loops: loops, createdAt: nil, updatedAt: updatedAt,
                   durationMin: nil, usd: nil, escalation: escalation, serverNeedsYou: serverNeedsYou,
                   previewStatus: previewStatus, slotNote: slotNote)
    }
}

/// Los rooms del espacio con sus repos (gs `…/factory/rooms`). `factory` = trabaja como fábrica.
struct FactoryRooms: Decodable {
    struct Room: Decodable, Hashable, Identifiable {
        let slug: String
        let name: String
        let `private`: Bool
        let repos: [String]
        let factory: Bool
        var id: String { slug }
    }
    let factoryInstalled: Bool
    let rooms: [Room]
}

/// Los repos que ve tu GitHub App (`…/factory/rooms?repos=1`), del más reciente al más viejo.
struct FactoryRepos: Decodable {
    struct Repo: Decodable, Hashable, Identifiable {
        let repo: String
        let `private`: Bool
        let description: String?
        let language: String?
        let pushedAt: String?
        /// Los rooms donde ya está conectado.
        let rooms: [String]
        var id: String { repo }
        var name: String { String(repo.split(separator: "/").last ?? Substring(repo)) }
        var owner: String { String(repo.split(separator: "/").first ?? "") }
    }
    let factoryInstalled: Bool
    let connected: Bool
    let installed: Bool
    let installUrl: String?
    let detail: String?
    let repos: [Repo]
}

/// Lo que contesta conectar un repo: el room, la caja de CI y qué tan listo está para agentes.
struct FactoryConnected: Decodable, Hashable {
    struct Readiness: Decodable, Hashable {
        let level: Int
        let passed: Int
        let total: Int
        let missing: [String]
    }
    let room: String
    let created: Bool
    let repo: String
    let factoryInstalled: Bool
    let ciLabel: String?
    let readiness: Readiness?
}

/// Lo que hace AHORA cada rol que trabaja en un pedido (gs `…/live`): sus pasos, el abierto y el
/// atasco vigente. Los pasos traen la misma `kind` que los del chat, así que se pintan igual.
struct FactoryLive: Decodable, Hashable {
    struct Step: Decodable, Hashable {
        let id: String
        let title: String
        let kind: String
        let detail: String?
        let status: String
        let secs: Int?
    }
    struct Stall: Decodable, Hashable {
        let human: String
        let rule: String
        let since: String?
    }
    struct Role: Decodable, Hashable {
        let role: String?
        let since: String
        let now: String?
        let steps: [Step]
        let stalled: Stall?

        /// Los pasos como los del chat (`PasosDelAgente`).
        var toolRun: ToolRun {
            ToolRun(herramientas: steps.map { s in
                Herramienta(id: s.id, titulo: s.title, clase: Herramienta.Clase(s.kind),
                            estado: s.status == "running" ? .corriendo : s.status == "failed" ? .fallida : .hecha,
                            salida: nil, donde: nil, detalle: s.detail)
            })
        }
    }
    let running: [Role]

    func role(_ r: String?) -> Role? { running.first { $0.role == r } }
}

/// «¿Qué hago?» con un pedido escalado (gs `…/advise`): arreglar o rehacer el plan, la nota para
/// @build punto por punto y lo único que @check revisa después. Sólo recomienda: decidir es `act`.
struct FactoryAdvice: Decodable, Hashable {
    struct Point: Decodable, Hashable {
        let point: String
        let cites: String
    }
    /// `fix` | `replan` | `close` | `close_ignore` | `recheck` | `wait` (las cuatro últimas, 20-oct).
    let decision: String
    let why: String
    let buildNote: [Point]
    let checkScope: String
    let confidence: String
    /// La nota lista para mandarla con la decisión: un renglón por punto.
    let note: String

    var fix: Bool { decision == "fix" }
    /// Sólo `fix` y `replan` llevan nota para un rol.
    var needsNote: Bool { decision == "fix" || decision == "replan" }

    init(decision: String, why: String, buildNote: [Point], checkScope: String, confidence: String, note: String) {
        self.decision = decision; self.why = why; self.buildNote = buildNote
        self.checkScope = checkScope; self.confidence = confidence; self.note = note
    }

    // Sin nota ni alcance cuando la decisión no es para un rol (`close`, `wait`…).
    init(from d: Decoder) throws {
        enum K: String, CodingKey { case decision, why, buildNote, checkScope, confidence, note }
        let c = try d.container(keyedBy: K.self)
        decision = try c.decode(String.self, forKey: .decision)
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        buildNote = try c.decodeIfPresent([Point].self, forKey: .buildNote) ?? []
        checkScope = try c.decodeIfPresent(String.self, forKey: .checkScope) ?? ""
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct FactorySpace: Identifiable, Hashable {
    let slug: String
    let role: String?
    var runs: [FactoryRun]
    var id: String { slug }
}

enum FactoryAPI {
    struct Failure: LocalizedError {
        let message: String
        let status: Int
        var errorDescription: String? { message }
    }

    /// `resume|stop|cancel`: la salida de un pedido «sin avanzar» (20-oct), como la tarjeta web.
    /// `close` cierra el PR (con `ignore`, le dice a Dependabot que no lo vuelva a abrir) y
    /// `retry_preview` pide la preview otra vez (20-oct).
    enum Action: String { case approve, changes, recheck, env, merge, card, resume, stop, cancel, close
        case retryPreview = "retry_preview" }

    /// `previewState`/`previewError`: cómo quedó la preview tras `retry_preview` (`waiting` = sin lugar de caja).
    struct ActResult { let status: String?; let queued: Bool; var keys: [String] = []
        var previewState: String? = nil; var previewError: String? = nil }
    struct NewRun { let room: String; let threadId: Int; let url: String? }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 40
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private static func url(_ path: String) -> URL {
        URL(string: path, relativeTo: Session.base)!.absoluteURL
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Pide y devuelve el cuerpo. Un 401 reintenta UNA vez con token nuevo, como `ClienteGS`.
    static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                                rejected: String? = nil) async throws -> Data {
        let token = try await Session.accessToken(rejected: rejected)
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.assumesHTTP3Capable = false
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, rejected == nil {
            return try await request(path, method: method, body: body, rejected: token)
        }
        guard (200..<300).contains(code) else {
            // gs y Teams contestan `{ error, message }` con la frase ya redactada en español.
            let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            // Teams (lo que gs le pasa tal cual, como el 409 de conectar) pone la frase en `error`.
            let teams = (json?["error"] as? String).flatMap { $0.contains(" ") ? $0 : nil }
            let msg = json?["message"] as? String ?? json?["error_description"] as? String ?? teams
                ?? (code == 401 ? "Hay que volver a entrar a tu cuenta." : "El servidor contestó \(code).")
            throw Failure(message: msg, status: code)
        }
        return d
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/"))) ?? s
    }

    /// Tus espacios (dueño o miembro): `[(slug, rol)]`.
    static func spaces() async throws -> [(slug: String, role: String?)] {
        struct R: Decodable { struct W: Decodable { let slug: String; let role: String? }; let workspaces: [W] }
        let r = try JSONDecoder().decode(R.self, from: try await request("/api/v2/workspaces"))
        return r.workspaces.map { ($0.slug, $0.role) }
    }

    static func runs(_ slug: String, limit: Int = 30) async throws -> [FactoryRun] {
        struct R: Decodable { let runs: [FactoryRun] }
        let d = try await request("/api/v2/workspaces/\(enc(slug))/factory/runs?limit=\(limit)")
        return try JSONDecoder().decode(R.self, from: d).runs
    }

    static func run(_ slug: String, _ id: Int) async throws -> FactoryRunDetail {
        struct R: Decodable { let run: FactoryRunDetail }
        let d = try await request("/api/v2/workspaces/\(enc(slug))/factory/runs/\(id)")
        return try JSONDecoder().decode(R.self, from: d).run
    }

    /// Decide un pedido. `approve` en `plan_review` exige la versión del plan que la persona leyó.
    static func act(_ slug: String, _ id: Int, _ action: Action, version: Int? = nil, note: String? = nil,
                    checkScope: String? = nil, skipPreview: Bool = false, dotenv: String? = nil,
                    ignore: String? = nil) async throws -> ActResult {
        var body: [String: Any] = ["action": action.rawValue]
        if let version { body["version"] = version }
        if let note, !note.isEmpty { body["note"] = note }
        // Lo único que @check revisa en la siguiente vuelta (lo propone `advise`).
        if let checkScope, !checkScope.isEmpty { body["checkScope"] = checkScope }
        if skipPreview { body["skipPreview"] = true }
        // Las variables de la preview: van a la bóveda de gs y nunca regresan.
        if let dotenv { body["dotenv"] = dotenv }
        // `major` | `dependency`: lo que Dependabot debe dejar de proponer al cerrar.
        if let ignore { body["ignore"] = ignore }
        let d = try await request("/api/v2/workspaces/\(enc(slug))/factory/runs/\(id)/act", method: "POST", body: body)
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let preview = j["preview"] as? [String: Any]
        return ActResult(status: j["status"] as? String, queued: j["queued"] as? Bool ?? false, keys: j["keys"] as? [String] ?? [],
                         previewState: preview?["state"] as? String, previewError: preview?["error"] as? String)
    }

    /// Qué hace ahora cada rol. Una caja de gs sin `/live` contesta 404: quien llama lo ignora.
    static func live(_ slug: String, _ id: Int) async throws -> FactoryLive {
        try JSONDecoder().decode(FactoryLive.self, from: try await request("/api/v2/workspaces/\(enc(slug))/factory/runs/\(id)/live"))
    }

    static func rooms(_ slug: String) async throws -> FactoryRooms {
        try JSONDecoder().decode(FactoryRooms.self, from: try await request("/api/v2/workspaces/\(enc(slug))/factory/rooms"))
    }

    static func repos(_ slug: String) async throws -> FactoryRepos {
        try JSONDecoder().decode(FactoryRepos.self, from: try await request("/api/v2/workspaces/\(enc(slug))/factory/rooms?repos=1"))
    }

    /// Conecta un repo a un room (lo crea con `create`). Tarda: revisa GitHub, prepara la caja de CI y
    /// mide qué tan listo está. Un repo que la App no ve contesta 409 (`Failure.status`).
    static func connect(_ slug: String, repo: String, room: String, create: Bool, isPrivate: Bool) async throws -> FactoryConnected {
        var body: [String: Any] = ["action": "connect", "repo": repo, "room": room]
        if create { body["create"] = true }
        if isPrivate { body["private"] = true }
        let d = try await request("/api/v2/workspaces/\(enc(slug))/factory/rooms", method: "POST", body: body)
        return try JSONDecoder().decode(FactoryConnected.self, from: d)
    }

    /// La página de GitHub para darle a la App acceso a más repos (vuelve a `…://conector`).
    static func githubAccessURL() async throws -> URL? {
        let d = try await request("/api/v2/me/connectors/github/start?install=1", method: "POST", body: [:])
        return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["url"].flatMap { $0 as? String }.flatMap(URL.init(string:))
    }

    /// Autorizar GitHub (la primera vez): el mismo flujo que Integraciones.
    static func githubConnectURL() async throws -> URL? {
        let d = try await request("/api/v2/me/connectors/github/start", method: "POST", body: [:])
        return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["url"].flatMap { $0 as? String }.flatMap(URL.init(string:))
    }

    /// El token de push de la Live Activity del pedido: con él gs la mantiene al día con la app dormida.
    static func registerLiveActivity(_ slug: String, _ id: Int, token: String, environment: String) async throws {
        _ = try await request("/api/v2/workspaces/\(enc(slug))/factory/runs/\(id)/live-activity", method: "POST",
                              body: ["token": token, "environment": environment])
    }

    /// La recomendación para un pedido escalado. 409 si ya no está escalado; 503 si el modelo no contestó.
    static func advise(_ slug: String, _ id: Int) async throws -> FactoryAdvice {
        struct R: Decodable { let advice: FactoryAdvice }
        let d = try await request("/api/v2/workspaces/\(enc(slug))/factory/runs/\(id)/advise", method: "POST", body: [:])
        return try JSONDecoder().decode(R.self, from: d).advice
    }

    /// «¿Qué pasó?» (gs `…/why`): por qué se atoró o falló, en dos frases. Se guarda la primera vez.
    static func why(_ slug: String, _ id: Int) async throws -> String {
        struct R: Decodable { struct W: Decodable { let summary: String }; let why: W? }
        let d = try await request("/api/v2/workspaces/\(enc(slug))/factory/runs/\(id)/why")
        return try JSONDecoder().decode(R.self, from: d).why?.summary ?? "Sin señales de problema."
    }

    /// Pedido nuevo: publica «@plan <texto>» en el room (o en el room conectado al repo).
    static func create(_ slug: String, room: String?, repo: String?, text: String) async throws -> NewRun {
        var body: [String: Any] = ["text": text]
        if let room, !room.isEmpty { body["room"] = room } else if let repo { body["repo"] = repo }
        let d = try await request("/api/v2/workspaces/\(enc(slug))/factory/runs", method: "POST", body: body)
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        return NewRun(room: j["room"] as? String ?? room ?? "", threadId: j["threadId"] as? Int ?? 0, url: j["url"] as? String)
    }

    /// El hilo del pedido en Teams.
    static func teamsURL(_ slug: String, room: String?, thread: Int?) -> URL? {
        guard let room else { return nil }
        let t = thread.map { "?thread=\($0)" } ?? ""
        return URL(string: "https://\(slug).teams.ghosty.studio/c/\(room)\(t)")
    }
}
