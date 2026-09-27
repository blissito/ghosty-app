import SwiftUI

/// «Te escucho…»: el overlay de voz del diseño. Oscuro al 92 %, el orbe con la mascota y
/// sus dos aros morados, y «Toca para terminar». Tocar en cualquier sitio termina y MANDA
/// la nota; «Descartar» (no está en el prototipo) es la salida sin mandar, que el
/// deslizar-para-cancelar da en el modo de mantener pulsado.
///
/// El orbe late con `gdot 2s` como en el prototipo y, además, los aros crecen con tu voz:
/// un micrófono que no reacciona no dice si te está oyendo.
struct OverlayDeVoz: View {
    let grabador: GrabadorDeVoz
    var alTerminar: () -> Void
    var alDescartar: () -> Void

    @Environment(\.accessibilityReduceMotion) private var sinMovimiento

    private var nivel: CGFloat { CGFloat(grabador.onda.last ?? 0) }

    var body: some View {
        ZStack {
            Color(hex: 0x15141B, opacity: 0.92)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                orbe
                VStack(spacing: 28) {
                    Text("Te escucho…")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Toca para terminar")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.gDarkInk2)
                }
                if grabador.grabando {
                    Text(NotaDeVoz.reloj(grabador.segundos))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.gDarkInk2.opacity(0.8))
                        .contentTransition(.numericText())
                }
            }
        }
        .overlay(alignment: .bottom) {
            Button(action: alDescartar) {
                HStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 13, weight: .semibold))
                    Text("Descartar").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color.gDarkInk2)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.white.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.gPressPill)
            .accessibilityIdentifier("voz-descartar")
            .padding(.bottom, 64)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: alTerminar)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Te escucho. Toca para terminar y mandar")
        .accessibilityIdentifier("overlay-voz")
    }

    /// 140 de orbe blanco con la mascota y dos aros: `0 0 0 18px rgba(91,75,214,.35)` y
    /// `0 0 0 40px rgba(91,75,214,.15)` — 176 y 220 de diámetro.
    private var orbe: some View {
        TimelineView(.animation(paused: sinMovimiento)) { contexto in
            let t = contexto.date.timeIntervalSinceReferenceDate
            let f = sinMovimiento ? 0.6 : GhostyDots.pulso(t: t, periodo: 2)
            ZStack {
                Circle().fill(Color.gPrimary.opacity(0.15))
                    .frame(width: 220, height: 220)
                    .scaleEffect(1 + nivel * 0.18)
                Circle().fill(Color.gPrimary.opacity(0.35))
                    .frame(width: 176, height: 176)
                    .scaleEffect(1 + nivel * 0.1)
                AgentAvatar(tone: .lila, size: 140)
            }
            .animation(.easeOut(duration: 0.1), value: nivel)
            // `gdot`: opacidad .25 → 1 y 3 pt hacia arriba en el pico. El piso se sube a .45
            // porque sobre el velo oscuro .25 apagaba el orbe entero.
            .opacity(0.45 + 0.55 * f)
            .offset(y: -3 * f)
        }
        .frame(width: 220, height: 220)
    }
}
