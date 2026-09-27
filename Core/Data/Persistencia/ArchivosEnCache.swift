import Foundation
import UIKit

/// Los bytes de los archivos de la cuenta, en disco: `Caches/archivos/<fileId>`.
///
/// La llave es el ID y no la URL: la URL va FIRMADA y caduca, así que con ella cada firma
/// nueva sería un archivo «nuevo». Un id de gs no cambia de contenido, así que lo guardado
/// no se revalida: si está, es ése.
///
/// Tope ~200 MB; al pasarse se tira lo que hace más tiempo que no se mira (la fecha de
/// modificación se toca en cada lectura: LRU aproximado sin índice aparte).
enum ArchivosEnDisco {
    static let topeBytes = 200 * 1024 * 1024
    /// Un archivo más grande que esto no se guarda: un video de 150 MB echaría todo lo demás.
    static let maximoPorArchivo = 50 * 1024 * 1024

    private static let cola = DispatchQueue(label: "ghosty.archivos-en-disco", qos: .utility)

    static var carpeta: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("archivos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func url(_ id: String) -> URL {
        carpeta.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"))
    }

    /// ¿Ya está bajado? Barato (sin leer bytes): sirve para decidir entre archivo local y
    /// streaming, como en el video.
    static func hay(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: url(id).path)
    }

    /// Lee fuera del hilo principal: un PDF de 8 MB no puede trabar un scroll.
    static func leer(_ id: String) async -> Data? {
        let destino = url(id)
        return await withCheckedContinuation { cont in
            cola.async {
                guard let d = try? Data(contentsOf: destino), !d.isEmpty else { cont.resume(returning: nil); return }
                tocar(destino)
                cont.resume(returning: d)
            }
        }
    }

    static func guardar(_ datos: Data, id: String) {
        guard !datos.isEmpty, datos.count <= maximoPorArchivo else { return }
        let destino = url(id)
        cola.async {
            try? datos.write(to: destino, options: .atomic)
            purgar()
        }
    }

    /// Marca el archivo como recién usado.
    static func tocar(_ destino: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destino.path)
    }

    static func olvidar(_ id: String) {
        let destino = url(id)
        cola.async { try? FileManager.default.removeItem(at: destino) }
    }

    /// Se pasa del tope → fuera lo más viejo hasta quedar en el 80 %.
    static func purgar() {
        let claves: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let archivos = try? FileManager.default.contentsOfDirectory(
            at: carpeta, includingPropertiesForKeys: claves) else { return }
        let conDatos = archivos.compactMap { u -> (URL, Date, Int)? in
            guard let v = try? u.resourceValues(forKeys: Set(claves)),
                  let fecha = v.contentModificationDate, let peso = v.fileSize else { return nil }
            return (u, fecha, peso)
        }
        var total = conDatos.reduce(0) { $0 + $1.2 }
        guard total > topeBytes else { return }
        let meta = topeBytes * 8 / 10
        for (u, _, peso) in conDatos.sorted(by: { $0.1 < $1.1 }) {
            guard total > meta else { break }
            try? FileManager.default.removeItem(at: u)
            total -= peso
        }
    }

    static func borrarTodo() {
        try? FileManager.default.removeItem(at: carpeta)
    }
}

/// Las miniaturas YA decodificadas (fotos, portadas de PDF): memoria, para que volver a
/// una tarjeta la pinte en el mismo fotograma, sin hueco ni spinner.
enum MiniaturasEnMemoria {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 60 * 1024 * 1024
        return c
    }()

    static func imagen(_ clave: String) -> UIImage? { cache.object(forKey: clave as NSString) }

    static func guardar(_ img: UIImage, clave: String) {
        let costo = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
        cache.setObject(img, forKey: clave as NSString, cost: costo)
    }

    static func olvidar(_ clave: String) { cache.removeObject(forKey: clave as NSString) }
    static func borrarTodo() { cache.removeAllObjects() }
}

/// Las últimas respuestas de `/me/files` tal cual llegaron: la de la cuenta (Archivos) y
/// las de cada conversación (adjuntos del hilo). Molde de `UsoEnDisco`: se pinta con lo
/// guardado al instante y se refresca en segundo plano.
enum ListasDeArchivosEnDisco {
    private static var carpeta: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("listas-de-archivos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func archivo(_ clave: String) -> URL {
        carpeta.appendingPathComponent(clave.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    static func guardar(_ data: Data, clave: String) {
        try? data.write(to: archivo(clave), options: .atomic)
    }

    static func leer(clave: String) -> Data? {
        try? Data(contentsOf: archivo(clave))
    }

    static func borrarTodo() {
        try? FileManager.default.removeItem(at: carpeta)
    }
}

/// Todo lo de archivos que vive en caché, de una vez. Al cerrar sesión: lo de una cuenta
/// no se le enseña a la siguiente.
enum CacheDeArchivos {
    static func borrarTodo() {
        ArchivosEnDisco.borrarTodo()
        ListasDeArchivosEnDisco.borrarTodo()
        MiniaturasEnMemoria.borrarTodo()
        CacheDeImagenes.borrarTodo()
    }
}
