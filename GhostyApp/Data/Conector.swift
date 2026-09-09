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
    /// ¿Se puede conectar YA? `false` = está en el catálogo pero todavía no se activa desde
    /// el teléfono. Se enseña igual, con leyenda y desactivado: ver la lista de lo que
    /// viene es información útil; un vacío no dice nada.
    var disponible: Bool = true
    /// Desde cuándo, si está conectado.
    var desde: Date?

    /// La marca de casa, si la tenemos empaquetada.
    ///
    /// ⚠️ Sólo las NUESTRAS. El logo de un tercero es una licencia que no tenemos, y además
    /// la lista la manda el servidor: un conector nuevo tiene que verse decente sin
    /// actualizar la app, y para eso está el símbolo.
    var marca: String? {
        switch id {
        case "easybits": return "marca-easybits"
        case "denik":    return "marca-denik"
        case "mailmask": return "marca-mailmask"
        default:         return nil
        }
    }

    /// El símbolo con el que se pinta cuando no hay marca propia.
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
