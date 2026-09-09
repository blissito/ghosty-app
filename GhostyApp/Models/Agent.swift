import Foundation

/// El tono del fantasma. Cada agente tiene el suyo y no cambia: es su identidad
/// visual en la lista, en la cabecera y en la hoja.
enum AgentTone: String, Codable, Sendable {
    case lila, azul, durazno

    var assetName: String {
        switch self {
        case .lila:    return "ghosty-lila"
        case .azul:    return "ghosty-azul"
        case .durazno: return "ghosty-durazno"
        }
    }
}

enum AgentStatus: Equatable, Sendable {
    /// Trabajando ahora, con la tarea que está haciendo
    case working(task: String)
    /// Terminó y espera que alguien decida algo irreversible
    case awaitingApproval
    /// Sin nada en curso
    case idle(since: String)
}

/// `id` es `String` y no `UUID` a propósito: el día del cliente ACP real mapea
/// directo al id de sesión que manda el runtime.
struct Agent: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var tone: AgentTone
    var status: AgentStatus
    /// Motor, para la línea bajo el nombre en la conversación
    var engine: String
}
