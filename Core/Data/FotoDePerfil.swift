import UIKit

/// La foto de perfil en este teléfono: pinta al instante sin esperar al servidor.
enum FotoDePerfil {
    private static var archivo: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "foto-de-perfil.jpg")
    }
    static func local() -> UIImage? { (try? Data(contentsOf: archivo)).flatMap(UIImage.init(data:)) }
    static func guardar(_ d: Data) { try? d.write(to: archivo, options: .atomic) }
    static func reducir(_ img: UIImage, lado: CGFloat) -> UIImage {
        let escala = min(1, lado / max(img.size.width, img.size.height))
        guard escala < 1 else { return img }
        let tam = CGSize(width: img.size.width * escala, height: img.size.height * escala)
        return UIGraphicsImageRenderer(size: tam).image { _ in img.draw(in: CGRect(origin: .zero, size: tam)) }
    }
}

