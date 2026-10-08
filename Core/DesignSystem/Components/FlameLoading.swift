import SwiftUI

/// La carga de un hilo: la flamita de Ghosty (el `AgentAvatar mood=working` de /c) y
/// «Traigo nuestra conversación…». Igual que Android (`ui/FlameLoading.kt`), mismos tiempos.
///
/// Regla de marca de /c: se mece, no se deforma. Con «Reducir movimiento», quieta.
struct FlameLoading: View {
    var text = "Trayendo nuestra conversación…"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            if reduceMotion {
                Flame(t: 0)
            } else {
                TimelineView(.animation) { ctx in
                    Flame(t: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(Color.gInk)
        }
        .frame(maxWidth: .infinity)
    }
}

/// La flama en el instante `t` (segundos). Todo sale de `t`: sin estado, sin derivas.
private struct Flame: View {
    let t: Double
    /// 72 pt de alto para un viewBox de 15 unidades.
    private static let unit: CGFloat = 72 / 15

    var body: some View {
        let u = Self.unit
        // sway 1.7 s ida y vuelta, ease-in-out: skewX ±4°, rotate ∓1.5°.
        let sway = -cos(.pi * t / 1.7)
        // bob 2.3 s: sube 0.9 unidades.
        let bob = -0.9 * (1 - cos(2 * .pi * t / 2.3)) / 2
        ZStack(alignment: .bottom) {
            ZStack {
                Image("flame-body").resizable()
                    .scaleEffect(x: flicker.x, y: flicker.y, anchor: .bottom)
                Image("flame-eyes").resizable()
                    .scaleEffect(x: 1, y: blink, anchor: UnitPoint(x: 0.54, y: 0.52))
                Image("flame-glasses").resizable()
            }
            .frame(width: 13 * u, height: 15 * u)
            .transformEffect(skewX(4 * sway, height: 15 * u, width: 13 * u))
            .rotationEffect(.degrees(-1.5 * sway), anchor: .bottom)
            sparks(u)
        }
        .frame(width: 13 * u, height: 15 * u)
        .offset(y: bob * u)
    }

    /// flicker 0.9 s, sólo el cuerpo: (1,1) → 30% (0.985,1.035) → 60% (1.01,0.99) → 80% (0.99,1.02) → (1,1).
    private var flicker: (x: CGFloat, y: CGFloat) {
        let keys: [(Double, CGFloat, CGFloat)] = [(0, 1, 1), (0.3, 0.985, 1.035), (0.6, 1.01, 0.99), (0.8, 0.99, 1.02), (1, 1, 1)]
        let p = t.truncatingRemainder(dividingBy: 0.9) / 0.9
        for i in 1..<keys.count where p <= keys[i].0 {
            let (p0, x0, y0) = keys[i - 1], (p1, x1, y1) = keys[i]
            let f = CGFloat((p - p0) / (p1 - p0))
            return (x0 + (x1 - x0) * f, y0 + (y1 - y0) * f)
        }
        return (1, 1)
    }

    /// blink 3.4 s: scaleY 1 hasta el 90 %, 0.1 al 93 %, 1 al 96 %.
    private var blink: CGFloat {
        let p = t.truncatingRemainder(dividingBy: 3.4) / 3.4
        switch p {
        case ..<0.90: return 1
        case ..<0.93: return 1 - 0.9 * CGFloat((p - 0.90) / 0.03)
        case ..<0.96: return 0.1 + 0.9 * CGFloat((p - 0.93) / 0.03)
        default: return 1
        }
    }

    /// Tres chispitas desde la punta (8, 0.5): suben 5 unidades, se encogen a 0.3 y se apagan.
    private func sparks(_ u: CGFloat) -> some View {
        let specs: [(period: Double, delay: Double, dx: CGFloat)] = [(1.5, 0, 0.6), (1.8, 0.5, -1.4), (1.3, 1, 1.6)]
        return ZStack(alignment: .topLeading) {
            ForEach(0..<specs.count, id: \.self) { i in
                let s = specs[i]
                let q = CGFloat(max(0, t - s.delay).truncatingRemainder(dividingBy: s.period) / s.period)
                Circle()
                    .fill(Color(red: 0x9A / 255, green: 0x99 / 255, blue: 0xEA / 255))
                    .frame(width: 1.1 * u, height: 1.1 * u)
                    .scaleEffect(1 - 0.7 * q)
                    .opacity(Double(1 - q))
                    .offset(x: (8 + s.dx * q) * u - 0.55 * u, y: (0.5 - 5 * q) * u - 0.55 * u)
            }
        }
        .frame(width: 13 * u, height: 15 * u, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// skewX con origen en la base al centro (como `transform-origin: 50% 100%`).
    private func skewX(_ degrees: Double, height: CGFloat, width: CGFloat) -> CGAffineTransform {
        let k = tan(degrees * .pi / 180)
        return CGAffineTransform(translationX: width / 2, y: height)
            .concatenating(.identity)
            .inverted()
            .concatenating(CGAffineTransform(a: 1, b: 0, c: CGFloat(k), d: 1, tx: 0, ty: 0))
            .concatenating(CGAffineTransform(translationX: width / 2, y: height))
    }
}

#Preview { FlameLoading().padding(.top, 90) }
