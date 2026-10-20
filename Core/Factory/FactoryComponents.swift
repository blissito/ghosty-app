import SwiftUI

// Las piezas de la fábrica que se repiten entre la lista y el detalle: el tono de cada etapa,
// el punto que late, la pastilla de etapa, la barra de pasos y la fila de un pedido.
// Mismo lenguaje que la tarjeta de Teams (`RunCard.tsx`): «te toca» en ÁMBAR (es una petición,
// no un problema), trabajando en el morado de la marca, terminado en verde, rojo sólo si falló.

extension Color {
    /// Ámbar de «te toca». No está en la paleta general: sólo lo usa la fábrica.
    static let gAmber     = Color(light: 0xD98E04, dark: 0xF5B83D)
    static let gAmberInk  = Color(light: 0xA86A00, dark: 0xF7C766)
    static let gAmberTint = Color(light: 0xFDF3DC, dark: 0x3A2E14)
}

struct FactoryTone {
    let ink: Color
    let accent: Color
    let tint: Color

    static func of(_ s: FactoryStage) -> FactoryTone {
        if s.needsYou { return .init(ink: .gAmberInk, accent: .gAmber, tint: .gAmberTint) }
        if s.working { return .init(ink: .gPrimaryPressed, accent: .gPrimary, tint: .gPrimaryTint) }
        if s == .done { return .init(ink: .gGreenInk, accent: .gGreen, tint: .gGreenTint) }
        return .init(ink: .gInk3, accent: .gInk4, tint: .gFill)
    }
}

/// Punto de 7 pt; si `active`, late con un halo (alguien está trabajando o te toca).
struct PulsingDot: View {
    var color: Color
    var active: Bool
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !active || reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let p = active && !reduceMotion ? (t.truncatingRemainder(dividingBy: 1.4)) / 1.4 : 0
            ZStack {
                if active {
                    Circle().fill(color.opacity(0.35 * (1 - p)))
                        .frame(width: size * (1 + 1.6 * p), height: size * (1 + 1.6 * p))
                }
                Circle().fill(color).frame(width: size, height: size)
            }
            .frame(width: size * 2.6, height: size * 2.6)
        }
        .accessibilityHidden(true)
    }
}

/// La pastilla de etapa: punto + nombre, en el tono de la etapa.
struct StageChip: View {
    let stage: FactoryStage

    var body: some View {
        let tone = FactoryTone.of(stage)
        HStack(spacing: 2) {
            PulsingDot(color: tone.accent, active: stage.working || stage.needsYou, size: 6)
                .padding(.leading, -2)
            Text(stage.label).gChip().foregroundStyle(tone.ink)
        }
        .padding(.trailing, 10).padding(.leading, 4).padding(.vertical, 3)
        .background(tone.tint, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("etapa-\(stage.rawValue)")
    }
}

/// Plan → Aprobación → Build → Check → PR. Lo hecho en verde, el paso actual en el tono de la
/// etapa (latiendo si un agente lo tiene), lo que falta en gris. Dependabot entra directo a
/// Build: Plan y Aprobación no ocurrieron y se pintan apagados, no como hechos.
struct FactoryStepBar: View {
    let stage: FactoryStage
    var dependabot = false

    private static let labels = ["Plan", "Aprobación", "Build", "Check", "PR"]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tone = FactoryTone.of(stage)
        let current = stage.step
        HStack(alignment: .top, spacing: 5) {
            ForEach(Array(Self.labels.enumerated()), id: \.offset) { i, label in
                let skipped = dependabot && i < 2
                let done = !skipped && (stage == .done || (current >= 0 && i < current))
                let now = !skipped && stage != .done && i == current
                VStack(alignment: .leading, spacing: 6) {
                    TimelineView(.animation(paused: !(now && stage.working) || reduceMotion)) { ctx in
                        let pulse = now && stage.working && !reduceMotion
                            ? 0.55 + 0.45 * GhostyDots.pulso(t: ctx.date.timeIntervalSinceReferenceDate, periodo: 1.4) : 1
                        Capsule()
                            .fill(done ? Color.gGreen : now ? tone.accent.opacity(pulse) : Color.gFillStrong)
                            .frame(height: 6)
                    }
                    Text(label)
                        .font(.system(size: 11, weight: now ? .bold : .medium))
                        .foregroundStyle(now ? tone.ink : done ? Color.gInk2 : Color.gInk4)
                        .strikethrough(skipped, color: .gInk4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Etapa: \(stage.label)")
    }
}

/// Anillo de avance con «2/5», ✓ o ✕ al centro (el de la tarjeta de Teams).
struct FactoryProgressRing: View {
    let stage: FactoryStage
    var size: CGFloat = 44

    var body: some View {
        let tone = FactoryTone.of(stage)
        let step = stage.step
        let progress = stage == .done ? 1 : step < 0 ? 0 : (Double(step) + (stage.closed ? 1 : 0.5)) / 5
        ZStack {
            Circle().stroke(Color.gFillStrong, lineWidth: 4)
            Circle().trim(from: 0, to: progress)
                .stroke(tone.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Group {
                if stage == .done { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)) }
                else if stage == .cancelled { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)) }
                else { Text("\(max(1, min(5, step + 1)))/5").font(.system(size: 12, weight: .bold).monospacedDigit()) }
            }
            .foregroundStyle(tone.ink)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)
    }
}

enum FactoryFormat {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.unitsStyle = .short
        return f
    }()

