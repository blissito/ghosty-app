import SwiftUI

/// La intro de arranque, copiada del arranque de Twitter para iOS (el pájaro que se encoge
/// y luego crece como máscara hasta destapar la app; coreografía documentada en
/// https://reactnative.dev/blog/2018/01/18/implementing-twitters-app-loading-animation-in-react-native).
///
/// Arranca EXACTAMENTE en el fotograma del LaunchScreen (`launch-mark`, `LaunchLockup`:
/// centrado en el área segura) y nada se traslada: sólo escala sobre su propio centro.
///
/// Guion (segundos desde que la app está lista, nunca antes de `Timing.hold`):
/// - 0.00–0.30  la flama se encoge a 0.8 (toma vuelo, ease-in-out) y el wordmark se apaga
///              encogiéndose sobre su centro: la flama se queda sola, como el pájaro.
/// - 0.30–1.00  la flama crece como ventana hasta tapar la pantalla (ease-in). Su cara se
///              apaga en 0.30–0.45 y por la silueta se ve la app, que a la vez baja de
///              1.1 a 1 (`RootView`): el mismo «aterrizaje» del original.
///
/// Reglas: sólo en arranque en frío, se salta con un toque, se quita en cuanto un aviso o
/// una liga piden ir a algún lado, y con «Reducir movimiento» es un fundido.
/// La flama y el wordmark son los assets oficiales SIN tocar: escalan uniformes, nunca se
/// redibujan ni se deforman.
struct LaunchIntro: View {
    /// ¿Ya hay algo que enseñar debajo (lista, login o error)? Mientras no, la intro espera
    /// quieta (idéntica al LaunchScreen); si tarda demasiado, se funde con el `LaunchMark`.
    var appReady: Bool
    /// Cambia cuando un aviso o una liga piden navegar: la intro se va de inmediato.
    var linkRequests: Int
    /// Arranca la apertura (la raíz baja la app de 1.1 a 1 con `Timing.reveal` de duración).
    var onReveal: () -> Void = {}
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Cuándo arrancó la apertura; `nil` = la marca sigue quieta.
    @State private var revealAt: Date?
    /// Con la app aún cargando (o «Reducir movimiento»), la salida es un fundido.
    @State private var fadeAt: Date?
    /// Espejo de `appReady` que sí ve la tarea de la coreografía (la vista es un valor).
    @State private var ready = false
    @State private var lockupMidY: CGFloat = 0
    @State private var backdropMidY: CGFloat = 0

    var body: some View {
        TimelineView(.animation(paused: revealAt == nil && fadeAt == nil)) { ctx in
            let pose = IntroPose(reveal: revealAt.map { ctx.date.timeIntervalSince($0) },
                                 fade: fadeAt.map { ctx.date.timeIntervalSince($0) })
            ZStack {
                // El fondo cubre la pantalla completa; la marca va al centro del área segura,
                // que es donde la pone iOS. El hueco se alinea con la marca MIDIENDO las dos
                // capas (no calculando con los bordes seguros: según dónde cuelgue la vista,
                // `safeAreaInsets` llega en 0 y la marca brincaba 14 pt).
                IntroBackdrop(pose: pose, safeCenterOffset: lockupMidY - backdropMidY)
                    .ignoresSafeArea()
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { backdropMidY = $0 }
                IntroLockup(pose: pose)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { lockupMidY = $0 }
            }
            .opacity(pose.overlayOpacity)
        }
        .contentShape(Rectangle())
        .onTapGesture { leave() }
        .allowsHitTesting(revealAt == nil && fadeAt == nil)
        .accessibilityHidden(true)
        .onChange(of: appReady, initial: true) { _, nuevo in ready = nuevo }
        .onChange(of: linkRequests) { _, _ in leave() }
        .task { await choreograph() }
    }

    private func choreograph() async {
        let start = Date()
        // Quieta un instante (el LaunchScreen «respira» antes de abrir, como en el original)
        // y hasta que haya app que destapar.
        try? await Task.sleep(for: .seconds(Timing.hold))
        while !ready, Date().timeIntervalSince(start) < Timing.maxWait {
            try? await Task.sleep(for: .milliseconds(30))
        }
        leave()
    }

    private func leave() {
        guard revealAt == nil, fadeAt == nil else { return }
        if ready && !reduceMotion {
            revealAt = Date()
            onReveal()
            Task {
                try? await Task.sleep(for: .seconds(Timing.reveal))
                onFinish()
            }
        } else {
            // Sin app debajo no hay qué destapar: se funde con el `LaunchMark` (la misma marca).
            fadeAt = Date()
            Task {
                try? await Task.sleep(for: .seconds(Timing.fade))
                onFinish()
            }
        }
    }
}

// MARK: - Tiempos

enum LaunchIntroTiming {
    /// La apertura completa: lo que dura también el 1.1 → 1 de la app en `RootView`.
    static let reveal = 1.0
}

private enum Timing {
    static let hold = 0.35
    /// Lo más que se espera a la app antes de fundirse con el LaunchMark.
    static let maxWait = 3.2
    static let reveal = LaunchIntroTiming.reveal
    /// Fin de la toma de vuelo (el 30 % del original).
    static let shrinkEnd = 0.30
    static let shrinkTo: CGFloat = 0.8
    /// Hasta dónde crece la ventana: con el corazón de la flama al centro, tapa las cuatro
    /// esquinas de cualquier iPhone.
    static let growTo: CGFloat = 40
    static let wordmarkOut = 0.24
    static let faceOut = (from: 0.30, to: 0.45)
    static let fade = 0.32
}

