import SwiftUI

/// Lo que ocupa el compositor mientras MANTIENES el micrófono, como WhatsApp: micrófono
/// rojo que parpadea, el tiempo, y «‹ Desliza para cancelar» con brillo. Sin onda: la
/// onda sale al bloquear, cuando ya no tienes el dedo tapando la pantalla.
///
/// ⚠️ Antes no había nada de esto: el grabador ya medía el cronómetro y no se pintaba. Un
/// micrófono que al pulsarlo no cambia nada en pantalla no es una nota de voz, es un botón
/// que hace algo invisible — no se sabe si empezó, cuánto llevas, ni cómo salir.
struct BarraDeGrabacion: View {
    let segundos: Double
    /// Cuánto se ha arrastrado hacia la izquierda, 0…1. A 1 se cancela sin soltar.
    let haciaCancelar: Double

    @State private var late = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.gDanger)
                .opacity(late ? 0.2 : 1)
                .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: late)
                .onAppear { late = true }
                .frame(width: 30, height: 30)

            Text(NotaDeVoz.reloj(segundos))
                .gMono(size: 15)
                .monospacedDigit()
                .foregroundStyle(Color.gInk)

            Spacer(minLength: 4)

            // La pista SIGUE AL DEDO: es lo que convierte el gesto en algo que responde en
            // vez de un umbral invisible.
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                Text("Desliza para cancelar").font(.system(size: 14))
            }
            .foregroundStyle(Color.gInk3)
            .brilloQueCorre()
            .opacity(1 - haciaCancelar * 0.9)
            .offset(x: -haciaCancelar * 60)
            .lineLimit(1)
            .fixedSize()
        }
        .frame(minHeight: 44)
        .padding(.trailing, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Grabando, \(NotaDeVoz.reloj(segundos)). Desliza a la izquierda para cancelar.")
    }
}

/// La grabación BLOQUEADA (deslizaste hacia arriba): dos filas, como WhatsApp.
/// Arriba el punto rojo, el tiempo y la onda en vivo; abajo bote · pausa · enviar.
struct BloqueDeGrabacion: View {
    let segundos: Double
    let onda: [Float]
    let pausado: Bool
    var alTirar: () -> Void
    var alPausar: () -> Void
    var alEnviar: () -> Void