    /// «hace 4 min», «ahora».
    static func ago(_ d: Date?) -> String? {
        guard let d else { return nil }
        if Date().timeIntervalSince(d) < 60 { return "ahora" }
        return relative.localizedString(for: d, relativeTo: Date())
    }

    /// «83 min» → «1 h 23 min».
    static func minutes(_ m: Double?) -> String? {
        guard let m, m > 0 else { return nil }
        let total = Int(m.rounded())
        if total < 60 { return "\(max(1, total)) min" }
        return total % 60 == 0 ? "\(total / 60) h" : "\(total / 60) h \(total % 60) min"
    }

    static func usd(_ v: Double?) -> String? {
        guard let v, v > 0 else { return nil }
        return String(format: "$%.2f", v)
    }

    /// Lo que lleva un paso: «41 s», «6 min».
    static func secs(_ s: Int) -> String { s < 60 ? "\(s) s" : "\(s / 60) min" }

    /// Quién trabaja, como en Teams.
    static func working(_ role: String?) -> String {
        switch role {
        case "plan":  "@plan está escribiendo el plan…"
        case "build": "@build está construyendo…"
        case "check": "@check está revisando el PR…"
        default:      "\(role.map { "@\($0)" } ?? "Un agente") está trabajando…"
        }
    }

    /// Cómo se lee cada renglón de la bitácora (`RunPanel.tsx` de Teams).
    static func event(_ type: String) -> String {
        [
            "plan_submitted": "entregó el plan",
            "approve": "firmó",
            "changes": "pidió cambios",
            "build_done": "abrió el PR",
            "check_pass": "aprobó la revisión",
            "check_fail": "regresó hallazgos",
            "check_blocked": "escaló: falta algo que Build no puede hacer",
            "close": "cerró",
            "merged": "merge hecho",
            "merge_queued": "dejó el merge en cola",
            "deployed": "desplegó a producción",
            "git_push": "subió commits",
            "adopted": "abrió el PR",
            "conflict": "PR con conflictos: lo pone al día",
            "rework": "pidieron más sobre el PR: vuelve a construir",
            "cancel": "canceló",
            "stale": "sin avanzar 30 min",
            "auto_resumed": "lo retomó la plataforma",
            "ci_red": "CI en rojo: se lo regresó a Build",
            "ci_red_help": "CI sigue en rojo: necesita una persona",
            "ci_requested": "pidió correr el CI",
            "waiting_person": "preguntó algo: espera tu respuesta",
            "head_moved": "el PR cambió durante la revisión",
            "stopped": "detuvo el turno",
            "resumed": "pidió retomar",
            "stuck": "se atoró",
            "stuck_notified": "Te avisé que se atoró",
            "stalled": "se atoró",
            "advice": "le pidió consejo a @arqui",
            "note": "dejó una nota para @build",
            "role_msg": "dejó un mensaje",
            "waiting": "espera tu respuesta",
            "box_ready": "La caja del pedido quedó lista",
            "box_waiting": "En espera de una caja libre",
            "preview_on": "Preview encendida",
            "preview_off": "Preview apagada",
            "preview_blocking": "La preview frena el merge",
            "smoke_fail": "La prueba de humo falló",
            "deploy_failed": "Falló el deploy",
            "git_push_denied": "GitHub rechazó el push",
            "behind_main": "La rama quedó atrás de main: la pone al día",
            "critique_timeout": "El crítico del plan no contestó a tiempo",
            "postmortem_requested": "pidió el post mortem",
            "reopened": "reabrió el pedido",
        ][type] ?? "actualizó el pedido"
    }

    static func actor(_ a: String?) -> String? {
        guard let a, !a.isEmpty else { return nil }
        return ["plan", "build", "check", "dependabot"].contains(a) ? "@\(a)" : "Tú"
    }

    /// Lo que hiciste TÚ, conjugado contigo: «Firmaste tú», no «Tú firmó» (bliss, 19-oct).
    static func ownEvent(_ type: String) -> String? {
        [
            "approve": "Firmaste",
            "changes": "Pediste cambios",
            "close": "Cerraste",
            "cancel": "Cancelaste",
            "merge_queued": "Dejaste el merge en cola",
            "deployed": "Desplegaste a producción",
            "git_push": "Subiste commits",
            "ci_requested": "Pediste correr el CI",
            "stopped": "Detuviste el turno",
            "resumed": "Pediste retomar",
        ][type]
    }

