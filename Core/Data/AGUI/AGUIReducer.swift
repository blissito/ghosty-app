import Foundation

/// El estado de UNA conversación como reductor PURO sobre eventos AG-UI: entra un evento, sale un
/// estado nuevo. Es el mismo modelo que `reducer.ts` de ghostykit (la web y Piloto), traído a Swift
/// para que el teléfono lea el hilo igual que ellos.
///
/// Un turno del asistente es todo lo que el agente dice y hace entre dos mensajes de la persona: su
/// texto (varios TEXT_MESSAGE seguidos), sus pasos (TOOL_CALL_*) y, si se detiene, sus aprobaciones.
/// `MESSAGES_SNAPSHOT` manda: el servidor es dueño del hilo, y al abrirlo o reconectar el snapshot
/// REEMPLAZA lo armado en vivo (conservando lo que sólo se ve en vivo: segundos, uso, pensamiento).
struct AGUIState: Equatable {
    struct Tool: Sendable, Equatable {
        var id: String
        /// `toolCallName`: el nombre técnico de la herramienta.
        var name: String?
        /// Cómo la nombra gs para personas («Leyendo tus archivos»), si lo dijo (`ghosty.step`).
        var title: String?
        var kind: String?
        var detail: String?
        var path: String?
        /// `in_progress` | `completed` | `failed` | `pending` (espera aprobación) | `cancelled`.
        var status: String
        /// Los argumentos en JSON tal como llegaron (TOOL_CALL_ARGS).
        var args: String = ""
        var result: String?
    }

    struct Turn: Sendable, Equatable {
        enum Role: String, Sendable { case user, assistant }
        var role: Role
        var id: String?
        var text: String = ""
        var thought: String?
        var tools: [Tool] = []
        /// Largo del texto cuando arrancó cada herramienta: lo de antes es narración.
        var cuts: [Int] = []
        var attachments: [AGUIAttachment] = []
        var seconds: Int?
        var usage: Usage?
    }

    struct Usage: Sendable, Equatable {
        var input: Int
        var output: Int
    }

    /// Una aprobación pendiente: un `Interrupt` de AG-UI listo para pintar.
    struct Permission: Sendable, Equatable {
        var id: String
        var title: String
        var tool: String?
        var toolCallId: String?
        var reason: String?
        /// Vencimiento en el reloj de ESTE teléfono: `expiresAt − hora del servidor + hora local`.
        var deadline: Date?
    }

    enum Outcome: Sendable, Equatable {
        case success, interrupt, cancelled
        case error(String, code: String?)
    }

    var turns: [Turn] = []
    /// Hay un run corriendo en el servidor.
    var busy = false
    var runId: String?
    var threadId: String?
    /// Cómo acabó el último run visto.
    var outcome: Outcome?
    var error: String?
    var permissions: [Permission] = []
    /// Cuándo arrancó el turno que encargó ESTE cliente (nil = ninguno: abrir no es turno).
    var turnStartedAt: Date?
    var title: String?
    /// Lo que gs dice del turno además del estándar: cola, despertar, capacidades.
    var custom: [String: [String: Any]] = [:]
    /// `STATE_SNAPSHOT`/`STATE_DELTA` aplicados (gs publica aquí lo que no es texto ni pasos).
    var shared: [String: Any] = [:]

    static func == (a: AGUIState, b: AGUIState) -> Bool {
        a.turns == b.turns && a.busy == b.busy && a.runId == b.runId && a.outcome == b.outcome
            && a.error == b.error && a.permissions == b.permissions && a.title == b.title
    }
}

// `[String: Any]` no es Sendable; el estado sólo se usa dentro de un actor o por copia en pruebas.
extension AGUIState: @unchecked Sendable {}

