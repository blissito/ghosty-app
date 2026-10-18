import Foundation

/// Lee eventos AG-UI y dice qué le toca a la app: el texto y los pasos van como `Replay` (lo que ya
/// pinta el hilo), lo demás como señales (permisos, estado, cola). Puro: sin red y sin store.
///
/// ⚠️ No es un traductor de protocolo: el cable YA es AG-UI y el estado sale del mismo reductor que la
/// web (`AGUIReducer`). Esto sólo reparte ese estado a las piezas de la app que existían antes.
struct AGUIBridge {
    /// Lo que gs manda además del estándar. Nombres acordados con gs (`docs/claude/agui.md` en gs).
    enum Custom {
        /// `{runId}`: el run VIVO al que se engancha una reconexión (para nombrar su burbuja y detenerlo).
        static let run = "ghosty.run"
        /// `{toolCallId, title, kind, detail?, path?}`: cómo se nombra un paso para personas.
        static let step = "ghosty.step"
        /// El payload de una entrega, tal como lo emite el relé (`ACPClient.entregaDesde`).
        static let artifact = "ghosty.artifact"
        /// `{phase}`: `waking` (despertando la caja) | `session` (el agente trabaja) | `queued`.
        static let status = "ghosty.status"
        /// `{ahead}`: cuántas conversaciones van delante esperando ranura.
        static let queue = "ghosty.queue"
        /// `{steer}`: si un mensaje con el run vivo ENTRA en él en vez de cortarlo.
        static let caps = "ghosty.caps"
        static let title = "ghosty.title"
    }

    enum Output {
        case replay(ACPClient.Replay)
        /// Aprobaciones abiertas al cerrar el run (`outcome: interrupt`).
        case interrupts([AGUIState.Permission])
        /// Fase del turno según el servidor: `waking` | `session` | `reposo`.
        case phase(String)
        case queue(Int)
        case caps(steer: Bool)
        case title(String)
        /// El run terminó (cualquier `outcome`).
        case finished(AGUIState.Outcome)
    }

    let agentID: String
    let sessionID: String
    private(set) var state = AGUIState()
    /// Desde `MESSAGES_SNAPSHOT`: lo que siga es el run vivo (si lo hay), no historia.
    private(set) var sawSnapshot = false
    /// Hubo trabajo en vivo después del snapshot (o en un run propio).
    private(set) var sawLive = false
    /// El run cuyo trabajo se está pintando: el propio, o el vivo al que nos enganchamos.
    private(set) var liveRunId: String?
    /// Herramientas ya contadas, para mandar sólo cambios.
    private var lastTool: [String: Herramienta] = [:]

    init(agentID: String, sessionID: String, runId: String? = nil) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.liveRunId = runId
    }

    mutating func apply(_ e: AGUIEvent, now: Date = Date()) -> [Output] {
        state = AGUIReducer.reduce(state, e, now: now)
        var out: [Output] = []
        switch e.type {
        case "RUN_STARTED":
            // Un run PROPIO (`liveRunId` puesto al mandar) es el turno: su burbuja se llama así.
            if let id = liveRunId { out.append(.replay(.turno(id))) }
        case "MESSAGES_SNAPSHOT":
            sawSnapshot = true
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
        case "RUN_FINISHED", "RUN_ERROR":
            if let u = state.turns.last?.usage { out.append(.replay(.usage(input: u.input, output: u.output))) }
            if !state.permissions.isEmpty { out.append(.interrupts(state.permissions)) }
            out.append(.phase("reposo"))
            out.append(.finished(state.outcome ?? .success))
        case "CUSTOM":
            let v = e["value"] as? [String: Any] ?? [:]
            switch e.string("name") {
            case Custom.run:
                if let id = v["runId"] as? String {
                    liveRunId = id
                    sawLive = true
                    out.append(.replay(.turno(id)))
                    out.append(.phase("session"))
                }
            case Custom.step:
                if let id = v["toolCallId"] as? String { out += toolChange(id) }
            case Custom.artifact:
                if var entrega = ACPClient.entregaDesde(v, agentID: agentID) {
                    entrega.sesionID = (v["sessionId"] as? String) ?? sessionID
                    out += live()
                    out.append(.replay(.entrega(entrega)))
                }
            case Custom.status:
                if let p = v["phase"] as? String { out.append(.phase(p)) }
            case Custom.queue:
                if let n = v["ahead"] as? Int { out.append(.queue(n)) }
            case Custom.caps:
                out.append(.caps(steer: v["steer"] as? Bool == true))
            case Custom.title:
                if let t = v["title"] as? String { out.append(.title(t)) }
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

    /// Un paso AG-UI como lo pinta la app. Con `ghosty.step`, el nombre para personas; si no, el técnico.
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
}
