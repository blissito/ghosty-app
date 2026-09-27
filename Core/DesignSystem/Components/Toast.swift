import SwiftUI

/// El aviso corto del diseño («Listo ✓», «Copiado»): píldora oscura arriba, 1.6 s.
///
/// Uno por app: quien lo quiera enseñar lo pide por el entorno
/// (`@Environment(Toaster.self) var toaster: Toaster?`) y `RootView` lo pinta encima de
/// todo con `.ghostyToast(_:)`.
@MainActor @Observable
final class Toaster {
    private(set) var texto: String?
    /// Cambia con cada aviso: dos iguales seguidos también reinician el reloj.
    private(set) var turno = 0
    private var reloj: Task<Void, Never>?

    init() {}

    func show(_ texto: String, duracion: Double = 1.6) {
        turno += 1
        withAnimation(.easeOut(duration: 0.2)) { self.texto = texto }
        reloj?.cancel()
        reloj = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duracion))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { self?.texto = nil }
        }
    }
}

/// La píldora: `#15141B`, blanco 500 13, padding 10/16, radio 18, a 60 pt del borde.
struct GhostyToastView: View {
    let texto: String
    var body: some View {
        Text(texto)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.vertical, 10).padding(.horizontal, 16)
            .background(Color.gDark, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityIdentifier("toast")
    }
}

extension View {
    /// Pinta el toast de `toaster` encima de esta vista, a 60 pt del borde superior de
    /// la pantalla, y lo publica en el entorno.
    func ghostyToast(_ toaster: Toaster) -> some View {
        overlay(alignment: .top) {
            ZStack {
                if let texto = toaster.texto {
                    GhostyToastView(texto: texto)
                        .id(toaster.turno)
                        .transition(.gIn)
                }
            }
            .padding(.top, 60)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
        }
        .environment(toaster)
    }
}