    /// El renglón de un evento, con lo que trae: el atasco dice de quién y en qué se atoró.
    static func logLine(_ e: FactoryRunDetail.Event) -> Text {
        let role = e.data?["role"]?.string.map { "@\($0)" }
        switch e.type {
        case "stuck", "stalled":
            let human = e.data?["human"]?.string
            // `human` trae el comando entre acentos graves: se lee como markdown.
            return Text("\(role ?? "Un agente") ").bold() + Text(LocalizedStringKey(human.map { "se atoró: " + $0 } ?? "se atoró"))
        case "stuck_notified":
            return Text(role.map { "Te avisé que \($0) se atoró" } ?? "Te avisé que se atoró")
        case "box_ready", "box_waiting", "preview_on", "preview_off", "preview_blocking", "smoke_fail",
             "deploy_failed", "git_push_denied", "behind_main", "critique_timeout":
            // Los dice la plataforma: sin actor delante.
            return Text(event(e.type))
        default:
            return logLine(actor: e.actor, type: e.type)
        }
    }

    /// Quita el renglón `note` que la firma deja justo junto a ella con el mismo texto.
    static func withoutEchoedNotes(_ events: [FactoryRunDetail.Event]) -> [FactoryRunDetail.Event] {
        // `note` guarda 500 caracteres y la firma 2000: se compara por el principio.
        let signed = events.filter { ["approve", "changes"].contains($0.type) }.compactMap { $0.data?["note"]?.string }
        return events.filter { e in
            guard e.type == "note", let text = e.data?["text"]?.string, !text.isEmpty else { return true }
            return !signed.contains { $0.hasPrefix(text) }
        }
    }

    /// El renglón de la bitácora: «@plan entregó el plan» o «Firmaste tú».
    static func logLine(actor a: String?, type: String) -> Text {
        let who = actor(a)
        if who == "Tú", let verb = ownEvent(type) { return Text("\(verb) ") + Text("tú").bold() }
        return Text(who.map { "\($0) " } ?? "").bold() + Text(event(type))
    }
}

/// Una fila de la lista: número, título, etapa, repo y lo que costó.
struct FactoryRunRow: View {
    let run: FactoryRun

    var body: some View {
        let stage = run.stage
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(run.id)").gMono(size: 13, weight: .bold).foregroundStyle(Color.gInk3)
                Text(run.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.gChevron)
            }
            HStack(spacing: 8) {
                StageChip(stage: stage)
                if let repo = run.repo {
                    Label {
                        Text(repo.split(separator: "/").last.map(String.init) ?? repo).lineLimit(1)
                    } icon: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                    .labelStyle(FactoryMetaLabelStyle())
                }
                if let pr = run.prNumber {
                    Label { Text(pr) } icon: { Image(systemName: "arrow.triangle.pull") }
                        .labelStyle(FactoryMetaLabelStyle())
                }
                Spacer(minLength: 0)
            }
            let meta = [FactoryFormat.ago(run.updated), FactoryFormat.minutes(run.durationMin), FactoryFormat.usd(run.usd)]
                .compactMap { $0 }.joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta).gMono(size: 12, weight: .regular).foregroundStyle(Color.gInk3)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .ghostyCard(radius: Theme.Radius.list)
        .overlay(alignment: .leading) {
            // Lo que te toca lleva una franja ámbar: se encuentra de un vistazo.
            if stage.needsYou {
                UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.list, bottomLeadingRadius: Theme.Radius.list)
                    .fill(Color.gAmber).frame(width: 4)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.list))
    }
}

struct FactoryMetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10, weight: .semibold))
            configuration.title.font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color.gInk2)
    }
}

/// Confeti de una sola ráfaga (≈2.4 s) al mergear: cae y se va, nunca en bucle. Con «reducir
/// movimiento» no se pinta.
struct ConfettiBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    private static let colors: [Color] = [.gPrimary, .gAmber, .gGreen, .gSky, .gSalmon, .gBird]
    private static let pieces: [(x: Double, delay: Double, speed: Double, spin: Double, size: Double, drift: Double)] =
        (0..<70).map { i in
            var g = SplitMix(seed: UInt64(i) &* 0x9E3779B97F4A7C15)
            return (g.next(), g.next() * 0.35, 0.75 + g.next() * 0.6, g.next() * 8 - 4, 6 + g.next() * 6, g.next() * 0.16 - 0.08)
        }
    private let duration = 2.4

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSince(start)
                Canvas { gc, size in
                    guard t < duration + 0.4 else { return }
                    for (i, p) in Self.pieces.enumerated() {
                        let lt = max(0, t - p.delay)
                        let y = -20 + lt * p.speed * size.height * 0.55 + lt * lt * 120
                        let x = (p.x + p.drift * lt) * size.width
                        let fade = max(0, 1 - max(0, t - duration + 0.6) / 0.6)
                        var c = gc
                        c.translateBy(x: x, y: y)
                        c.rotate(by: .radians(lt * p.spin))
                        c.opacity = fade
                        let r = CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)
                        c.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(Self.colors[i % Self.colors.count]))
                    }
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
    }
}

/// Aleatorio con semilla: el confeti sale igual en cada toma.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
