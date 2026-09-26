import SwiftUI

/// Lo que ocupa el compositor mientras grabas.
///
/// ⚠️ Antes no había nada de esto: el grabador ya medía el cronómetro y la onda, y no se
/// pintaba ninguno de los dos. Un micrófono que al pulsarlo no cambia nada en pantalla no
/// es una nota de voz, es un botón que hace algo invisible — no se sabe si empezó, cuánto
/// llevas, ni cómo salir sin mandarla.
struct BarraDeGrabacion: View {
    let segundos: Double
    let onda: [Float]
    /// Cuánto se ha arrastrado hacia la izquierda, 0…1. A 1 se cancela al soltar.
    let haciaCancelar: Double
    let bloqueado: Bool
    var alCancelar: () -> Void

    @State private var late = false

    /// ¿Se pasó del umbral? A partir de aquí, soltar cancela.
    private var cruzado: Bool { haciaCancelar >= 1 }

    var body: some View {
        HStack(spacing: 10) {
            bote

            Text(NotaDeVoz.reloj(segundos))
                .gMono(size: 13)
                .monospacedDigit()
                .foregroundStyle(cruzado ? Color.gDangerInk : Color.gInk)

            onditas
                .frame(maxWidth: .infinity, minHeight: 22)
                // La onda se apaga al acercarte a cancelar: deja de ser lo importante.
                .opacity(1 - haciaCancelar * 0.7)

            if !bloqueado {
                // La pista SIGUE AL DEDO, como en WhatsApp: es lo que convierte el gesto en
                // algo que responde en vez de un umbral invisible.
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                    Text("desliza").font(.system(size: 12))
                }
                .foregroundStyle(Color.gInk3)
                .opacity(1 - haciaCancelar)
                .offset(x: -haciaCancelar * 26)
            }
        }
        .frame(minHeight: 30)
        .sensoryFeedback(.warning, trigger: cruzado)
    }

    /// El bote. Aparece al arrastrar, crece contigo y **se sacude al llegar**.
    ///
    /// ⚠️ Es lo que faltaba: sin un destino visible, deslizar a la izquierda es un umbral
    /// invisible — no sabes cuánto falta ni qué va a pasar. Con el bote, el gesto se
    /// explica solo.
    @ViewBuilder
    private var bote: some View {
        if bloqueado {
            Button(action: alCancelar) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.gDanger)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        } else if haciaCancelar > 0.02 {
            Image(systemName: cruzado ? "trash.fill" : "trash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.gDanger)
                .frame(width: 30, height: 30)
                // Crece contigo, y al cruzar el umbral pega un brinco: `.bounce` es el
                // efecto nativo de SF Symbols, así que el "botecito" se anima solo.
                .scaleEffect(0.7 + haciaCancelar * 0.5 + (cruzado ? 0.15 : 0))
                .symbolEffect(.bounce, value: cruzado)
                .transition(.scale.combined(with: .opacity))
        } else {
            Circle()
                .fill(Color.gDanger)
                .frame(width: 9, height: 9)
                .opacity(late ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: late)
                .onAppear { late = true }
                .frame(width: 30, height: 30)
                .transition(.scale.combined(with: .opacity))
        }
    }

    /// Las últimas amplitudes. Crece desde la derecha, como una grabadora de verdad.
    private var onditas: some View {
        GeometryReader { g in
            let cuantas = max(1, Int(g.size.width / 4))
            let ultimas = Array(onda.suffix(cuantas))
            HStack(alignment: .center, spacing: 2) {
                Spacer(minLength: 0)
                ForEach(Array(ultimas.enumerated()), id: \.offset) { _, v in
                    Capsule()
                        .fill(Color.gPrimary.opacity(0.75))
                        .frame(width: 2, height: max(3, CGFloat(v) * g.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}
