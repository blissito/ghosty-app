import SwiftUI

/// La imagen de un adjunto, venga de donde venga.
///
/// ⚠️ Un hilo recargado trae los adjuntos **sin bytes**: `ReplayToMessages` los
/// reconstruye con `datos: Data()` y sólo el id de la cuenta. La burbuja hacía
/// `UIImage(data: a.datos)` y, al fallar, no pintaba NADA — la foto que mandaste
/// desaparecía al cambiar de conversación y volver, dejando sólo el texto.
/// Aquí se baja por su id, igual que ya hace la nota de voz con su audio.
enum CacheDeImagenes {
    /// Dos niveles: memoria para lo de esta sesión, disco para que cerrar la app no
    /// obligue a bajarlo todo otra vez.
    private static var cache: [String: UIImage] = [:]
    private static var enVuelo: [String: Task<UIImage?, Never>] = [:]

    /// Cuánto puede ocupar el caché en disco antes de purgar por lo más viejo.
    private static let topeBytes = 80 * 1024 * 1024

    private static var carpeta: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "imagenes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    static func imagen(_ adjunto: Adjunto) async -> UIImage? {
        if let i = UIImage(data: adjunto.datos) { return i }
        guard let id = adjunto.remoto?.id else { return nil }
        if let ya = cache[id] { return ya }
        if let tarea = enVuelo[id] { return await tarea.value }

        let destino = carpeta.appending(path: id)
        if let d = try? Data(contentsOf: destino), let img = UIImage(data: d) {
            cache[id] = img
            return img
        }

        let tarea = Task<UIImage?, Never> {
            guard let d = try? await GhostyAPI.bajar(id) else { return nil }
            try? d.write(to: destino, options: .atomic)
            return UIImage(data: d)
        }
        enVuelo[id] = tarea
        let img = await tarea.value
        enVuelo[id] = nil
        if let img { cache[id] = img }
        return img
    }

    /// Tira la copia de UNA imagen. Se llama al borrar su archivo de la cuenta: si no,
    /// la miniatura seguiría saliendo de un archivo que ya no existe.
    static func olvidar(_ id: String) {
        cache[id] = nil
        try? FileManager.default.removeItem(at: carpeta.appending(path: id))
    }

    /// Purga lo más viejo si el caché se pasó del tope. Se llama al arrancar: hacerlo en
    /// cada escritura costaría un listado del directorio por cada imagen que baja.
    static func purgar() {
        let claves: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let archivos = try? FileManager.default.contentsOfDirectory(
            at: carpeta, includingPropertiesForKeys: claves) else { return }

        let conDatos = archivos.compactMap { url -> (URL, Date, Int)? in
            guard let v = try? url.resourceValues(forKeys: Set(claves)),
                  let fecha = v.contentModificationDate, let peso = v.fileSize else { return nil }
            return (url, fecha, peso)
        }
        var total = conDatos.reduce(0) { $0 + $1.2 }
        guard total > topeBytes else { return }
        for (url, _, peso) in conDatos.sorted(by: { $0.1 < $1.1 }) {
            guard total > topeBytes else { break }
            try? FileManager.default.removeItem(at: url)
            total -= peso
        }
    }
}

struct ImagenDeAdjunto<Contenido: View>: View {
    let adjunto: Adjunto
    /// El hueco mientras baja, para que la burbuja no cambie de tamaño al llegar.
    var alto: CGFloat = 120
    @ViewBuilder var contenido: (UIImage) -> Contenido

    @State private var imagen: UIImage?
    @State private var fallo = false

    var body: some View {
        Group {
            if let imagen {
                contenido(imagen)
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Color.gFill)
                    .frame(height: alto)
                    .overlay {
                        if fallo {
                            Image(systemName: "photo")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.gInk4)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .task(id: adjunto.id) {
            guard imagen == nil else { return }
            let i = await CacheDeImagenes.imagen(adjunto)
            imagen = i
            fallo = i == nil
        }
    }
}