enum AGUIReducer {
    /// Un evento → estado nuevo. `now` se inyecta para que sea puro.
    static func reduce(_ prev: AGUIState, _ e: AGUIEvent, now: Date = Date()) -> AGUIState {
        var s = prev
        switch e.type {
        case "RUN_STARTED":
            s.busy = true
            s.error = nil
            s.outcome = nil
            s.runId = e.string("runId") ?? s.runId
            s.threadId = e.string("threadId") ?? s.threadId
        case "TEXT_MESSAGE_START":
            if let r = e.string("role"), r != "assistant" { return s }
            // Un mensaje nuevo del mismo turno va en párrafo aparte.
            patchAssistant(&s) { t in
                if !t.text.isEmpty, !t.text.hasSuffix("\n") { t.text += "\n\n" }
            }
        case "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_CHUNK":
            if let r = e.string("role"), r != "assistant" { return s }
            guard let d = e.string("delta"), !d.isEmpty else { return s }
            patchAssistant(&s) { $0.text += d }
        case "TOOL_CALL_START":
            guard let id = e.string("toolCallId") else { return s }
            upsertTool(&s, id) { t in t.name = e.string("toolCallName") ?? t.name; t.status = "in_progress" }
        case "TOOL_CALL_CHUNK":
            guard let id = e.string("toolCallId") else { return s }
            upsertTool(&s, id) { t in
                if let n = e.string("toolCallName") { t.name = n }
                t.args += e.string("delta") ?? ""
            }
        case "TOOL_CALL_ARGS":
            guard let id = e.string("toolCallId") else { return s }
            upsertTool(&s, id) { $0.args += e.string("delta") ?? "" }
        case "TOOL_CALL_END":
            guard let id = e.string("toolCallId") else { return s }
            upsertTool(&s, id) { t in if t.detail == nil { t.detail = argsDetail(t.args) } }
        case "TOOL_CALL_RESULT":
            guard let id = e.string("toolCallId") else { return s }
            let failed = (e["metadata"] as? [String: Any])?["error"] as? Bool == true
            upsertTool(&s, id) { t in
                t.status = failed ? "failed" : "completed"
                if let c = e.string("content"), !c.isEmpty { t.result = c }
            }
        case "REASONING_MESSAGE_CONTENT", "REASONING_MESSAGE_CHUNK", "THINKING_TEXT_MESSAGE_CONTENT":
            guard let d = e.string("delta"), !d.isEmpty else { return s }
            patchAssistant(&s) { $0.thought = ($0.thought ?? "") + d }
        case "MESSAGES_SNAPSHOT":
            let msgs = (e["messages"] as? [[String: Any]] ?? []).compactMap(AGUIMessage.init)
            applySnapshot(&s, msgs)
        case "STATE_SNAPSHOT":
            s.shared = e["snapshot"] as? [String: Any] ?? [:]
        case "STATE_DELTA":
            s.shared = JSONPatch.apply(e["delta"] as? [[String: Any]] ?? [], to: s.shared)
        case "RUN_FINISHED":
            finish(&s, e, now: now)
        case "RUN_ERROR":
            s.error = e.string("message") ?? "El agente falló."
            finish(&s, e, now: now, failed: true)
        case "CUSTOM":
            guard let name = e.string("name") else { return s }
            let value = e["value"] as? [String: Any] ?? [:]
            if name == "ghosty.title", let t = value["title"] as? String { s.title = t }
            if name == "ghosty.step", let id = value["toolCallId"] as? String {
                // Cómo nombra gs el paso para personas: no cambia su estado, sólo cómo se lee.
                upsertTool(&s, id, create: false) { t in
                    t.title = value["title"] as? String ?? t.title
                    t.kind = value["kind"] as? String ?? t.kind
                    t.detail = value["detail"] as? String ?? t.detail
                    t.path = value["path"] as? String ?? t.path
                }
            }
            s.custom[name] = value
        default:
            // STEP_*, ACTIVITY_*, RAW…: no se pintan.
            break
        }
        return s
    }

    /// Todo un flujo de una vez (pruebas, flujos grabados).
    static func reduce(_ s: AGUIState = AGUIState(), _ events: [AGUIEvent], now: Date = Date()) -> AGUIState {
        events.reduce(s) { reduce($0, $1, now: now) }
    }

    // MARK: - Acciones locales (lo que hace el cliente, no el servidor)

    /// La persona manda un mensaje (o contesta una tarjeta: texto vacío, sin burbuja).
    static func beginSend(_ prev: AGUIState, text: String, attachments: [AGUIAttachment] = [],
                          now: Date = Date()) -> AGUIState {
        var s = prev
        if !text.isEmpty || !attachments.isEmpty {
            s.turns.append(.init(role: .user, text: text, attachments: attachments))
        }
        s.busy = true
        s.error = nil
        s.turnStartedAt = now
        return s
    }

    /// Detener: los pasos abiertos ya no corren.
    static func stop(_ prev: AGUIState) -> AGUIState {
        var s = prev
        s.busy = false
        s.turnStartedAt = nil
        s.turns = closeOpenTools(s.turns, status: "cancelled")
        return s
    }

    /// La persona contestó (o dejó vencer) una tarjeta: sale de las abiertas.
    static func resolvePermission(_ prev: AGUIState, id: String) -> AGUIState {
        var s = prev
        s.permissions.removeAll { $0.id == id }
        return s
    }

    // MARK: - Piezas

    static func patchAssistant(_ s: inout AGUIState, _ patch: (inout AGUIState.Turn) -> Void) {
        if s.turns.last?.role != .assistant { s.turns.append(.init(role: .assistant)) }
        patch(&s.turns[s.turns.count - 1])
    }

