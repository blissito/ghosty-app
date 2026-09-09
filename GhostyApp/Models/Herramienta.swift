import SwiftUI

/// Una llamada a herramienta del agente: qué es, cómo va y qué produjo.
///
/// ⚠️ Todo esto YA llegaba y la app lo tiraba. El relé de la caja reenvía los
/// `session/update` verbatim —tiene un test que lo dice—, así que `kind`, `status`,
/// `content` y `locations` estaban ahí; `ACPClient` se quedaba con el título y descartaba
/// el resto, y la pantalla acababa diciendo "Corrió 4 herramientas" con un chevron que no
/// desplegaba nada.
struct Herramienta: Identifiable, Equatable, Sendable {
    /// Lo que la herramienta ES, según ACP. Es lo que da variedad: leer no se parece a
    /// borrar, y el color lo dice antes que el texto.
    enum Clase: String, Sendable {
        case read, edit, execute, search, fetch, think, move, delete, other

        /// ⚠️ Una clase desconocida NO se esconde: cae en `other`. Es la regla de la casa
        /// —una tool que no reconocemos se humaniza, nunca se descarta— y viene de cuando
        /// el agente corría ocho herramientas y la lista enseñaba tres.
        init(_ crudo: String?) { self = Clase(rawValue: crudo ?? "") ?? .other }

        var icono: String {
            switch self {
            case .read:    "doc.text.magnifyingglass"
            case .edit:    "pencil.line"
            case .execute: "terminal"
            case .search:  "magnifyingglass"
            case .fetch:   "globe"
            case .think:   "sparkles"
            case .move:    "arrow.right.doc.on.clipboard"
            case .delete:  "trash"
            case .other:   "wrench.adjustable"
            }
        }

        var tinte: (fg: Color, bg: Color) {
            switch self {
            case .delete:          (.gDangerInk, .gDangerTint)
            case .edit, .move:     (.gPrimary, .gPrimaryTint)
            case .search, .fetch:  (.gPrimary, .gPrimaryTint)
            case .think:           (.gInk3, .gFill)
            default:               (.gInk2, .gFill)
            }
        }
    }

    /// Cómo va. ⚠️ Antes esto era un `Bool`, así que "corriendo" y "falló" eran lo mismo:
    /// un paso que revienta se pintaba igual que uno que salió bien.
    enum Estado: Sendable { case corriendo, hecha, fallida }

    let id: String
    var titulo: String
    var clase: Clase
    var estado: Estado
    /// Lo que devolvió, si devolvió algo legible. Se enseña recortado.
    var salida: String?
    /// El archivo que tocó, si lo dice.
    var donde: String?

    var esperando: Bool { estado == .corriendo }
}
