import SwiftUI
import UIKit
import Observation

/// Qué imagen se está mirando a pantalla completa.
///
/// ⚠️ Vive fuera de las vistas porque quien pide abrirla está MUY adentro: una imagen de
/// una respuesta la pinta el proveedor de MarkdownUI, y desde ahí no hay forma de subir un
/// binding hasta la raíz. `RootView` lo inyecta y presenta.
@Observable
@MainActor
final class Visor {
    var imagen: UIImage?
    var titulo = ""

    func abrir(_ img: UIImage, titulo: String = "") {
        self.titulo = titulo
        imagen = img
    }
}

/// Lo bajado por URL, en memoria y en disco.
///
/// ⚠️ Vive FUERA de las vistas a propósito. Estaba en un `@State` de la tarjeta, y una
/// vista de SwiftUI se destruye al cambiar de conversación: la vista previa de un PDF
/// aparecía al abrirlo y **desaparecía al volver**, porque los bytes se iban con la vista.
/// Lo que se ha bajado una vez no se vuelve a bajar ni se pierde.
@MainActor
enum Descargas {
    private static var memoria: [String: Data] = [:]
    private static var enVuelo: [String: Task<Data?, Never>] = [:]

    private static var carpeta: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "descargas")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func clave(_ url: URL) -> String {
        // Una URL firmada cambia de firma pero no de objeto: la llave es sin la firma, así
        // una liga re-firmada encuentra lo que ya se bajó.
        var texto = url.absoluteString
        if texto.contains("X-Amz-"), let corte = texto.firstIndex(of: "?") { texto = String(texto[..<corte]) }
        var h: UInt64 = 0xcbf29ce484222325
        for b in texto.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return "d" + String(h, radix: 36)
    }

    static func bytes(_ url: URL) async -> Data? {
        let k = clave(url)
        if let ya = memoria[k] { return ya }
        if let t = enVuelo[k] { return await t.value }
        let destino = carpeta.appending(path: k)
        if let d = try? Data(contentsOf: destino), !d.isEmpty {
            memoria[k] = d
            return d
        }
        let tarea = Task<Data?, Never> {
            func bajar(_ u: URL) async -> Data? {
                guard let (d, resp) = try? await URLSession.shared.data(from: u) else { return nil }
                // El código sólo se mira si HAY respuesta HTTP: un `file://` no trae ninguna.
                let codigo = (resp as? HTTPURLResponse)?.statusCode
                guard codigo == nil || codigo == 200, !d.isEmpty else { return nil }
                return d
            }
            // ⚠️ La URL que el agente escribió en un ```eb-audio```/```eb-file``` caduca a los
            // 7 días: si ya no sirve, gs la vuelve a firmar (`/me/files/fresh`) y se reintenta.
            // Era la nota de voz que «ya no está» al volver a un hilo viejo (30-sep).
            var d = await bajar(url)
            if d == nil, url.scheme == "https", let fresca = try? await GhostyAPI.urlFresca(url) {
                d = await bajar(fresca)
            }
            guard let d else { return nil }
            try? d.write(to: destino, options: .atomic)
            return d
        }
        enVuelo[k] = tarea
        let d = await tarea.value
        enVuelo[k] = nil
        if let d { memoria[k] = d }
        return d
    }
}

/// Baja imágenes por URL y se queda con el `UIImage`.
///
/// ⚠️ `AsyncImage` da un `Image` de SwiftUI, que **no se puede volver a abrir**: para el
/// visor hace falta el `UIImage`. Además reutiliza el mismo caché de disco que ya usan los
/// adjuntos, así que una imagen mirada dos veces se baja una.
@MainActor
enum CargadorDeImagen {
    private static var memoria: [String: UIImage] = [:]
    private static var enVuelo: [String: Task<UIImage?, Never>] = [:]

    private static var carpeta: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "imagenes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Nombre en disco: la URL no sirve tal cual como nombre de archivo.
    private static func clave(_ url: URL) -> String {
        // Una URL firmada cambia de firma pero no de objeto: la llave es sin la firma, así
        // una liga re-firmada encuentra lo que ya se bajó.
        var texto = url.absoluteString
        if texto.contains("X-Amz-"), let corte = texto.firstIndex(of: "?") { texto = String(texto[..<corte]) }
        var h: UInt64 = 0xcbf29ce484222325
        for b in texto.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return "w" + String(h, radix: 36)
    }

    /// Sin esperar: lo que ya está en memoria, para pintar en el primer fotograma.
    static func enMemoria(_ url: URL) -> UIImage? { memoria[clave(url)] }

    static func imagen(_ url: URL) async -> UIImage? {
        let k = clave(url)
        if let ya = memoria[k] { return ya }
        if let t = enVuelo[k] { return await t.value }

        let destino = carpeta.appending(path: k)
        if let d = try? Data(contentsOf: destino), let img = UIImage(data: d) {
            memoria[k] = img
            return img
        }
        let tarea = Task<UIImage?, Never> {
            guard let (d, _) = try? await URLSession.shared.data(from: url) else { return nil }
            try? d.write(to: destino, options: .atomic)
            return UIImage(data: d)
        }
        enVuelo[k] = tarea
        let img = await tarea.value
        enVuelo[k] = nil
        if let img { memoria[k] = img }
        return img
    }
}