    private static func upsertTool(_ s: inout AGUIState, _ id: String, create: Bool = true,
                                   _ patch: (inout AGUIState.Tool) -> Void) {
        // Primero donde ya esté (un `ghosty.step` o un resultado pueden llegar después de otro texto).
        for ti in s.turns.indices.reversed() {
            if let i = s.turns[ti].tools.firstIndex(where: { $0.id == id }) {
                patch(&s.turns[ti].tools[i])
                return
            }
        }
        guard create else { return }
        patchAssistant(&s) { t in
            var tool = AGUIState.Tool(id: id, status: "in_progress")
            patch(&tool)
            t.tools.append(tool)
            // Lo que el agente dijo ANTES de esta herramienta es narración («Reviso tus crons.»).
            let len = t.text.count
            if !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, t.cuts.last != len {
                t.cuts.append(len)
            }
        }
    }

    /// Los argumentos de una tool en corto, para el renglón del paso: «job: purge-notifications».
    static func argsDetail(_ json: String?) -> String? {
        guard let json, !json.isEmpty, let d = json.data(using: .utf8),
              let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return nil }
        guard let o = v as? [String: Any] else { return "\(v)" }
        let parts = o.keys.sorted().compactMap { k -> String? in
            let x = o[k]!
            if x is NSNull { return nil }
            if let s = x as? String { return s.isEmpty ? nil : "\(k): \(s)" }
            if x is [Any] || x is [String: Any],
               let j = try? JSONSerialization.data(withJSONObject: x), let js = String(data: j, encoding: .utf8) {
                return "\(k): \(js)"
            }
            return "\(k): \(x)"
        }
        let s = parts.joined(separator: ", ")
        if s.isEmpty { return nil }
        return s.count > 80 ? String(s.prefix(79)) + "…" : s
    }

    private static func closeOpenTools(_ turns: [AGUIState.Turn], status: String) -> [AGUIState.Turn] {
        turns.map { t in
            var t = t
            for i in t.tools.indices where t.tools[i].status == "in_progress" { t.tools[i].status = status }
            return t
        }
    }

    /// El hilo guardado (mensajes AG-UI) como turnos: cada mensaje de la persona abre uno; lo que
    /// sigue del asistente y de las herramientas se junta en un turno, con sus pasos y narración.
    static func messagesToTurns(_ messages: [AGUIMessage]) -> [AGUIState.Turn] {
        var turns: [AGUIState.Turn] = []
        var open = false
        func assistant() -> Int {
            if !open { turns.append(.init(role: .assistant)); open = true }
            return turns.count - 1
        }
        for m in messages {
            switch m.role {
            case "user":
                open = false
                turns.append(.init(role: .user, id: m.id, text: m.text, attachments: m.attachments))
            case "assistant":
                let i = assistant()
                if turns[i].id == nil { turns[i].id = m.id }
                let text = m.text
                if !text.isEmpty { turns[i].text = turns[i].text.isEmpty ? text : turns[i].text + "\n\n" + text }
                for c in m.toolCalls {
                    turns[i].tools.append(.init(id: c.id, name: c.name, detail: argsDetail(c.arguments),
                                                status: "pending", args: c.arguments))
                    let len = turns[i].text.count
                    if !turns[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, turns[i].cuts.last != len {
                        turns[i].cuts.append(len)
                    }
                }
            case "tool":
                let i = assistant()
                if let k = turns[i].tools.firstIndex(where: { $0.id == m.toolCallId }) {
                    turns[i].tools[k].status = m.failed ? "failed" : "completed"
                    let r = m.text
                    if !r.isEmpty { turns[i].tools[k].result = r }
                }
            case "reasoning":
                let i = assistant()
                turns[i].thought = (turns[i].thought ?? "") + m.text
            default:
                break
            }
        }
        return turns
    }

    /// El snapshot manda, pero lo que sólo existe en vivo (segundos, uso, pensamiento, cómo nombró gs
    /// cada paso) se conserva.
    private static func applySnapshot(_ s: inout AGUIState, _ messages: [AGUIMessage]) {
        let old = s.turns
        s.turns = messagesToTurns(messages).enumerated().map { i, t in
            guard i < old.count, old[i].role == t.role else { return t }
            let o = old[i]
            var t = t
            t.seconds = o.seconds ?? t.seconds
            t.usage = o.usage ?? t.usage
            if t.thought == nil { t.thought = o.thought }
            if t.attachments.isEmpty { t.attachments = o.attachments }
            t.tools = t.tools.map { x in
                guard let y = o.tools.first(where: { $0.id == x.id }) else { return x }
                var x = x
                x.title = x.title ?? y.title
                x.kind = x.kind ?? y.kind
                x.path = x.path ?? y.path
                x.result = x.result ?? y.result
                if x.status == "pending", y.status != "in_progress" { x.status = y.status }
                return x
            }
            return t
        }
    }

    private static func finish(_ s: inout AGUIState, _ e: AGUIEvent, now: Date, failed: Bool = false) {
        s.busy = false
        let outcome = e["outcome"] as? [String: Any]
        let type = outcome?["type"] as? String
        let interrupts = outcome?["interrupts"] as? [[String: Any]] ?? []
        let interrupted = type == "interrupt" && !interrupts.isEmpty
        // El reloj del servidor (`timestamp`, o el que puso el transporte con el `Date`) contra el
        // local al recibirlo: la cuenta regresiva no depende del reloj de la persona.
        let offset = e.timestamp.map { now.timeIntervalSince1970 - $0 / 1000 } ?? 0
        s.permissions = interrupted ? interrupts.map { toPermission($0, turns: s.turns, offset: offset) } : []
        if failed {
            s.outcome = .error(s.error ?? "El agente falló.", code: e.string("code"))
            s.turns = closeOpenTools(s.turns, status: "failed")
        } else if type == "cancelled" {
            s.outcome = .cancelled
            s.turns = closeOpenTools(s.turns, status: "cancelled")
        } else {
            s.outcome = interrupted ? .interrupt : .success
        }
        if interrupted {
            // La herramienta que espera aprobación no está corriendo: espera.
            let waiting = Set(s.permissions.compactMap(\.toolCallId))
            for ti in s.turns.indices {
                for k in s.turns[ti].tools.indices where waiting.contains(s.turns[ti].tools[k].id)
                    && s.turns[ti].tools[k].status != "completed" {
                    s.turns[ti].tools[k].status = "pending"
                }
            }
        }
        // Uso de tokens (`usage: [{inputTokens, outputTokens}]`) en el último turno.
        let usage: AGUIState.Usage? = (e["usage"] as? [[String: Any]]).flatMap { list in
            guard !list.isEmpty else { return nil }
            return list.reduce(AGUIState.Usage(input: 0, output: 0)) { a, u in
                .init(input: a.input + (u["inputTokens"] as? Int ?? 0), output: a.output + (u["outputTokens"] as? Int ?? 0))
            }
        }
        if let last = s.turns.indices.last, s.turns[last].role == .assistant {
            if let t0 = s.turnStartedAt { s.turns[last].seconds = max(1, Int((now.timeIntervalSince(t0)).rounded())) }
            if let usage { s.turns[last].usage = usage }
        }
        s.turnStartedAt = nil
    }

    /// Un `Interrupt` de AG-UI como tarjeta: título, herramienta (por su toolCallId) y vencimiento.
    static func toPermission(_ i: [String: Any], turns: [AGUIState.Turn], offset: TimeInterval) -> AGUIState.Permission {
        let meta = i["metadata"] as? [String: Any] ?? [:]
        let toolCallId = i["toolCallId"] as? String
        let toolName = (meta["tool"] as? String)
            ?? turns.flatMap(\.tools).first(where: { $0.id == toolCallId }).flatMap { $0.title ?? $0.name }
        let deadline = expiry(i["expiresAt"]).map { $0.addingTimeInterval(offset) }
        return .init(id: i["id"] as? String ?? "",
                     title: (i["message"] as? String) ?? toolName ?? (i["reason"] as? String ?? "una acción"),
                     tool: toolName, toolCallId: toolCallId, reason: i["reason"] as? String, deadline: deadline)
    }

    /// `expiresAt` (ISO o epoch ms) → fecha.
    static func expiry(_ v: Any?) -> Date? {
        if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// JSON Patch (RFC 6902) mínimo para `STATE_DELTA`: add/replace/remove sobre objetos y arreglos.
enum JSONPatch {
    static func apply(_ ops: [[String: Any]], to doc: [String: Any]) -> [String: Any] {
        var root: Any = doc
        for op in ops {
            guard let kind = op["op"] as? String, let path = op["path"] as? String else { continue }
            let keys = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map {
                $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            }
            root = set(root, Array(keys), kind == "remove" ? nil : op["value"], remove: kind == "remove")
        }
        return root as? [String: Any] ?? doc
    }

    private static func set(_ node: Any, _ keys: [String], _ value: Any?, remove: Bool) -> Any {
        guard let k = keys.first else { return value ?? NSNull() }
        let rest = Array(keys.dropFirst())
        if var a = node as? [Any] {
            if k == "-", rest.isEmpty, let value { a.append(value); return a }
            guard let i = Int(k), i <= a.count else { return a }
            if rest.isEmpty {
                if remove { if i < a.count { a.remove(at: i) } }
                else if let value { if i < a.count { a[i] = value } else { a.append(value) } }
                return a
            }
            if i < a.count { a[i] = set(a[i], rest, value, remove: remove) }
            return a
        }
        var o = node as? [String: Any] ?? [:]
        if rest.isEmpty {
            if remove { o[k] = nil } else { o[k] = value }
            return o
        }
        o[k] = set(o[k] ?? [String: Any](), rest, value, remove: remove)
        return o
    }
}
