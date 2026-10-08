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
    /// En vivo: en qué largo del texto arrancó cada herramienta. Lo de antes de cada corte
    /// es narración y se pinta como pasos (`AgentNarration`). Al recargar no hay cortes: gs
    /// guarda esa narración como líneas `- ✓ …` y se parte por ahí.
    var narrationCuts: [Int] = []

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
    /// ¿Lo último que hay en el hilo lo escribió el agente? Con eso se sabe que una
    /// conversación CONTESTÓ, aunque el turno no fuera nuestro —al engancharse a uno que
    /// ya estaba corriendo, aquí no hay turno local que mirar—.
    var esDeUsuario: Bool { if case .user = kind { return true } else { return false } }

    var esDelAgente: Bool {
        switch kind {
        case .agent, .entrega: return true
        default: return false
        }
    }

    enum Kind: Equatable, Sendable {
        /// El texto y, si los hubo, lo que se mandó con él.
        ///
        /// ⚠️ Van los ADJUNTOS, no sus nombres. Enseñar «`foto-1.jpg`» en la burbuja no dice
        /// qué mandaste —de tres fotos del carrete no distingues cuál— y además los backticks
        /// salían literales, porque la burbuja del usuario es texto plano, no Markdown.
        /// `steer` = se mandó con el turno ya corriendo y ENTRÓ en él. Se dice en la
        /// burbuja porque no es un mensaje normal: no abre turno, corrige el que hay.
        case user(String, adjuntos: [Adjunto] = [], steer: Bool = false)
        case agent(text: String, tools: ToolRun?, trailing: String?)
        case prCard(PullRequestCard)
        /// Algo que el agente hizo llegar: un archivo o un artefacto. Ver `Entregas.swift`.
        case entrega(Entrega)
        /// Línea de la plataforma (turno programado, entrega de un encargo): sólo la causa,
        /// centrada y chica. Nace de un mensaje de usuario que empieza por «⏰ ».
        case sistema(String)
        case typing
    }

    let id: String
    var kind: Kind
    /// Su número en la copia de gs (`ConversationMessage.seq`): la identidad que deja
    /// FUNDIR lo que llega en vez de reemplazar el hilo. `nil` = aún no lo confirma gs
    /// (tu mensaje recién mandado, la respuesta en streaming, una entrega local).
    var seq: Int? = nil
    /// El turno al que pertenece: con él se reconcilia lo optimista con lo guardado.
    var turnId: String? = nil
}