    @State private var late = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.gDanger)
                    .frame(width: 9, height: 9)
                    .opacity(pausado ? 0.35 : (late ? 0.25 : 1))
                    .animation(pausado ? .default : .easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: late)
                    .onAppear { late = true }
                Text(NotaDeVoz.reloj(segundos))
                    .gMono(size: 15)
                    .monospacedDigit()
                    .foregroundStyle(Color.gInk)
                OndaEnVivo(onda: onda, apagada: pausado)
                    .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
            }
            .padding(.horizontal, 10)

            HStack {
                Button(action: alTirar) {
                    Image(systemName: "trash")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Color.gInk2)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.gPressIcon)
                .accessibilityLabel("Tirar la nota")
                .accessibilityIdentifier("voz-tirar")

                Spacer()

                Button(action: alPausar) {
                    Image(systemName: pausado ? "mic.fill" : "pause.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.gDanger)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.gPressIcon)
                .accessibilityLabel(pausado ? "Seguir grabando" : "Pausar")
                .accessibilityIdentifier("voz-pausa")

                Spacer()

                Button(action: alEnviar) {
                    Circle().fill(Color.gPrimary)
                        .frame(width: 48, height: 48)
                        .overlay { ChatIcons.enviar.dibujo(.white, size: 18, ancho: 2) }
                }
                .buttonStyle(.gPressPrimary)
                .accessibilityLabel("Mandar nota de voz")
                .accessibilityIdentifier("voz-enviar")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Las últimas amplitudes. Crece desde la derecha, como una grabadora de verdad.
struct OndaEnVivo: View {
    let onda: [Float]
    var apagada = false

    var body: some View {
        GeometryReader { g in
            let cuantas = max(1, Int(g.size.width / 4))
            let ultimas = Array(onda.suffix(cuantas))
            HStack(alignment: .center, spacing: 2) {
                Spacer(minLength: 0)
                ForEach(Array(ultimas.enumerated()), id: \.offset) { _, v in
                    Capsule()
                        .fill(Color.gInk3.opacity(apagada ? 0.35 : 0.8))
                        .frame(width: 2, height: max(3, CGFloat(v) * g.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

/// La píldora del candado que flota encima del micrófono mientras lo mantienes: dice
/// que deslizar arriba bloquea. La flecha rebota; al subir el dedo la píldora se encoge.
struct PildoraDeCandado: View {
    /// 0…1: cuánto falta para bloquear (1 = ya casi).
    let haciaBloquear: Double

    @State private var rebota = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: haciaBloquear > 0.85 ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.gInk2)
                .contentTransition(.symbolEffect(.replace))
            Image(systemName: "chevron.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.gInk3)
                .offset(y: rebota ? -5 : 2)
                .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: rebota)
                .onAppear { rebota = true }
                .opacity(1 - haciaBloquear)
        }
        .padding(.vertical, 12)
        .frame(width: 40, height: 84 - 34 * haciaBloquear)
        .background(Color.gCard, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.gSeparator, lineWidth: 1))
        .ghostySoftShadow()
        .accessibilityHidden(true)
    }
}

/// Cancelar SIN soltar: el micrófono salta, gira y cae en un bote que aparece y tiembla.
/// Dura ~0.9 s y se pinta en el sitio de la barra; al acabar llama `alTerminar`.
struct MicAlBote: View {
    var alTerminar: () -> Void

    private struct Pose {
        var micY: CGFloat = 0
        var micGiro: Double = 0
        var micEscala: CGFloat = 1
        var micOpacidad: Double = 1
        var boteY: CGFloat = 34
        var boteGiro: Double = 0
        var boteOpacidad: Double = 0
    }

    @State private var disparo = 0

    var body: some View {
        HStack {
            ZStack {
                Image(systemName: "trash.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.gInk3)
                    .keyframeAnimator(initialValue: Pose(), trigger: disparo) { v, p in
                        v.offset(y: p.boteY).rotationEffect(.degrees(p.boteGiro), anchor: .bottom)
                            .opacity(p.boteOpacidad)
                    } keyframes: { _ in
                        KeyframeTrack(\.boteY) {
                            CubicKeyframe(34, duration: 0.25)
                            SpringKeyframe(0, duration: 0.2)
                            CubicKeyframe(0, duration: 0.3)
                            CubicKeyframe(40, duration: 0.2)
                        }
                        KeyframeTrack(\.boteOpacidad) {
                            LinearKeyframe(0, duration: 0.2)
                            LinearKeyframe(1, duration: 0.1)
                            LinearKeyframe(1, duration: 0.5)
                            LinearKeyframe(0, duration: 0.15)
                        }
                        KeyframeTrack(\.boteGiro) {
                            LinearKeyframe(0, duration: 0.5)
                            CubicKeyframe(-14, duration: 0.07)
                            CubicKeyframe(12, duration: 0.07)
                            CubicKeyframe(-8, duration: 0.07)
                            CubicKeyframe(0, duration: 0.07)
                        }
                    }
                Image(systemName: "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.gDanger)
                    .keyframeAnimator(initialValue: Pose(), trigger: disparo) { v, p in
                        v.rotationEffect(.degrees(p.micGiro))
                            .scaleEffect(p.micEscala)
                            .offset(y: p.micY)
                            .opacity(p.micOpacidad)
                    } keyframes: { _ in
                        KeyframeTrack(\.micY) {
                            CubicKeyframe(-48, duration: 0.28)
                            CubicKeyframe(4, duration: 0.3)
                        }
                        KeyframeTrack(\.micGiro) {
                            LinearKeyframe(360, duration: 0.5)
                        }
                        KeyframeTrack(\.micEscala) {
                            CubicKeyframe(1.15, duration: 0.28)
                            CubicKeyframe(0.55, duration: 0.3)
                        }
                        KeyframeTrack(\.micOpacidad) {
                            LinearKeyframe(1, duration: 0.5)
                            LinearKeyframe(0, duration: 0.08)
                        }
                    }
            }
            .frame(width: 30, height: 44)
            Spacer()
        }
        .frame(minHeight: 44)
        .onAppear {
            disparo += 1
            Task {
                try? await Task.sleep(for: .milliseconds(950))
                alTerminar()
            }
        }
        .sensoryFeedback(.warning, trigger: disparo)
        .accessibilityLabel("Nota cancelada")
    }
}

/// Un brillo que recorre el texto de izquierda a derecha, como el «Desliza para cancelar»
/// de WhatsApp. Es una máscara: el texto no cambia de color, cambia qué parte se ilumina.
private struct BrilloQueCorre: ViewModifier {
    @State private var fase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Color.white.opacity(0.85), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.45)
                        .offset(x: fase * g.size.width)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { fase = 1.2 }
            }
    }
}

extension View {
    func brilloQueCorre() -> some View { modifier(BrilloQueCorre()) }
}
