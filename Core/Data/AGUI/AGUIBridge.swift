import Foundation

/// Lee eventos AG-UI y dice qué le toca a la app: el texto y los pasos van como `Replay` (lo que ya
/// pinta el hilo), lo demás como señales (permisos, fase, capacidades, estado compartido). Puro: sin
/// red y sin store.
///
/// ⚠️ No es un traductor de protocolo: el cable YA es AG-UI y el estado sale del mismo reductor que la
/// web (`AGUIReducer`). Esto sólo reparte ese estado a las piezas de la app que existían antes.
/// Lo propio de gs está en `~/ghosty-studio/docs/claude/agui-adopcion.md` §0 («gs-agui 1»).
struct AGUIBridge {
    /// Los CUSTOM de gs (§0.3).
    enum Custom {
        /// `{toolCallId, title, kind, path?, detail?}`: cómo se nombra un paso para personas.
        static let tool = "ghosty.tool"
        /// El payload del relé tal cual + `id`, `messageId` y `url` firmada (sin base64).
        static let delivery = "ghosty.delivery"
        /// `{messageId}`: el steer entró en el run vivo.
        static let injected = "ghosty.injected"
        static let title = "ghosty.title"
        /// `{messageId?, content}`: el texto final de la respuesta cambió al cerrar.
        static let replace = "ghosty.replace"
        /// `{names, message}`: adjuntos que no llegaron al agente.
        static let attachmentsFailed = "ghosty.attachments_failed"
    }

    /// Los `stepName` de gs (§0.3). Los de otros servidores (LangGraph manda `agent`) se ignoran.
    static let phases: Set<String> = ["waking", "session", "compacting"]

    enum Output {
        case replay(ACPClient.Replay)
        /// Aprobaciones abiertas al cerrar el run (`outcome: interrupt`).
        case interrupts([AGUIState.Permission])
        /// Fase del turno según el servidor: `waking` | `session` | `compacting` | `reposo`.
        case phase(String)
        case caps(steer: Bool)
        case title(String)
        /// `state` compartido nuevo (STATE_SNAPSHOT/STATE_DELTA): capacidades, modelo, subagentes.
        case state([String: Any])
        /// El steer entró en el run vivo.
        case injected
        case notice(String)
        /// El run terminó (cualquier `outcome`).
        case finished(AGUIState.Outcome)
    }

    let agentID: String
    let sessionID: String
    /// El `runId` que mandamos en ESTE request.
    let requestRunId: String
    /// El run que YA sabemos que es el de esta respuesta: el propio (`turnId`), o el vivo al que
    /// contesta un resume o un steer. `nil` al reconectar: lo dice `RUN_STARTED`.
    let knownRunId: String?
    private(set) var state = AGUIState()
    /// Hay un run vivo detrás de esta respuesta: el propio, o uno al que nos enganchamos.
    private(set) var sawLive = false
    /// El run cuyo trabajo se está pintando (= el `turnId` de su burbuja).
    private(set) var liveRunId: String?
    /// Herramientas ya contadas, para mandar sólo cambios.
    private var lastTool: [String: Herramienta] = [:]
    private var lastSteer: Bool?

