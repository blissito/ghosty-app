import Foundation

/// Una app que el agente puede usar en tu nombre.
///
/// ⚠️ El catálogo lo manda el SERVIDOR, no la app. Los conectores se añaden cada pocas
/// semanas y una lista horneada en un binario tarda días en poder corregirse — el mismo
/// criterio que ya se aplicó al tope de almacenamiento y a la lista de proveedores del
/// login.
/// Lo que contestó el servidor cuando se le preguntó por las integraciones.
///
/// ⚠️ Son TRES estados, no dos, y meterlos en un opcional fue el error original: `nil`
/// significaba a la vez "este servidor no las sirve" y "algo falló", así que un 500 o una
/// red caída se veían exactamente igual que la ausencia de la función — la pantalla
/// enseñaba el catálogo apagado y la persona concluía que sus conectores se habían
/// perdido. Un fallo se cuenta; una función que aún no existe se explica.
enum RespuestaDeConectores: Sendable {
    /// El servidor los sirve. Esta lista manda, incluido qué está disponible.
    case servidos([Conector])
    /// Este servidor todavía no sabe de integraciones (404). Se enseña lo que viene.
    case sinSoporte
    /// Algo se rompió, y se dice.
    case fallo(String)
}

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
    /// Qué hace, en una línea. Lo manda el servidor: un conector nuevo no pide versión nueva.
    var descripcion: String? = nil
    /// Ruta del logo en gs (`/connectors/x.png`), relativa a `Session.base`. Respaldo
    /// remoto para los ids que no traen asset empaquetado.
    var logoSrc: String? = nil
    /// El SF Symbol que sugiere el servidor, antes de caer en la inicial.
    var sfSymbol: String? = nil

    /// La URL absoluta del logo remoto, si el servidor mandó uno.
    var logoURL: URL? {
        guard let logoSrc, !logoSrc.isEmpty else { return nil }
        return URL(string: logoSrc, relativeTo: Session.base)?.absoluteURL
    }

    /// La marca de casa, si la tenemos empaquetada.
    ///
    /// La lista la manda el servidor: un conector nuevo sin logo aquí se ve decente con el
    /// símbolo, sin actualizar la app.
    var marca: String? {
        // Logos OFICIALES de todos (lo pidió el dueño, 2026-09-29; los mismos de Android,
        // sacados del catálogo de gs `app/lib/connectors/registry.ts`). Por id y, de
        // respaldo, por nombre. Sin asset: el logo remoto de gs o su símbolo.
        let porId: [String: String] = [
            "google-drive": "logo-google-drive", "drive": "logo-google-drive",
            "mercadopago": "logo-mercadopago", "skydropx": "logo-skydropx",
            "elevenlabs": "logo-elevenlabs", "easybits": "logo-easybits",
            "google-calendar": "logo-google-calendar", "calendar": "logo-google-calendar",
            "denik": "logo-denik", "mailmask": "logo-mailmask", "github": "logo-github",
            "google": "logo-google", "gmail": "logo-google", "calendly": "logo-calendly",
            "spotify": "logo-spotify", "canva": "logo-canva", "odoo": "logo-odoo",
            "kommo": "logo-kommo", "mercadolibre": "logo-mercadolibre", "stripe": "logo-stripe",
            "shopify": "logo-shopify", "woocommerce": "logo-woocommerce", "hubspot": "logo-hubspot",
            "notion": "logo-notion", "slack": "logo-slack", "telegram": "logo-telegram",
            "zoom": "logo-zoom", "clip": "logo-clip", "tiendanube": "logo-tiendanube",
            "excel": "logo-excel", "google-business": "logo-google-business",
            "meta-ads": "logo-meta-ads", "amazon": "logo-amazon", "facturama": "logo-facturama",
        ]
        if let m = porId[id] { return m }
        let n = nombre.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().replacingOccurrences(of: " ", with: "")
        return porId.first { n.contains($0.key.replacingOccurrences(of: "-", with: "")) }?.value
    }

    /// El símbolo con el que se pinta cuando no hay marca propia.
    var icono: String {
        if let sfSymbol, !sfSymbol.isEmpty { return sfSymbol }
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
