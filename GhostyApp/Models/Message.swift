import Foundation

/// Una llamada a herramienta que el agente hizo dentro de un turno. En el chat se
/// colapsa a una línea: lo que importa es que se vea que trabajó, no el detalle.
struct ToolRun: Equatable, Sendable {
    var count: Int
    var summary: String
}

/// Lo que la plataforma pinta cuando el agente cierra una revisión de PR. El modelo
/// emite los datos; los botones los pone la app — si el modelo pudiera declararlos,
/// inventaría acciones que no existen.
struct PullRequestCard: Equatable, Sendable {
    var reference: String
    var title: String
    var chips: [Chip]

    struct Chip: Equatable, Sendable {
        enum Tone: Sendable { case green, red, neutral }
        var text: String
        var tone: Tone
    }
}

struct Message: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case user(String)
        case agent(text: String, tools: ToolRun?, trailing: String?)
        case prCard(PullRequestCard)
        /// Algo que el agente hizo llegar: un archivo o un artefacto. Ver `Entregas.swift`.
        case entrega(Entrega)
        case typing
    }

    let id: String
    var kind: Kind
}
