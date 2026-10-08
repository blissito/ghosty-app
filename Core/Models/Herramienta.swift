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
        /// Generar o editar una imagen. Studio la manda con `kind: "image"` y título
        /// «Creando imagen»/«Editando imagen» (el prompt va en `detalle`).
        case imagen = "image"
        /// Le encargó algo a un subagente (la tool `Agent`). gs la manda con `kind: "delegate"`
        /// y título «Solicité: …» / «Mandé a un ghostyllo: …» (antes «Encargué»); antes, «Delegando».
        case delegate

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
            case .imagen:  "photo"
            case .delegate: "person.2"
            case .other:   "wrench.adjustable"
            }
        }

        var tinte: (fg: Color, bg: Color) {
            switch self {
            case .delete:          (.gDangerInk, .gDangerTint)
            case .edit, .move:     (.gPrimary, .gPrimaryTint)
            case .search, .fetch, .imagen: (.gPrimary, .gPrimaryTint)
            case .think:           (.gInk3, .gFill)
            default:               (.gInk2, .gFill)
            }
        }
    }

    /// Cómo va. ⚠️ Antes esto era un `Bool`, así que "corriendo" y "falló" eran lo mismo:
    /// un paso que revienta se pintaba igual que uno que salió bien.
    enum Estado: Sendable { case corriendo, hecha, fallida }

    /// ¿Es un encargo a un subagente? Por la clase y, en hilos guardados antes de `delegate`,
    /// por el título.
    var isDelegation: Bool {
        clase == .delegate || titulo == "Delegando"
            || titulo.hasPrefix("Solicité:") || titulo.hasPrefix("Encargué:") || titulo.hasPrefix("Mandé a un ghostyllo:")
            || titulo.hasPrefix("Mandé a un ghostillo:")
    }

    let id: String
    var titulo: String
    var clase: Clase
    var estado: Estado
    /// Lo que devolvió, si devolvió algo legible. Se enseña recortado.
    var salida: String?
    /// El archivo que tocó, si lo dice.
    var donde: String?
    /// QUÉ hizo, en una línea: el comando, la búsqueda, la URL. goose titula «Terminal»
    /// y sin esto diez pasos seguidos eran diez filas iguales.
    var detalle: String?

    var esperando: Bool { estado == .corriendo }

    /// ¿Está creando (o editando) una imagen? Por la clase, o —mientras Studio no manda
    /// `kind: "image"`— porque el comando llama al SDK de imágenes de la caja.
    var esImagen: Bool {
        clase == .imagen
            || titulo.contains("/opt/gs-sdk/image.mjs")
            || (detalle ?? "").contains("/opt/gs-sdk/image.mjs")
    }

    /// Editar una imagen existente (y no crear una nueva).
    var editaImagen: Bool {
        titulo.localizedCaseInsensitiveContains("editando")
            || (detalle ?? "").contains("edit(")
    }

    /// «Terminal · npm test». Si el título ya lo dice (Ghosty-ACP manda «shell · echo
    /// hola»), no se repite.
    var rotulo: String {
        // Detectada por el comando (sin `kind` del servidor): el comando crudo no dice nada.
        if esImagen, clase != .imagen { return editaImagen ? "Editando imagen" : "Creando imagen" }
        guard let d = detalle, !d.isEmpty, !titulo.localizedCaseInsensitiveContains(d) else { return titulo }
        return "\(titulo) · \(d)"
    }
}
