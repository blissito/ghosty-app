import Foundation

/// Una app que el agente puede usar en tu nombre.
///
/// ⚠️ El catálogo lo manda el SERVIDOR, no la app. Los conectores se añaden cada pocas
/// semanas y una lista horneada en un binario tarda días en poder corregirse — el mismo
/// criterio que ya se aplicó al tope de almacenamiento y a la lista de proveedores del
/// login.
struct Conector: Identifiable, Equatable, Sendable {
    let id: String
    var nombre: String
    var conectado: Bool
    /// Desde cuándo, si está conectado.
    var desde: Date?

    /// El símbolo con el que se pinta. Del id, porque un logo de marca hay que
    /// empaquetarlo y estos cambian sin que la app se actualice.
    var icono: String {
        switch id {
        case "github":                    return "chevron.left.forwardslash.chevron.right"
        case "google", "gmail":           return "envelope.fill"
        case "google-calendar", "calendar", "denik": return "calendar"
        case "spotify":                   return "music.note"
        case "canva":                     return "paintbrush.fill"
        case "odoo", "kommo":             return "building.2.fill"
        case "calendly":                  return "clock.fill"
        case "drive", "google-drive":     return "folder.fill"
        default:                          return "puzzlepiece.extension.fill"
        }
    }
}
