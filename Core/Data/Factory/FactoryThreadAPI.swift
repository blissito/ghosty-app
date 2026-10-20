import Foundation

/// Un pedido a @plan visto desde el teléfono (gs `…/factory/threads/:room/:threadId`). @plan no
/// siempre arma un plan para firmar: también propone un sprint, deja ideas o sólo contesta o
/// pregunta. La app sólo veía runs y el pedido «no regresaba» (bliss, 19-oct).
struct FactoryThread: Decodable, Hashable {
    struct Ask: Decodable, Hashable {
        let question: String
        let options: [String]
        let answered: String?
    }
    struct Message: Decodable, Hashable, Identifiable {
        let id: Int
        let from: String
        let handle: String?
        let name: String
        let body: String
        let at: Int
        let live: Bool
        let ask: Ask?
        var byAgent: Bool { from == "agent" }
    }
    struct Run: Decodable, Hashable {
        let id: Int
        let status: String
        let title: String?
    }
    let channel: String
    let root: Message
    var messages: [Message]
    let run: Run?
    let sprint: FactorySprint?
    let working: Bool

    /// Lo último que dijo @plan, para el renglón de la lista.
    var lastReply: Message? { messages.last(where: \.byAgent) }

    /// En qué quedó, en una frase (la lista «Con @plan»).
    var summary: String {
        if let run { return run.status == "plan_review" ? "Plan listo para firmar" : "Ya es el pedido #\(run.id)" }
        if let sprint { return sprint.status == "draft" ? "Te propuso un sprint de \(sprint.items.count) tickets" : "Sprint en marcha" }
        if working { return "@plan está trabajando…" }
        guard let last = lastReply else { return "Esperando a @plan…" }
        let r = FactoryReply(last.body)
        if !r.ideas.isEmpty { return "Te dejó \(r.ideas.count) ideas" }
        if last.ask != nil || r.text.hasSuffix("?") { return "Te hizo una pregunta" }
        return "Te contestó"
    }
}

/// Un sprint: lo que @plan propone cuando el objetivo no cabe en un pedido (3–8 tickets en orden,
/// con dependencias). Se aprueba con UNA firma y la fábrica arranca los tickets uno a la vez. Es la
/// forma de la tarjeta de Teams (`readSprint`).
struct FactorySprint: Decodable, Hashable, Identifiable {
    struct Item: Decodable, Hashable, Identifiable {
        let id: Int
        let idx: Int
        let key: String
        let title: String
        let size: String
        let dependsOn: [String]
        let bodyMd: String
        let included: Bool
        let status: String
        let runId: Int?
        let prUrl: String?
        let issueUrl: String?
        let issueNumber: Int?
        /// Quién lo tiene ahora: `@plan`, `@build`, `@check`, `you_review`, `you_decide`, `box_wait`.
        let stage: String?
    }
    struct Change: Decodable, Hashable {
        let note: String
        let byName: String?
        let pending: Bool
        let answered: Bool
    }
    let id: Int
    let title: String
    let goal: String
    let repo: String?
    let status: String
    let version: Int
    let canEdit: Bool
    let change: Change?
    let items: [Item]

    var isDraft: Bool { status == "draft" }
    var included: [Item] { items.filter(\.included) }
    var merged: Int { included.filter { $0.status == "merged" || $0.status == "skipped" }.count }
}

/// Un renglón de la lista de sprints (gs `…/factory/sprints`).
struct FactorySprintRow: Decodable, Hashable, Identifiable {
    let id: Int
    let title: String
    let status: String
    let repo: String?
    let room: String?
    let threadId: Int?
    let total: Int
    let merged: Int
    let updatedAt: Int
}

/// El cuerpo de un mensaje de @plan, separado: el texto que se lee, los pasos (`gt-tools`) y las
/// ideas (`gt-asks`). Los demás bloques (`gt-plan`, `gt-run`, `gt-sprint`, `eb-*`…) se quitan: el
/// run y el sprint llegan aparte, ya armados.
struct FactoryReply: Equatable {
    struct Idea: Decodable, Hashable, Identifiable {
        let size: String?
        let title: String
        let ask: String
        let why: String?
        let repo: String?
        var id: String { title + ask.prefix(40) }
    }
    var text: String
    var tools: [Herramienta]
    var ideas: [Idea]
    var ideasRoom: String?

