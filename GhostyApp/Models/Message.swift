import Foundation

/// Una llamada a herramienta que el agente hizo dentro de un turno. En el chat se
/// colapsa a una línea: lo que importa es que se vea que trabajó, no el detalle.
/// Lo que el agente CORRIÓ en un turno.
///
/// ⚠️ Antes era `(count, summary)`: un contador y un texto que **no se pintaba en ningún
/// sitio**. La burbuja decía "Corrió 4 herramientas" con un chevron decorativo que no
/// desplegaba nada — prometía detalle y no lo daba.
struct ToolRun: Equatable, Sendable {
    var herramientas: [Herramienta]

    var count: Int { herramientas.count }
    var corriendo: Herramienta? { herramientas.last(where: \.esperando) }
    var fallidas: Int { herramientas.filter { $0.estado == .fallida }.count }
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
        /// El texto y, si los hubo, lo que se mandó con él.
        ///
        /// ⚠️ Van los ADJUNTOS, no sus nombres. Enseñar «`foto-1.jpg`» en la burbuja no dice
        /// qué mandaste —de tres fotos del carrete no distingues cuál— y además los backticks
        /// salían literales, porque la burbuja del usuario es texto plano, no Markdown.
        case user(String, adjuntos: [Adjunto] = [])
        case agent(text: String, tools: ToolRun?, trailing: String?)
        case prCard(PullRequestCard)
        /// Algo que el agente hizo llegar: un archivo o un artefacto. Ver `Entregas.swift`.
        case entrega(Entrega)
        case typing
    }

    let id: String
    var kind: Kind
}
