import SwiftUI
import UIKit

/// `fullScreenCover(item:)` exige `Identifiable` y `UIImage` no lo es. La identidad es el
/// propio objeto: cada entrega crea el suyo, así que no hay dos que deban colapsar.
extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// Una imagen entregada, a pantalla completa.
///
/// ⚠️ No lo hace el visor del sistema, y no por gusto: medido en el teléfono, una entrega
/// `.pdf` abre en QuickLook y una `.png` **no** — se queda en negro. Enseñar una imagen es
/// lo más fácil que hay en iOS y no vale la pena depender de un componente que falla
/// justo en el caso más común. El PDF y lo demás siguen yendo por QuickLook, que ahí sí
/// hace un trabajo que no queremos reescribir.
///
/// De paso sale mejor: se puede acercar, y compartir es el gesto del sistema.
struct VisorDeImagen: View {
    let imagen: UIImage
    let titulo: String
    var archivo: URL?
    @Environment(\.dismiss) private var dismiss

    @State private var escala: CGFloat = 1
    @GestureState private var pellizco: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: imagen)
                .resizable()
                .scaledToFit()
                .scaleEffect(escala * pellizco)
                .gesture(
                    MagnifyGesture()
                        .updating($pellizco) { valor, estado, _ in estado = valor.magnification }
                        .onEnded { valor in
                            // Se guarda al soltar y se acota: sin el tope de abajo la
                            // imagen se puede encoger hasta desaparecer y ya no hay forma
                            // de recuperarla más que cerrando.
                            escala = min(max(escala * valor.magnification, 1), 6)
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        escala = escala > 1 ? 1 : 2.5
                    }
                }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .accessibilityIdentifier("cerrar-visor")
                    Spacer()
                    // ⚠️ Compartir SIEMPRE. Sólo salía cuando la imagen venía de una
                    // entrega, que es la única que tiene archivo en disco; una imagen de
                    // una respuesta se abría a pantalla completa y no se podía sacar de
                    // ahí — ni guardar en el carrete ni mandarla a nadie.
                    if archivo == nil {
                        ShareLink(item: Image(uiImage: imagen),
                                  preview: SharePreview(titulo.isEmpty ? "Imagen" : titulo,
                                                        image: Image(uiImage: imagen))) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(.white.opacity(0.18), in: Circle())
                        }
                    }
                    if let archivo {
                        ShareLink(item: archivo) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(.white.opacity(0.18), in: Circle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                Text(titulo)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.bottom, 20)
            }
        }
        .statusBarHidden()
    }
}
