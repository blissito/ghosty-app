import ImageIO
import SwiftUI
import UIKit

/// Decodifica bytes de imagen respetando los GIF animados.
///
/// ⚠️ `UIImage(data:)` con un GIF sólo toma el PRIMER cuadro: el GIF se veía estático en el
/// chat (bliss, 7-oct). Aquí un GIF de varios cuadros sale como `UIImage.animatedImage`, que
/// guarda los cuadros en `images`. Todo lo demás sigue por `UIImage(data:)` tal cual.
enum DecodificadorDeImagen {
    /// Lado máximo en píxeles de cada cuadro: un GIF de 1000 px × 100 cuadros sin acotar
    /// son ~400 MB decodificados. 720 px basta para la burbuja y el visor.
    private static let ladoMaximo = 720
    /// Tope de cuadros: más que esto no se nota y sí pesa en memoria.
    private static let cuadrosMaximos = 240

    static func esGIF(_ datos: Data) -> Bool {
        datos.count > 6 && datos.prefix(3).elementsEqual("GIF".utf8)
    }

    /// El mime real de una imagen por sus primeros bytes (el selector de fotos no lo dice).
    static func mime(_ datos: Data) -> String? {
        let b = [UInt8](datos.prefix(12))
        guard b.count >= 4 else { return nil }
        if esGIF(datos) { return "image/gif" }
        if b[0] == 0x89, b[1] == 0x50 { return "image/png" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "image/jpeg" }
        if b.count >= 12, b[0...3].elementsEqual("RIFF".utf8), b[8...11].elementsEqual("WEBP".utf8) { return "image/webp" }
        if b.count >= 12, b[4...7].elementsEqual("ftyp".utf8) { return "image/heic" }
        return nil
    }

    static func imagen(_ datos: Data) -> UIImage? {
        guard esGIF(datos), let animada = gifAnimado(datos) else { return UIImage(data: datos) }
        return animada
    }

    /// Para el primer pintado: decodifica ya (como `preparingForDisplay`) sin perder la
    /// animación, que `preparingForDisplay` tira.
    static func imagenLista(_ datos: Data) -> UIImage? {
        guard let img = imagen(datos) else { return nil }
        return img.images == nil ? (img.preparingForDisplay() ?? img) : img
    }

    private static func gifAnimado(_ datos: Data) -> UIImage? {
        guard let fuente = CGImageSourceCreateWithData(datos as CFData, nil) else { return nil }
        let total = CGImageSourceGetCount(fuente)
        guard total > 1 else { return nil }
        let opciones: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: ladoMaximo,
        ]
        var cuadros: [UIImage] = []
        var duracion: Double = 0
        for i in 0..<min(total, cuadrosMaximos) {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(fuente, i, opciones as CFDictionary) else { continue }
            cuadros.append(UIImage(cgImage: cg))
            duracion += retardo(fuente, i)
        }
        guard cuadros.count > 1 else { return cuadros.first }
        return UIImage.animatedImage(with: cuadros, duration: duracion)
    }

    /// Retardo de un cuadro. Como los navegadores: ≤ 10 ms se trata como 100 ms.
    private static func retardo(_ fuente: CGImageSource, _ i: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(fuente, i, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return d <= 0.011 ? 0.1 : d
    }
}

/// Una imagen redimensionable que ANIMA si es un GIF.
///
/// Equivale a `Image(uiImage:).resizable().aspectRatio(contentMode:)`. `Image(uiImage:)` de
/// SwiftUI pinta sólo el primer cuadro de una `UIImage` animada; para esas va un
/// `UIImageView`. Las imágenes normales siguen siendo `Image` (cero costo extra en el scroll).
struct ImagenAnimable: View {
    let imagen: UIImage
    var modo: ContentMode = .fit

    init(_ imagen: UIImage, modo: ContentMode = .fit) {
        self.imagen = imagen
        self.modo = modo
    }

    var body: some View {
        if imagen.images != nil {
            VistaAnimada(imagen: imagen, modo: modo)
                .aspectRatio(imagen.size, contentMode: modo)
        } else {
            Image(uiImage: imagen).resizable().aspectRatio(contentMode: modo)
        }
    }
}

private struct VistaAnimada: UIViewRepresentable {
    let imagen: UIImage
    let modo: ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.clipsToBounds = true
        // Sin esto el UIImageView exige su tamaño intrínseco (el del GIF) y rompe el marco.
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        v.contentMode = modo == .fit ? .scaleAspectFit : .scaleAspectFill
        if v.image !== imagen { v.image = imagen }
        if !v.isAnimating { v.startAnimating() }
    }

    func sizeThatFits(_ propuesta: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        propuesta.replacingUnspecifiedDimensions(by: imagen.size)
    }
}
