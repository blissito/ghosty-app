import SwiftUI

/// La intro de arranque, copiada del arranque de Twitter para iOS (el pájaro que se encoge
/// y luego crece como máscara hasta destapar la app; coreografía documentada en
/// https://reactnative.dev/blog/2018/01/18/implementing-twitters-app-loading-animation-in-react-native).
///
/// Arranca EXACTAMENTE en el fotograma del LaunchScreen (`launch-mark`, `LaunchLockup`:
/// centrado en el área segura) y nada se traslada: sólo escala sobre su propio centro.
///
/// Mientras la cuenta carga (por red, en un teléfono de verdad pueden ser segundos) la marca
/// se queda QUIETA en la pose del LaunchScreen: nunca se funde con otra capa. Antes, a los
/// 3.2 s se fundía con el `LaunchMark` de la raíz (otro fondo, otra flama que se mece): en
/// el teléfono eso se veía como «el ghosty y luego un fundido hacia otro, en mal lugar».
///
/// Guion de la apertura (segundos desde que la app está lista, nunca antes de `Timing.hold`):
/// - 0.00–0.20  toma vuelo: la flama se encoge a 0.85 (ease-in-out); el wordmark se apaga
///              en 0.14 s y los ojos y lentes en 0.08–0.20: queda la silueta sola, como el
///              pájaro blanco.
/// - 0.20–0.62  la silueta es la ventana y crece hasta tapar la pantalla con ease-in (el
///              «golpe» del original). Crece lila, como el pájaro blanco, y entre ×3 y ×10 el
///              lila se apaga y queda la app pura, que baja de 1.1 a 1 con ease-out (`RootView`).
///
/// Reglas: sólo en arranque en frío, se salta con un toque, se quita en cuanto un aviso o
/// una liga piden ir a algún lado, y con «Reducir movimiento» es un fundido. Si la app no
/// está lista en `Timing.maxWait` (10 s), último recurso: fundido.
/// La flama y el wordmark son los assets oficiales SIN tocar: escalan uniformes, nunca se
/// redibujan ni se deforman.
struct LaunchIntro: View {
    /// ¿Ya hay algo que enseñar debajo (lista, login o error)? Mientras no, la intro espera
    /// quieta (idéntica al LaunchScreen); si tarda demasiado, se funde con el `LaunchMark`.
    var appReady: Bool
    /// Cambia cuando un aviso o una liga piden navegar: la intro se va de inmediato.
    var linkRequests: Int
    /// Arranca la apertura. Recibe en cuántos segundos empieza a abrirse la ventana: ahí la
    /// raíz empieza a bajar la app de 1.1 a 1 (`LaunchIntroTiming.appSettle`).
    var onReveal: (_ growStart: Double) -> Void = { _ in }
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Cuándo arrancó la apertura; `nil` = la marca sigue quieta.
    @State private var revealAt: Date?
    /// Con la app aún cargando (o «Reducir movimiento»), la salida es un fundido.
    @State private var fadeAt: Date?
    /// Espejo de `appReady` que sí ve la tarea de la coreografía (la vista es un valor).
    @State private var ready = false

