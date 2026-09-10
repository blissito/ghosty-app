import SwiftUI

/// La imagen de un adjunto, venga de donde venga.
///
/// ⚠️ Un hilo recargado trae los adjuntos **sin bytes**: `ReplayToMessages` los
/// reconstruye con `datos: Data()` y sólo el id de la cuenta. La burbuja hacía
/// `UIImage(data: a.datos)` y, al fallar, no pintaba NADA — la foto que mandaste
/// desaparecía al cambiar de conversación y volver, dejando sólo el texto.
/// Aquí se baja por su id, igual que ya hace la nota de voz con su audio.
enum CacheDeImagenes {
    /// En memoria y por id. Volver a un hilo no vuelve a bajar lo mismo.
    private static var cache: [String: UIImage] = [:]
    private static var enVuelo: [String: Task<UIImage?, Never>] = [:]

    @MainActor
    static func imagen(_ adjunto: Adjunto) async -> UIImage? {
        if let i = UIImage(data: adjunto.datos) { return i }
        guard let id = adjunto.remoto?.id else { return nil }
        if let ya = cache[id] { return ya }
        if let tarea = enVuelo[id] { return await tarea.value }

        let tarea = Task<UIImage?, Never> {
            guard let d = try? await GhostyAPI.bajar(id) else { return nil }
            return UIImage(data: d)
        }
        enVuelo[id] = tarea
        let img = await tarea.value
        enVuelo[id] = nil
        if let img { cache[id] = img }
        return img
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
