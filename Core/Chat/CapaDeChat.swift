import SwiftUI

/// Lo que el chat pinta ENCIMA de toda la app: la hoja «Agregar» y el overlay de voz.
///
/// ⚠️ Vive en la raíz y no en `ConversationView` porque la barra de pestañas es hermana
/// del chat en el `ZStack` de `RootView`: pintado desde el chat, el velo de la hoja y el
/// oscuro de la voz se quedaban a medio camino y la barra flotaba encima (el diseño los
/// pinta sobre todo). El chat decide QUÉ se enseña; la raíz sólo presta el sitio.
///
/// `RootView` lo publica con `.capaDeChat(_:)`; quien no lo tenga en el entorno (una
/// vista previa) simplemente no abre nada.
@MainActor @Observable
final class CapaDeChat {
    /// La hoja: título y contenido. El contenido se CONSERVA al cerrar para que la
    /// animación de salida tenga algo que animar.
    var hojaAbierta = false
    private(set) var tituloHoja: String?
    private(set) var identificadorHoja: String?
    private(set) var contenidoHoja: AnyView = AnyView(EmptyView())

    /// Lo que cubre la pantalla entera (el «Te escucho…»). `nil` = nada.
    private(set) var cubierta: AnyView?

    init() {}

    func abrirHoja<C: View>(_ titulo: String, identificador: String? = nil,
                            @ViewBuilder _ contenido: () -> C) {
        tituloHoja = titulo
        identificadorHoja = identificador
        contenidoHoja = AnyView(contenido())
        hojaAbierta = true
    }

    func cerrarHoja() { hojaAbierta = false }

    func cubrir<C: View>(_ contenido: C) {
        withAnimation(.easeOut(duration: 0.22)) { cubierta = AnyView(contenido) }
    }

    func descubrir() {
        guard cubierta != nil else { return }
        withAnimation(.easeIn(duration: 0.2)) { cubierta = nil }
    }
}

extension View {
    /// Monta la capa del chat (hoja + cubierta) encima de esta vista y la publica en el
    /// entorno. Va en la raíz, debajo del toast.
    func capaDeChat(_ capa: CapaDeChat) -> some View {
        @Bindable var capa = capa
        return self
            .ghostySheet(isPresented: $capa.hojaAbierta, title: capa.tituloHoja,
                         identifier: capa.identificadorHoja) {
                capa.contenidoHoja
            }
            .overlay {
                ZStack {
                    if let cubierta = capa.cubierta {
                        cubierta.transition(.opacity)
                    }
                }
                .ignoresSafeArea()
            }
            .environment(capa)
    }
}
