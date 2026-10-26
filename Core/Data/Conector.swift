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
    /// PNG de 96 px que gs sirve para TODOS los conectores (`/api/v2/connectors/<id>/logo.png`).
    /// Es la fuente principal: un conector nuevo trae su logo sin versión nueva de la app.
    var logoPng: String? = nil
    /// Lo que hay que leer ANTES de ir a conectar (hoy sólo GitHub). Lo manda el servidor.
    var intro: IntroDeConector? = nil
    /// Un botón para administrarlo ya conectado (GitHub: «Repos»).
    var manage: GestionDeConector? = nil
    /// El color de la marca (`logo.color`, `#181717`): la franja de la tarjeta del chat.
    var logoColor: String? = nil
    /// `oauth` o `credential` (llave). Una de llave no abre navegador.
    var kind: String? = nil

    /// Arma un conector desde una fila de `GET /api/v2/me/connectors`. `nil` sin `id`.
    ///
    /// `intro` y `manage` son opcionales a propósito: un servidor viejo no los manda y uno
    /// mal formado no debe tumbar la lista entera.
    static func desdeJSON(_ c: [String: Any]) -> Conector? {
        guard let id = c["id"] as? String else { return nil }
        // gs manda `toISOString()` (con milisegundos) y el formateador por default no los lee:
        // `desde` llegaba siempre nil. Se prueba con fracción y luego sin ella.
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        return Conector(id: id,
                        nombre: (c["nombre"] as? String) ?? (c["name"] as? String) ?? id,
                        conectado: (c["conectado"] as? Bool) ?? (c["connected"] as? Bool) ?? false,
                        // ⚠️ Este campo NO se leía, así que TODA fila del servidor
                        // quedaba en el default `true`: los conectores que aún no
                        // existen se pintaban como si se pudieran conectar, y el botón
                        // llevaba a un error. El servidor es quien sabe cuáles sirve.
                        disponible: (c["disponible"] as? Bool) ?? (c["available"] as? Bool) ?? true,
                        desde: (c["desde"] as? String).flatMap { isoFrac.date(from: $0) ?? iso.date(from: $0) },
                        descripcion: (c["descripcion"] as? String) ?? (c["description"] as? String),
                        logoSrc: (c["logo"] as? [String: Any])?["src"] as? String,
                        sfSymbol: c["sfSymbol"] as? String,
                        logoPng: c["logoPng"] as? String,
                        intro: (c["intro"] as? [String: Any]).flatMap(IntroDeConector.desdeJSON),
                        manage: (c["manage"] as? [String: Any]).flatMap(GestionDeConector.desdeJSON),
                        logoColor: (c["logo"] as? [String: Any])?["color"] as? String,
                        kind: c["kind"] as? String)
    }

    /// La URL del PNG del servidor, si la mandó (absoluta; relativa se resuelve contra gs).
    var logoPngURL: URL? {
        guard let logoPng, !logoPng.isEmpty else { return nil }
        return URL(string: logoPng, relativeTo: Session.base)?.absoluteURL
    }

    /// El color de marca como `UInt32` (`#181717` → 0x181717), si vino bien formado.
    var brandHex: UInt32? {
        guard let logoColor else { return nil }
        let h = logoColor.hasPrefix("#") ? String(logoColor.dropFirst()) : logoColor
        guard h.count == 6 else { return nil }
        return UInt32(h, radix: 16)
    }

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
        // sacados del catálogo de gs `app/lib/connectors/registry.ts`). Respaldo offline
        // del `logoPng` del servidor.
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
        // ⚠️ Sólo por id exacto. El respaldo por nombre con `contains` hacía que
        // google-contacts cayera en el logo de Google; desde que gs manda `logoPng` para
        // todos, el asset local es sólo el respaldo sin red.
        return porId[id]
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

/// La hoja que se lee antes de conectar: qué marcar del otro lado y por qué es seguro.
struct IntroDeConector: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let title: String
        let body: String
    }
    let title: String
    let subtitle: String
    let items: [Item]
    let continueLabel: String
    let cancelLabel: String

    /// `nil` si falta cualquier texto: una hoja a medias confunde más que no enseñarla.
    static func desdeJSON(_ j: [String: Any]) -> IntroDeConector? {
        guard let title = j["title"] as? String,
              let continueLabel = j["continueLabel"] as? String,
              let cancelLabel = j["cancelLabel"] as? String
        else { return nil }
        let items = ((j["items"] as? [[String: Any]]) ?? []).compactMap { i -> Item? in
            guard let t = i["title"] as? String, let b = i["body"] as? String else { return nil }
            return Item(title: t, body: b)
        }
        return IntroDeConector(title: title, subtitle: (j["subtitle"] as? String) ?? "",
                               items: items, continueLabel: continueLabel, cancelLabel: cancelLabel)
    }
}

/// El botón para administrar un conector ya conectado.
struct GestionDeConector: Equatable, Sendable {
    let label: String
    /// https absoluta o ruta del sitio (`/settings/…`), relativa a `Session.base`.
    let href: String

    var url: URL? {
        guard !href.isEmpty else { return nil }
        return URL(string: href, relativeTo: Session.base)?.absoluteURL
    }

    static func desdeJSON(_ j: [String: Any]) -> GestionDeConector? {
        guard let label = j["label"] as? String, !label.isEmpty,
              let href = j["href"] as? String, !href.isEmpty
        else { return nil }
        return GestionDeConector(label: label, href: href)
    }
}
