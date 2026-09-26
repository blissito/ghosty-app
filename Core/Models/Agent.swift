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
    /// Correo del dueño si el agente es compartido conmigo.
    var compartidoPor: String? = nil
    /// Último uso mío (lo dice gs), para ordenar.
    var ultimaActividad: Date? = nil
    /// De qué espacio es (lo dice gs). nil = gs viejo o EasyBits: cuenta como personal.
    var space: AgentSpace? = nil
}

/// El espacio de un agente: la lista se agrupa por esto cuando hay más de uno. Un agente
/// vive en varios canales pero en UN espacio.
struct AgentSpace: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case personal, workspace, shared }
    var kind: Kind
    /// Id del workspace; vacío en personal y compartido.
    var id: String = ""
    /// Nombre visible del workspace (su slug).
    var name: String = ""
    /// `teams`, `sales` o `both`: qué pantallas de más le tocarán a ese espacio.
    var combo: String? = nil

    static let personal = AgentSpace(kind: .personal)

    /// Lo que manda gs en `espacio` (`tipo`: personal | workspace | compartido).
    init?(json: [String: Any]?) {
        guard let json, let tipo = json["tipo"] as? String else { return nil }
        switch tipo {
        case "personal": kind = .personal
        case "workspace":
            kind = .workspace
            id = json["id"] as? String ?? ""
            name = json["nombre"] as? String ?? ""
            combo = json["combo"] as? String
        case "compartido": kind = .shared
        default: return nil
        }
    }

    init(kind: Kind, id: String = "", name: String = "", combo: String? = nil) {
        self.kind = kind; self.id = id; self.name = name; self.combo = combo
    }

    /// Título de la sección en la lista.
    var title: String {
        switch kind {
        case .personal: return "Tuyos"
        case .workspace: return name.prefix(1).uppercased() + name.dropFirst()
        case .shared: return "Compartidos contigo"
        }
    }
}
