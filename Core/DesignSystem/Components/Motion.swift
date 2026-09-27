import SwiftUI

// Las animaciones del diseño (`@keyframes gdot/gspin/gin` y los `style-active` del
// prototipo), en un solo sitio para que todas las pantallas se muevan igual.

// MARK: - gdot: tres puntos que laten

/// «Pensando»: tres puntos de 7 pt que suben 3 pt y se encienden por turnos.
/// `gdot 1.2s`, desfase de 0.15 s entre puntos; el pico es al 40 % del ciclo.
struct GhostyDots: View {
    var color: Color = .gPrimary
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var sinMovimiento

    var body: some View {
        TimelineView(.animation(paused: sinMovimiento)) { contexto in
            let t = contexto.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    let f = Self.pulso(t: t - Double(i) * 0.15)
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                        .opacity(sinMovimiento ? 0.6 : 0.25 + 0.75 * f)
                        .offset(y: sinMovimiento ? 0 : -3 * f)
                }
            }
            .padding(.vertical, 10)
        }
        .accessibilityLabel("Pensando")
    }

    /// 0 → 1 → 0 en los primeros 80 % del ciclo, quieto el resto (como el keyframe).
    static func pulso(t: Double, periodo: Double = 1.2) -> Double {
        let p = (t.truncatingRemainder(dividingBy: periodo) + periodo)
            .truncatingRemainder(dividingBy: periodo) / periodo
        guard p < 0.8 else { return 0 }
        let x = p < 0.4 ? p / 0.4 : (0.8 - p) / 0.4
        // ease: suave en los extremos
        return x * x * (3 - 2 * x)
    }
}

// MARK: - gspin: el giro de «paso activo»

/// Aro de 14 pt con el tramo de arriba morado, una vuelta cada 0.8 s.
struct GhostySpinner: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2
    var color: Color = .gPrimary
    var pista: Color = .gFillStrong
    @Environment(\.accessibilityReduceMotion) private var sinMovimiento

    var body: some View {
        TimelineView(.animation(paused: sinMovimiento)) { contexto in
            let t = contexto.date.timeIntervalSinceReferenceDate
            let grados = (t.truncatingRemainder(dividingBy: 0.8) / 0.8) * 360
            ZStack {
                Circle().stroke(pista, lineWidth: lineWidth)
                // El `border-top-color` del CSS: un cuarto de aro.
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(grados - 135))
            }
            .padding(lineWidth / 2)
            .frame(width: size, height: size)
        }
        .padding(1)
        .accessibilityLabel("Trabajando")
    }
}

// MARK: - gin: aparecer desde 8 pt

/// `gin .3s ease both`: entra con fade subiendo 8 pt. Una sola vez por vista.
struct GhostyAppear: ViewModifier {
    var duration: Double = 0.3
    var delay: Double = 0
    var distance: CGFloat = 8
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var sinMovimiento

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || sinMovimiento ? 0 : distance)
            .onAppear {
                guard !visible else { return }
                withAnimation(.easeOut(duration: duration).delay(delay)) { visible = true }
            }
    }
}

extension View {
    /// Aparece como `gin`: fade + 8 pt hacia arriba en 0.3 s.
    func gIn(duration: Double = 0.3, delay: Double = 0, distance: CGFloat = 8) -> some View {
        modifier(GhostyAppear(duration: duration, delay: delay, distance: distance))
    }
}

/// La transición equivalente a `gin` para lo que entra y SALE con un `if`.
extension AnyTransition {
    static var gIn: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                    removal: .opacity.combined(with: .offset(y: 4)))
    }
}

// MARK: - Escala al presionar

/// Los `style-active` del prototipo: la escala exacta depende del tamaño del control.
/// - 0.90 (+ opacidad .6): botones de icono (historial, nuevo chat, ＋)
/// - 0.92: botones redondos primarios (enviar, micrófono)
/// - 0.95: pestañas y avatar de la barra
/// - 0.97: píldoras (agente de la cabecera, chips)
/// - 0.98: filas y tarjetas (sugerencias, filas de hoja)
struct GhostyPressStyle: ButtonStyle {
    var scale: CGFloat
    var pressedOpacity: Double = 1
    /// Fondo al presionar (las filas pasan a `#FAFAFD`). `nil` = sin cambio.
    var pressedBackground: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed, let pressedBackground { pressedBackground }
            }
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GhostyPressStyle {
    /// Escala libre.
    static func gPress(_ scale: CGFloat, opacity: Double = 1) -> GhostyPressStyle {
        GhostyPressStyle(scale: scale, pressedOpacity: opacity)
    }
    /// 0.90 y opacidad .6 — botones de icono.
    static var gPressIcon: GhostyPressStyle { GhostyPressStyle(scale: 0.9, pressedOpacity: 0.6) }
    /// 0.92 — botón redondo primario.
    static var gPressPrimary: GhostyPressStyle { GhostyPressStyle(scale: 0.92) }
    /// 0.95 — pestañas.
    static var gPressTab: GhostyPressStyle { GhostyPressStyle(scale: 0.95) }
    /// 0.97 — píldoras.
    static var gPressPill: GhostyPressStyle { GhostyPressStyle(scale: 0.97) }
    /// 0.98 — filas y tarjetas.
    static var gPressRow: GhostyPressStyle { GhostyPressStyle(scale: 0.98) }
}
