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

/// El fondo de una barra superior flotante, como WhatsApp en iOS 26: en reposo no hay
/// nada (se ve el fondo de la app); al desplazar, un difuminado casi blanco que cubre
/// parejo desde la franja de la batería y se desvanece hacia abajo, sin corte duro.
struct FondoDeBarraDifuminado: View {
    /// 0 = en reposo (transparente) · 1 = con contenido pasando por debajo.
    var intensidad: Double = 1

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            // El material solo tiñe de gris sobre blanco: se aclara hacia el color de la app.
            Color.gBg.opacity(0.55)
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                     .init(color: .black, location: 0.7),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .opacity(intensidad)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}
