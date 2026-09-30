import SwiftUI

/// Liquid Glass (iOS 26) en un círculo, con respaldo para iOS 17–25: el material del sistema.
/// `tinte` lo colorea (el + de Chats va en la marca).
struct CristalCircular: ViewModifier {
    var tinte: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(tinte.map { .regular.tint($0).interactive() } ?? .regular.interactive(), in: Circle())
        } else {
            content.background {
                if let tinte { Circle().fill(tinte) } else { Circle().fill(.regularMaterial) }
            }
        }
    }
}

extension View {
    func cristalCircular(tinte: Color? = nil) -> some View { modifier(CristalCircular(tinte: tinte)) }
}

/// El fondo de una barra superior flotante: difumina lo que pasa por debajo y se desvanece
/// hacia abajo, como WhatsApp en iOS 26.
struct FondoDeBarraDifuminado: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                         .init(color: .black, location: 0.6),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }
}