// MARK: - Geometría (la del LaunchScreen, `LaunchLockup`)

private enum Mark {
    static let unit = LaunchLockup.flameHeight / 15
    static let flameSize = CGSize(width: 13 * unit, height: 15 * unit)
    /// El «corazón» de la flama (la parte redonda), en unidades del viewBox: de ahí se
    /// encoge y crece, como el pájaro desde su cuerpo.
    static let core = UnitPoint(x: 6.9 / 13, y: 8.4 / 15)
    static let launchBg = Color("bg")
}

// MARK: - La pose en el instante t (todo sale de t: sin estado, sin derivas)

private struct IntroPose {
    var flameScale: CGFloat = 1
    var faceOpacity: Double = 1
    var wordmarkScale: CGFloat = 1
    var wordmarkOpacity: Double = 1
    /// La ventana: escala de la silueta recortada; `nil` = todavía no hay hueco.
    var hole: CGFloat?
    var overlayOpacity: Double = 1

    init(reveal r: Double?, fade f: Double?) {
        if let f { overlayOpacity = 1 - clamp(f / Timing.fade) }
        guard let r else { return }
        // El wordmark se va primero: se encoge sobre su centro y se apaga.
        let w = easeInOutCubic(clamp(r / Timing.wordmarkOut))
        wordmarkScale = 1 - 0.1 * CGFloat(w)
        wordmarkOpacity = 1 - w
        if r < Timing.shrinkEnd {
            // 1 → 0.8, ease-in-out (primer tramo del original).
            let p = easeInOutCubic(r / Timing.shrinkEnd)
            flameScale = 1 - (1 - Timing.shrinkTo) * CGFloat(p)
        } else {
            // 0.8 → 40, ease-in: interpolación exponencial (se siente a velocidad pareja)
            // que arranca lenta y termina de golpe, como el pájaro.
            let q = clamp((r - Timing.shrinkEnd) / (Timing.reveal - Timing.shrinkEnd))
            let e = pow(q, 1.6)
            flameScale = Timing.shrinkTo * CGFloat(exp(log(Double(Timing.growTo / Timing.shrinkTo)) * e))
            hole = flameScale
            faceOpacity = 1 - smooth(r, Timing.faceOut.from, Timing.faceOut.to)
        }
    }
}

// MARK: - Fondo con la ventana

/// El fondo del LaunchScreen con un hueco en forma de flama: por ahí se ve la app.
private struct IntroBackdrop: View {
    let pose: IntroPose
    let safeCenterOffset: CGFloat

    var body: some View {
        ZStack {
            Mark.launchBg
            if let s = pose.hole {
                Image("flame-body")
                    .resizable()
                    .frame(width: Mark.flameSize.width, height: Mark.flameSize.height)
                    .scaleEffect(s, anchor: Mark.core)
                    .offset(y: safeCenterOffset + LaunchLockup.flameOffset)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
    }
}

// MARK: - La marca: flama y wordmark, en el lugar exacto del LaunchScreen

private struct IntroLockup: View {
    let pose: IntroPose

    var body: some View {
        ZStack {
            ZStack {
                Image("flame-body").resizable()
                Image("flame-eyes").resizable()
                Image("flame-glasses").resizable()
            }
            .frame(width: Mark.flameSize.width, height: Mark.flameSize.height)
            .opacity(pose.faceOpacity)
            .scaleEffect(pose.flameScale, anchor: Mark.core)
            .offset(y: LaunchLockup.flameOffset)

            Image("ghosty-wordmark")
                .resizable()
                .frame(width: LaunchLockup.wordmarkSize.width, height: LaunchLockup.wordmarkSize.height)
                .scaleEffect(pose.wordmarkScale)
                .opacity(pose.wordmarkOpacity)
                .offset(y: LaunchLockup.wordmarkOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Curvas

private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
private func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double {
    let p = clamp((x - a) / (b - a))
    return p * p * (3 - 2 * p)
}
private func easeInOutCubic(_ p: Double) -> Double {
    p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
}

// MARK: - Cuándo se toca

/// El único interruptor de la intro. Sólo en arranque en frío (una vez por proceso: volver
/// del fondo no recrea la raíz, y aun si lo hiciera, ya se tocó).
enum LaunchIntroGate {
    /// Apagar aquí quita la intro entera; la app arranca como antes (LaunchMark).
    static let enabled = true

    @MainActor private static var played = false

    /// Se pregunta UNA vez, al crear la raíz.
    @MainActor static func claim() -> Bool {
        guard enabled, !played else { return false }
        played = true
        // Ganchos: `GHOSTY_INTRO=1` la fuerza y `=0` la quita. En modo demo (lo que usan
        // las pruebas de UI) no sale salvo que se pida: taparía los primeros toques.
        switch Gancho.valor("GHOSTY_INTRO") {
        case "1": return true
        case "0": return false
        default: return Gancho.valor("GHOSTY_DEMO") == nil
        }
    }
}