    var body: some View {
        TimelineView(.animation(paused: revealAt == nil && fadeAt == nil)) { ctx in
            let pose = IntroPose(reveal: revealAt.map { ctx.date.timeIntervalSince($0) },
                                 fade: fadeAt.map { ctx.date.timeIntervalSince($0) })
            // UNA sola fuente de geometría: la marca va al centro del área segura (donde la
            // pone iOS) y el fondo con la ventana es su `background`, con el MISMO centro.
            // Antes el fondo ignoraba el área segura y el hueco se alineaba midiendo las dos
            // capas: la medición salía igual y la silueta quedaba (top − bottom)/2 corrida
            // (7 pt en un iPhone 11, 14 pt en un 17 Pro), con rendijas por donde se asomaba la app.
            IntroLockup(pose: pose)
                .background { IntroBackdrop(pose: pose) }
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
            onReveal(Timing.growStart)
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
    /// Lo que tarda la app en asentarse de 1.1 a 1 (ease-out) desde que se abre la ventana.
    static let appSettle = 0.75
}

private enum Timing {
    static let hold = 0.35
    /// Lo más que se espera a la app; después, último recurso, fundido.
    static let maxWait = 10.0
    /// Fin de la toma de vuelo; ahí la silueta se vuelve ventana.
    static let growStart = 0.20
    static let shrinkTo: CGFloat = 0.85
    /// Fin del crecimiento: la ventana ya tapa la pantalla.
    static let growEnd = 0.62
    /// La overlay se quita cuando la app ya se asentó.
    static let reveal = growStart + LaunchIntroTiming.appSettle
    /// Hasta dónde crece la ventana: con el corazón de la flama al centro, tapa las cuatro
    /// esquinas de cualquier iPhone.
    static let growTo: CGFloat = 40
    static let wordmarkOut = 0.14
    static let faceOut = (from: 0.08, to: 0.20)
    /// Entre qué escalas de la flama su lila se apaga y deja ver la app.
    static let fillOut = (from: 3.0, to: 10.0)
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
    /// Ojos y lentes.
    var faceOpacity: Double = 1
    /// El cuerpo lila de la flama (dentro de la ventana, encima de la app).
    var fillOpacity: Double = 1
    var wordmarkScale: CGFloat = 1
    var wordmarkOpacity: Double = 1
    /// La ventana: escala de la silueta recortada; `nil` = todavía no hay hueco.
    var hole: CGFloat?
    var overlayOpacity: Double = 1

    init(reveal r: Double?, fade f: Double?) {
        if let f { overlayOpacity = 1 - clamp(f / Timing.fade) }
        guard let r else { return }
        // El wordmark se va primero: se encoge un poco sobre su centro y se apaga.
        let w = easeOutCubic(clamp(r / Timing.wordmarkOut))
        wordmarkScale = 1 - 0.06 * CGFloat(w)
        wordmarkOpacity = 1 - w
        faceOpacity = 1 - smooth(r, Timing.faceOut.from, Timing.faceOut.to)
        if r < Timing.growStart {
            // 1 → 0.85, ease-in-out: la toma de vuelo.
            let p = easeInOutCubic(r / Timing.growStart)
            flameScale = 1 - (1 - Timing.shrinkTo) * CGFloat(p)
        } else {
            // 0.85 → 40 en escala logarítmica con ease-in cúbico: arranca suave y casi todo el
            // crecimiento llega al final, de golpe, como el pájaro.
            let q = clamp((r - Timing.growStart) / (Timing.growEnd - Timing.growStart))
            let e = q * q
            flameScale = Timing.shrinkTo * CGFloat(exp(log(Double(Timing.growTo / Timing.shrinkTo)) * e))
            hole = flameScale
            // Como el pájaro blanco: crece lila y sólo cuando ya es grande se vuelve app
            // (nunca un recorte chiquito con texto adentro).
            fillOpacity = 1 - smooth(log(Double(flameScale)), log(Timing.fillOut.from), log(Timing.fillOut.to))
        }
    }
}

// MARK: - Fondo con la ventana

/// El fondo del LaunchScreen con un hueco en forma de flama: por ahí se ve la app.
private struct IntroBackdrop: View {
    let pose: IntroPose
    /// Más grande que cualquier pantalla y centrado en la marca: tapa todo sin salirse del
    /// sistema de coordenadas de la marca (un `ignoresSafeArea` lo movería).
    private static let side: CGFloat = 3000

    var body: some View {
        ZStack {
            ZStack {
                Mark.launchBg.frame(width: Self.side, height: Self.side)
                if let s = pose.hole {
                    silhouette(s).blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            // El lila que llena la ventana sale de la MISMA silueta que la recorta (mismo
            // tamaño, ancla y lugar): sin rendijas por donde se asome la app.
            if let s = pose.hole {
                silhouette(s).opacity(pose.fillOpacity)
            }
        }
    }

    private func silhouette(_ s: CGFloat) -> some View {
        Image("flame-body")
            .resizable()
            .frame(width: Mark.flameSize.width, height: Mark.flameSize.height)
            .scaleEffect(s, anchor: Mark.core)
            .offset(y: LaunchLockup.flameOffset)
    }
}

// MARK: - La marca: flama y wordmark, en el lugar exacto del LaunchScreen

private struct IntroLockup: View {
    let pose: IntroPose

    var body: some View {
        ZStack {
            ZStack {
                // Ya con ventana, el cuerpo lo pinta el fondo (`IntroBackdrop`).
                Image("flame-body").resizable()
                    .opacity(pose.hole == nil ? 1 : 0)
                Group {
                    Image("flame-eyes").resizable()
                    Image("flame-glasses").resizable()
                }
                .opacity(pose.faceOpacity)
            }
            .frame(width: Mark.flameSize.width, height: Mark.flameSize.height)
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
private func easeOutCubic(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
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
