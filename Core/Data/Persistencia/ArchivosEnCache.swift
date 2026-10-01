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
    /// Un video sí puede más: se baja a ARCHIVO (nunca a memoria) y es lo que hace que
    /// volver a verlo no dependa de la red.
    static let maximoPorVideo = 150 * 1024 * 1024

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

    /// Mueve un archivo ya bajado (p. ej. el temporal de `URLSession.download`) a su sitio.
    /// Se mueve entero y de una: `hay(_:)` nunca ve un video a medias.
    static func guardarArchivo(_ temporal: URL, id: String, maximo: Int = maximoPorVideo) {
        let destino = url(id)
        let peso = (try? temporal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard peso > 0, peso <= maximo else { try? FileManager.default.removeItem(at: temporal); return }
        try? FileManager.default.removeItem(at: destino)
        guard (try? FileManager.default.moveItem(at: temporal, to: destino)) != nil else { return }
        cola.async { purgar() }
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
    /// Lo que se sabe de un video sin abrirlo: duración y aspecto. Va con su portada.
    struct DatosDeVideo: Codable { var segundos: Double?; var aspecto: Double? }

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
        PortadasDeVideo.borrarTodo()
        CuadroDeVideo.borrarTodo()
        FirmasEnMemoria.borrarTodo()
        Task { @MainActor in ReproductoresDeVideo.borrarTodo() }
    }
}

/// Las URLs firmadas ya pedidas, por id, con su caducidad. Volver a un hilo con un video
/// no paga otra vuelta a `/me/files/:id` por firma: la de hace diez minutos sirve.
///
/// ⚠️ Sólo para REPRODUCIR. `GhostyAPI.bajar` sigue pidiendo firma fresca siempre (ver su
/// aviso). Si una firma de aquí falla (403, caducada), quien la usó llama `olvidar` y
/// pide otra.
enum FirmasEnMemoria {
    private static let lock = NSLock()
    private static var firmas: [String: (url: String, vence: Date)] = [:]
    /// Tope propio aunque la firma diga más: el reloj del teléfono puede ir desfasado.
    static let vidaMaxima: TimeInterval = 45 * 60

    static func url(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let f = firmas[id], f.vence > Date() else { firmas[id] = nil; return nil }
        return f.url
    }

    static func guardar(_ url: String, id: String) {
        var vence = Date().addingTimeInterval(vidaMaxima)
        // S3/R2 firman con X-Amz-Date + X-Amz-Expires: si vence antes, manda eso (−2 min).
        if let c = URLComponents(string: url), let items = c.queryItems,
           let fecha = items.first(where: { $0.name == "X-Amz-Date" })?.value,
           let segs = items.first(where: { $0.name == "X-Amz-Expires" })?.value.flatMap(Double.init) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            if let d = f.date(from: fecha) { vence = min(vence, d.addingTimeInterval(segs - 120)) }
        }
        lock.lock(); firmas[id] = (url, vence); lock.unlock()
    }

    static func olvidar(_ id: String) { lock.lock(); firmas[id] = nil; lock.unlock() }
    static func borrarTodo() { lock.lock(); firmas.removeAll(); lock.unlock() }

    /// La firma guardada, o una nueva (que se guarda).
    static func firma(_ id: String, fresca: Bool = false) async throws -> String {
        if !fresca, let u = url(id) { return u }
        let u = try await GhostyAPI.urlDe(id)
        guardar(u, id: id)
        return u
    }
}

/// La portada (primer cuadro) de cada video, más su duración y aspecto: memoria
/// (`MiniaturasEnMemoria`, clave `video:<clave>`) y disco (`Caches/portadas-video`). Es lo
/// que deja pintar la tarjeta de un video al volver al hilo sin spinner ni salto de alto.
enum PortadasDeVideo {
    private static let lock = NSLock()
    private static var datosEnMemoria: [String: MiniaturasEnMemoria.DatosDeVideo] = [:]

    private static var carpeta: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("portadas-video", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func nombre(_ clave: String) -> String { clave.replacingOccurrences(of: "/", with: "_") }

    /// Sin esperar: sólo memoria. Para el primer pintado.
    static func enMemoria(_ clave: String) -> (UIImage?, MiniaturasEnMemoria.DatosDeVideo?) {
        lock.lock(); let d = datosEnMemoria[clave]; lock.unlock()
        return (MiniaturasEnMemoria.imagen("video:" + clave), d)
    }

    /// Del disco (fuera del hilo principal), y la sube a memoria.
    static func delDisco(_ clave: String) async -> (UIImage?, MiniaturasEnMemoria.DatosDeVideo?) {
        let base = carpeta.appendingPathComponent(nombre(clave))
        let (img, datos) = await Task.detached(priority: .userInitiated) { () -> (UIImage?, MiniaturasEnMemoria.DatosDeVideo?) in
            let img = (try? Data(contentsOf: base.appendingPathExtension("jpg"))).flatMap(UIImage.init(data:))?.preparingForDisplay()
            let datos = (try? Data(contentsOf: base.appendingPathExtension("json")))
                .flatMap { try? JSONDecoder().decode(MiniaturasEnMemoria.DatosDeVideo.self, from: $0) }
            return (img, datos)
        }.value
        if let img { MiniaturasEnMemoria.guardar(img, clave: "video:" + clave) }
        if let datos { lock.lock(); datosEnMemoria[clave] = datos; lock.unlock() }
        return (img, datos)
    }

    static func guardar(_ img: UIImage?, datos: MiniaturasEnMemoria.DatosDeVideo, clave: String) {
        if let img { MiniaturasEnMemoria.guardar(img, clave: "video:" + clave) }
        lock.lock(); datosEnMemoria[clave] = datos; lock.unlock()
        let base = carpeta.appendingPathComponent(nombre(clave))
        DispatchQueue.global(qos: .utility).async {
            if let jpg = img?.jpegData(compressionQuality: 0.75) {
                try? jpg.write(to: base.appendingPathExtension("jpg"), options: .atomic)
            }
            if let j = try? JSONEncoder().encode(datos) {
                try? j.write(to: base.appendingPathExtension("json"), options: .atomic)
            }
        }
    }

    static func borrarTodo() {
        lock.lock(); datosEnMemoria.removeAll(); lock.unlock()
        try? FileManager.default.removeItem(at: carpeta)
    }
}
