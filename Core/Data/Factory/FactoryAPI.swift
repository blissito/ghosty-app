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

    var stage: FactoryStage { FactoryStage(status) }
    var isDependabot: Bool { kind == "dependabot" }

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

    var stage: FactoryStage { FactoryStage(status) }

    /// Lo que encontró @check la última vez que escaló o regresó hallazgos.
    var findings: String? {
        events.first { ["check_blocked", "check_fail", "ci_red_help"].contains($0.type) }?
            .data?["findings"]?.string
    }

    /// El pedido en la forma corta de la lista (para pintar mientras llega el detalle).
    var summary: FactoryRun {
        FactoryRun(id: id, title: title, status: status, kind: kind, room: room, thread: thread, repo: repo,
                   branch: branch, pr: pr, preview: preview, previewState: previewState,
                   planVersion: planVersion, loops: loops, createdAt: nil, updatedAt: updatedAt,
                   durationMin: nil, usd: nil)
    }
}

/// «¿Qué hago?» con un pedido escalado (gs `…/advise`): arreglar o rehacer el plan, la nota para
/// @build punto por punto y lo único que @check revisa después. Sólo recomienda: decidir es `act`.
struct FactoryAdvice: Decodable, Hashable {
    struct Point: Decodable, Hashable {
        let point: String
        let cites: String
    }
    let decision: String
    let why: String
    let buildNote: [Point]
    let checkScope: String
    let confidence: String
    /// La nota lista para mandarla con la decisión: un renglón por punto.
    let note: String

    var fix: Bool { decision == "fix" }
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

    enum Action: String { case approve, changes, merge, card }

    struct ActResult { let status: String?; let queued: Bool }
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
    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
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
            let msg = json?["message"] as? String ?? json?["error_description"] as? String
                ?? (code == 401 ? "Hay que volver a entrar a tu cuenta." : "El servidor contestó \(code).")
            throw Failure(message: msg, status: code)
        }
        return d
    }

    private static func enc(_ s: String) -> String {
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
                    checkScope: String? = nil, skipPreview: Bool = false) async throws -> ActResult {
        var body: [String: Any] = ["action": action.rawValue]
        if let version { body["version"] = version }
        if let note, !note.isEmpty { body["note"] = note }
        // Lo único que @check revisa en la siguiente vuelta (lo propone `advise`).
        if let checkScope, !checkScope.isEmpty { body["checkScope"] = checkScope }
        if skipPreview { body["skipPreview"] = true }
        let d = try await request("/api/v2/workspaces/\(enc(slug))/factory/runs/\(id)/act", method: "POST", body: body)
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        return ActResult(status: j["status"] as? String, queued: j["queued"] as? Bool ?? false)
    }

    /// La recomendación para un pedido escalado. 409 si ya no está escalado; 503 si el modelo no contestó.
    static func advise(_ slug: String, _ id: Int) async throws -> FactoryAdvice {
        struct R: Decodable { let advice: FactoryAdvice }
        let d = try await request("/api/v2/workspaces/\(enc(slug))/factory/runs/\(id)/advise", method: "POST", body: [:])
        return try JSONDecoder().decode(R.self, from: d).advice
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
