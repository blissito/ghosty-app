import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// La miniatura de un video: un cuadro del primer segundo (360 px). La usan Archivos,
/// «Mis archivos» y la burbuja de lo que mandaste, para que un video nunca sea sólo su sigla.
///
/// Memoria → disco → generada del asset. El id del archivo no cambia, así que la miniatura
/// no caduca. El asset sale, en este orden, de los bytes que ya tengas, del disco si ya se
/// bajó, o por streaming con la firma guardada (y, si ésa ya no sirve, con una fresca).
enum CuadroDeVideo {
    private static var carpeta: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "miniaturas-video")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// `id`: la llave del caché (el id remoto si lo hay). `remotoID`: el archivo de la cuenta.
    static func de(id: String, remotoID: String? = nil, url: String? = nil,
                   datos: Data? = nil, mime: String? = nil) async -> UIImage? {
        let clave = "cuadro:" + id
        if let ya = MiniaturasEnMemoria.imagen(clave) { return ya }
        let archivo = carpeta.appending(path: id.replacingOccurrences(of: "/", with: "_") + ".jpg")
        if let d = try? Data(contentsOf: archivo), let img = UIImage(data: d) {
            MiniaturasEnMemoria.guardar(img, clave: clave)
            return img
        }
        // Sin extensión en el nombre, AVFoundation necesita que le digan qué es.
        let tipo = mime ?? "video/mp4"
        var img: UIImage?
        if let datos, !datos.isEmpty {
            let tmp = FileManager.default.temporaryDirectory.appending(path: "cuadro-\(UUID().uuidString)")
            if (try? datos.write(to: tmp)) != nil {
                img = await generar(AVURLAsset(url: tmp, options: [AVURLAssetOverrideMIMETypeKey: tipo]))
                try? FileManager.default.removeItem(at: tmp)
            }
        }
        if img == nil, let rid = remotoID, ArchivosEnDisco.hay(rid) {
            img = await generar(AVURLAsset(url: ArchivosEnDisco.url(rid), options: [AVURLAssetOverrideMIMETypeKey: tipo]))
        }
        if img == nil, let rid = remotoID {
            for fresca in [false, true] {
                guard let f = try? await FirmasEnMemoria.firma(rid, fresca: fresca), let u = URL(string: f) else { continue }
                if let i = await generar(AVURLAsset(url: u)) { img = i; break }
                FirmasEnMemoria.olvidar(rid)
            }
        }
        if img == nil, let s = url, let u = URL(string: s) { img = await generar(AVURLAsset(url: u)) }
        guard let img else { return nil }
        MiniaturasEnMemoria.guardar(img, clave: clave)
        if let d = img.jpegData(compressionQuality: 0.8) { try? d.write(to: archivo, options: .atomic) }
        return img
    }

    /// Al segundo 1 (el 0 suele ser negro o un fundido); un video más corto, el primero.
    private static func generar(_ asset: AVURLAsset) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 360, height: 360)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        if let (cg, _) = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)) { return UIImage(cgImage: cg) }
        if let (cg, _) = try? await gen.image(at: .zero) { return UIImage(cgImage: cg) }
        return nil
    }

    static func borrarTodo() {
        try? FileManager.default.removeItem(at: carpeta)
    }
}