    private static let fence = try! NSRegularExpression(pattern: "```((?:gt|eb)-[a-z-]+|ask-user)[^\\n]*\\n([\\s\\S]*?)\\n?```", options: [])

    init(_ body: String) {
        var tools: [Herramienta] = []
        var ideas: [Idea] = []
        var room: String?
        let ns = body as NSString
        for m in Self.fence.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: m.range(at: 1))
            let data = Data(ns.substring(with: m.range(at: 2)).utf8)
            switch kind {
            case "gt-tools":
                struct T: Decodable { let label: String; let status: String?; let detail: String? }
                struct W: Decodable { let tools: [T]? }
                for (i, t) in ((try? JSONDecoder().decode(W.self, from: data))?.tools ?? []).enumerated() {
                    let estado: Herramienta.Estado = t.status == "running" ? .corriendo : t.status == "error" ? .fallida : .hecha
                    tools.append(Herramienta(id: "t\(i)-\(t.label)", titulo: t.label, clase: Self.clase(t.label), estado: estado, detalle: t.detail))
                }
            case "gt-asks":
                struct W: Decodable { let roomSlug: String?; let items: [Idea] }
                if let w = try? JSONDecoder().decode(W.self, from: data) { ideas += w.items; room = w.roomSlug }
            default: break
            }
        }
        text = Self.fence.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.tools = tools
        self.ideas = ideas
        ideasRoom = room
    }

    /// La clase del paso por su rótulo («Github: list issues», «Factory: plan submit»…).
    private static func clase(_ label: String) -> Herramienta.Clase {
        let l = label.lowercased()
        if l.hasPrefix("factory") { return .deliver }
        if l.contains("search") || l.contains("buscar") || l.contains("grep") { return .search }
        if l.contains("read") || l.contains("leer") || l.contains("list") { return .read }
        if l.contains("bash") || l.contains("terminal") || l.contains("comando") { return .execute }
        if l == "agent" { return .delegate }
        return .other
    }
}

extension FactoryAPI {
    static func thread(_ slug: String, room: String, id: Int) async throws -> FactoryThread {
        try JSONDecoder().decode(FactoryThread.self, from: try await request("/api/v2/workspaces/\(enc(slug))/factory/threads/\(enc(room))/\(id)"))
    }

    /// Contestarle a @plan en el hilo (una opción de `ask-user` es su texto).
    static func reply(_ slug: String, room: String, id: Int, text: String) async throws {
        _ = try await request("/api/v2/workspaces/\(enc(slug))/factory/threads/\(enc(room))/\(id)", method: "POST", body: ["text": text])
    }

    static func sprints(_ slug: String) async throws -> [FactorySprintRow] {
        struct W: Decodable { let sprints: [FactorySprintRow] }
        return try JSONDecoder().decode(W.self, from: try await request("/api/v2/workspaces/\(enc(slug))/factory/sprints")).sprints
    }

    static func sprint(_ slug: String, _ id: Int) async throws -> FactorySprint {
        try JSONDecoder().decode(FactorySprint.self, from: try await request("/api/v2/workspaces/\(enc(slug))/factory/sprints/\(id)"))
    }

    enum SprintAction {
        case approve
        case edit(itemId: Int, included: Bool? = nil, title: String? = nil, bodyMd: String? = nil)
        case changes(note: String)
        case item(itemId: Int, op: String)
        case issue(itemId: Int)
    }

    /// Lo que hace la tarjeta del sprint en Teams; regresa el sprint como quedó.
    static func sprintAct(_ slug: String, _ id: Int, _ a: SprintAction) async throws -> FactorySprint {
        var body: [String: Any]
        switch a {
        case .approve: body = ["action": "approve"]
        case let .edit(itemId, included, title, bodyMd):
            body = ["action": "edit", "itemId": itemId]
            if let included { body["included"] = included }
            if let title { body["title"] = title }
            if let bodyMd { body["bodyMd"] = bodyMd }
        case let .changes(note): body = ["action": "changes", "note": note]
        case let .item(itemId, op): body = ["action": "item", "itemId": itemId, "op": op]
        case let .issue(itemId): body = ["action": "issue", "itemId": itemId]
        }
        return try JSONDecoder().decode(FactorySprint.self, from: try await request("/api/v2/workspaces/\(enc(slug))/factory/sprints/\(id)", method: "POST", body: body))
    }
}
