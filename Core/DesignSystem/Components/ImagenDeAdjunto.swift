import SwiftUI

/// La imagen de un adjunto, venga de donde venga.
///
/// ⚠️ Un hilo recargado trae los adjuntos **sin bytes**: `ReplayToMessages` los
/// reconstruye con `datos: Data()` y sólo el id de la cuenta. La burbuja hacía
/// `UIImage(data: a.datos)` y, al fallar, no pintaba NADA — la foto que mandaste
/// desaparecía al cambiar de conversación y volver, dejando sólo el texto.
/// Aquí se baja por su id, igual que ya hace la nota de voz con su audio.
enum CacheDeImagenes {
    /// Dos niveles: memoria (`MiniaturasEnMemoria`, ya decodificada) para pintar en el
    /// mismo fotograma, y disco (`ArchivosEnDisco`, por id) para que cerrar la app no
    /// obligue a bajarlo todo otra vez.
    @MainActor private static var enVuelo: [String: Task<UIImage?, Never>] = [:]

    /// Lo que ya está en memoria, sin esperar: para el primer pintado.
    @MainActor
    static func enMemoria(_ adjunto: Adjunto) -> UIImage? {
        guard adjunto.datos.isEmpty, let id = adjunto.remoto?.id else { return nil }
        return MiniaturasEnMemoria.imagen(id)
    }

    @MainActor
    static func imagen(_ adjunto: Adjunto) async -> UIImage? {
        if !adjunto.datos.isEmpty, let i = DecodificadorDeImagen.imagen(adjunto.datos) { return i }
        guard let id = adjunto.remoto?.id else { return nil }
        if let ya = MiniaturasEnMemoria.imagen(id) { return ya }
        if let tarea = enVuelo[id] { return await tarea.value }

        // `bajar` mira primero el disco; sólo va a la red si no está.
        let tarea = Task<UIImage?, Never> {
            guard let d = try? await GhostyAPI.bajar(id) else { return nil }
            return await Task.detached(priority: .userInitiated) { DecodificadorDeImagen.imagenLista(d) }.value
        }
        enVuelo[id] = tarea
        let img = await tarea.value
        enVuelo[id] = nil
        if let img { MiniaturasEnMemoria.guardar(img, clave: id) }
        return img
    }

    /// Tira la copia de UNA imagen. Se llama al borrar su archivo de la cuenta: si no,
    /// la miniatura seguiría saliendo de un archivo que ya no existe.
    static func olvidar(_ id: String) {
        MiniaturasEnMemoria.olvidar(id)
        ArchivosEnDisco.olvidar(id)
    }

    /// El caché viejo de imágenes vivía en Application Support con su propio tope. Ahora
    /// todo va a `Caches/archivos`: se tira la carpeta vieja y se purga la nueva.
    static func purgar() {
        let vieja = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "imagenes")
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: vieja)
            ArchivosEnDisco.purgar()
        }
    }

    static func borrarTodo() {
        let vieja = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "imagenes")
        try? FileManager.default.removeItem(at: vieja)
    }
}

struct ImagenDeAdjunto<Contenido: View>: View {
    let adjunto: Adjunto
    /// El hueco mientras baja, para que la burbuja no cambie de tamaño al llegar.
    var alto: CGFloat = 120
    @ViewBuilder var contenido: (UIImage) -> Contenido

    @Environment(Visor.self) private var visor: Visor?
    @State private var imagen: UIImage?
    @State private var fallo = false

    var body: some View {
        Group {
            // La de memoria se pinta YA: sin un fotograma de hueco al volver al hilo.
            if let imagen = imagen ?? CacheDeImagenes.enMemoria(adjunto) {
                contenido(imagen)
                    // La foto que mandaste también se abre: se ve a 238 puntos y a veces
                    // lo que quieres es mirarla.
                    .contentShape(Rectangle())
                    .onTapGesture { visor?.abrir(imagen, titulo: adjunto.nombre) }
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
