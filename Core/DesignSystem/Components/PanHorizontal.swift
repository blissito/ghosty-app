import SwiftUI
import UIKit

/// Un arrastre SÓLO horizontal que no le roba el scroll a la lista.
///
/// ⚠️ En iOS 18 un `DragGesture` dentro de las filas de un `ScrollView` bloquea el scroll
/// aunque vaya como `simultaneousGesture`: la lista de Chats dejaba de desplazarse y había
/// que reintentar (medido con una prueba de UI, 2026-09-29). Aquí va un
/// `UIPanGestureRecognizer` que sólo EMPIEZA si el dedo va más de lado que de arriba abajo;
/// si no, ni se entera y el scroll sigue siendo del sistema.
@available(iOS 18.0, *)
private struct PanHorizontalUIKit: UIGestureRecognizerRepresentable {
    var alCambiar: (CGFloat) -> Void
    var alTerminar: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinador { Coordinador() }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let x = g.translation(in: g.view).x
        switch g.state {
        case .changed: alCambiar(x)
        case .ended, .cancelled, .failed: alTerminar(x)
        default: break
        }
    }

    final class Coordinador: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer else { return false }
            let v = p.velocity(in: p.view)
            return abs(v.x) > abs(v.y) * 1.3
        }
    }
}

extension View {
    /// Arrastre horizontal que respeta el scroll vertical. En iOS 17 cae al `DragGesture`
    /// con la misma regla (|dx| > |dy|).
    @ViewBuilder
    func panHorizontal(alCambiar: @escaping (CGFloat) -> Void,
                       alTerminar: @escaping (CGFloat) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.gesture(PanHorizontalUIKit(alCambiar: alCambiar, alTerminar: alTerminar))
        } else {
            self.simultaneousGesture(
                DragGesture(minimumDistance: 14, coordinateSpace: .local)
                    .onChanged { v in if abs(v.translation.width) > abs(v.translation.height) { alCambiar(v.translation.width) } }
                    .onEnded { v in if abs(v.translation.width) > abs(v.translation.height) { alTerminar(v.translation.width) } }
            )
        }
    }
}
