import Foundation
import UniformTypeIdentifiers

/// Algo que la persona quiere mandarle al agente.
///
/// ⚠️ **Hay DOS caminos y no son intercambiables**, y esto se midió contra la caja antes de
/// escribirlo (`initialize` declara `promptCapabilities: {image: true, audio: false,
/// embeddedContext: true}`):
///
/// | Bloque del prompt | Qué pasa |
/// |---|---|
/// | `image` con base64 | el agente la ve |
/// | `resource` con `text` | el agente lo lee |
/// | `resource` con `blob` | **lo acepta sin error y NO lo ve** |
///
/// Ese último es el fallo mudo perfecto —turno en verde y el agente diciendo que no le
/// llegó nada—, así que un PDF NO se empaqueta en el prompt: se **sube** a la máquina del
/// agente y se le dice la ruta. Es además lo correcto: su caja trae `pdftotext`, poppler y
/// tesseract, o sea que lee un PDF mejor, más barato y sin perder el texto de lo que lo
/// haría el modelo mirando páginas rasterizadas.
///
/// Es la misma doctrina que ya usa Teams: **al agente se le da ACCESO al archivo, no el
/// archivo**.
struct Adjunto: Identifiable, Equatable, Sendable {
    static func == (a: Adjunto, b: Adjunto) -> Bool { a.id == b.id && a.remoto?.id == b.remoto?.id }

    let id: String
    var nombre: String
    var mime: String
    var datos: Data
    /// Lo que devolvió la subida a gs. `nil` = todavía no se ha subido, o falló.
    var remoto: GhostyAPI.ArchivoRemoto?
    /// Sólo en una nota de voz: cuánto dura y su onda. Sin esto se vería como un archivo
    /// cualquiera, y una nota de voz sin duración no se sabe si son 3 segundos o 3 minutos.
    var segundos: Double?
    var onda: [Float]?

    var esVoz: Bool { mime.hasPrefix("audio/") && segundos != nil }

    /// ¿Viaja dentro del prompt, o se sube y se nombra por su ruta?
    var esImagen: Bool { mime.hasPrefix("image/") }

    var peso: String {
        ByteCountFormatter.string(fromByteCount: Int64(datos.count), countStyle: .file)
    }

    /// El icono con el que se enseña mientras espera en el compositor.
    var icono: String {
        if esImagen { return "photo" }
        switch mime {
        case "application/pdf": return "doc.richtext"
        case let m where m.hasPrefix("text/"): return "doc.plaintext"
        default: return "paperclip"
        }
    }

    init(id: String = UUID().uuidString, nombre: String, mime: String, datos: Data,
         segundos: Double? = nil, onda: [Float]? = nil) {
        self.id = id
        self.nombre = nombre
        self.mime = mime
        self.datos = datos
        self.segundos = segundos
        self.onda = onda
    }

    /// Una nota de voz recién grabada.
    init(voz clip: GrabadorDeVoz.Clip) {
        // El nombre lleva la hora porque acaba impreso en el almacenamiento de la cuenta y
        // "audio.m4a" repetido veinte veces no se puede distinguir.
        let sello = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        self.init(nombre: "nota-de-voz-\(sello).m4a", mime: "audio/mp4",
                  datos: clip.datos, segundos: clip.segundos, onda: clip.onda)
    }

    /// Desde un archivo del disco. El mime sale del sistema, no de la extensión a mano.
    init?(url: URL) {
        // ⚠️ Un archivo elegido con el explorador llega con alcance de seguridad prestado:
        // sin este par, `Data(contentsOf:)` falla con "no tienes permiso" para todo lo que
        // no esté en el sandbox de la app — que es justo lo que uno elige ahí.
        let abierto = url.startAccessingSecurityScopedResource()
        defer { if abierto { url.stopAccessingSecurityScopedResource() } }
        guard let datos = try? Data(contentsOf: url) else { return nil }
        let tipo = UTType(filenameExtension: url.pathExtension)
        self.init(nombre: url.lastPathComponent,
                  mime: tipo?.preferredMIMEType ?? "application/octet-stream",
                  datos: datos)
    }
}