    init(agentID: String, sessionID: String, requestRunId: String, knownRunId: String?) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.requestRunId = requestRunId
        self.knownRunId = knownRunId
    }

    mutating func apply(_ e: AGUIEvent, now: Date = Date()) -> [Output] {
        state = AGUIReducer.reduce(state, e, now: now)
        var out: [Output] = []
        switch e.type {
        case "RUN_STARTED":
            // Regla del run vivo (§0.6): una respuesta que se engancha a un run que ya corre abre con
            // el runId VIVO, no el del request. Si ya lo sabemos (turno propio, resume, steer), manda
            // el nuestro: el servidor dice lo mismo, y uno que no lo cumpla no parte la burbuja.
            let id = knownRunId ?? e.string("runId") ?? requestRunId
            if knownRunId != nil || id != requestRunId {
                liveRunId = id
                sawLive = true
                out.append(.replay(.turno(id)))
            }
        case "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_CHUNK":
            if let r = e.string("role"), r != "assistant" { break }
            guard let d = e.string("delta"), !d.isEmpty else { break }
            out += live()
            out.append(.replay(.agent(d)))
        case "REASONING_MESSAGE_CONTENT", "REASONING_MESSAGE_CHUNK", "THINKING_TEXT_MESSAGE_CONTENT":
            guard let d = e.string("delta"), !d.isEmpty else { break }
            out += live()
            out.append(.replay(.thought(d)))
        case "TOOL_CALL_START", "TOOL_CALL_CHUNK", "TOOL_CALL_END", "TOOL_CALL_RESULT":
            out += live()
            if let id = e.string("toolCallId") { out += toolChange(id) }
        case "STEP_STARTED":
            if let n = e.string("stepName"), Self.phases.contains(n) { out.append(.phase(n)) }
        case "STATE_SNAPSHOT", "STATE_DELTA":
            out.append(.state(state.shared))
            if let steer = (state.shared["caps"] as? [String: Any])?["steer"] as? Bool, steer != lastSteer {
                lastSteer = steer
                out.append(.caps(steer: steer))
            }
        case "RUN_FINISHED", "RUN_ERROR":
            if sawLive, let u = state.turns.last?.usage {
                out.append(.replay(.usage(input: u.input, output: u.output)))
            }
            if !state.permissions.isEmpty { out.append(.interrupts(state.permissions)) }
            out.append(.phase("reposo"))
            out.append(.finished(state.outcome ?? .success))
        case "CUSTOM":
            let v = e["value"] as? [String: Any] ?? [:]
            switch e.string("name") {
            case Custom.tool:
                if let id = v["toolCallId"] as? String { out += toolChange(id) }
            case Custom.delivery:
                // Una entrega que llega al reconectar sin run vivo es HISTORIA: la trae el hilo (REST).
                guard sawLive, let entrega = Self.entrega(v, agentID: agentID, sessionID: sessionID) else { break }
                out.append(.replay(.entrega(entrega)))
            case Custom.replace:
                // Fuera de un run vivo es historia: el texto bueno ya lo trae el hilo (REST).
                guard sawLive, let t = v["content"] as? String else { break }
                out.append(.replay(.reemplazo(t)))
            case Custom.injected:
                out.append(.injected)
            case Custom.title:
                if let t = v["title"] as? String { out.append(.title(t)) }
            case Custom.attachmentsFailed:
                if let m = v["message"] as? String { out.append(.notice(m)) }
            default:
                break
            }
        default:
            break
        }
        return out
    }

    /// La primera señal de trabajo en vivo enciende «trabajando».
    private mutating func live() -> [Output] {
        guard !sawLive else { return [] }
        sawLive = true
        return [.phase("session")]
    }

    /// El paso como `Herramienta`, sólo si cambió algo que se ve.
    private mutating func toolChange(_ id: String) -> [Output] {
        guard let t = state.turns.reversed().lazy.flatMap(\.tools).first(where: { $0.id == id }) else { return [] }
        let h = Self.herramienta(t)
        if lastTool[id] == h { return [] }
        lastTool[id] = h
        return [.replay(.tool(h))]
    }

    /// Un paso AG-UI como lo pinta la app. Con `ghosty.tool`, el nombre para personas; si no, el técnico.
    /// El resultado de la herramienta NO se pinta: el SSE viejo no lo mandaba y la tarjeta no cambia.
    static func herramienta(_ t: AGUIState.Tool) -> Herramienta {
        var u: [String: Any] = [
            "title": t.title ?? t.name ?? "herramienta",
            // Un paso detenido no se pinta como hecho: cancelado o fallido salen igual que antes (fallida).
            "status": t.status == "in_progress" || t.status == "pending" ? "in_progress" : t.status == "completed" ? "completed" : "failed",
        ]
        if let k = t.kind { u["kind"] = k }
        if let p = t.path { u["locations"] = [["path": p]] }
        if let d = t.detail { u["detalle"] = d }
        return ACPClient.herramienta(u, id: t.id)
    }

    /// `ghosty.delivery` como entrega: el payload del relé, ahora con `url` firmada en vez de bytes.
    static func entrega(_ v: [String: Any], agentID: String, sessionID: String) -> Entrega? {
        guard var e = ACPClient.entregaDesde(v, agentID: agentID) else { return nil }
        e.sesionID = (v["sessionId"] as? String) ?? sessionID
        e.url = v["url"] as? String
        e.mime = v["mime"] as? String
        e.bytesRemotos = (v["size"] as? NSNumber)?.intValue
        return e
    }
}
