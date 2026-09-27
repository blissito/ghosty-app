import SwiftUI

/// El plan y cuánto va de él: lo que la persona quiere saber al tocar su agente.
///
/// ⚠️ Sin botones de «cambiar plan» ni ligas a la web: Apple (3.1.1) no deja ni insinuar
/// una compra fuera de la tienda. Aquí se CONSULTA, no se vende.
struct UsagePane: View {
    let agent: Agent
    @State private var usage: PersonalUsage?
    @State private var loaded = false
    /// Las tarjetas entran escalonadas cuando llega el uso.
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            planCard.entrance(appeared, order: 0)
            if let u = usage, u.modelAllowedInPlan == false {
                NoticeCard(icon: "exclamationmark.triangle.fill", tint: .gBird,
                           title: "Este modelo no está incluido en tu plan",
                           detail: "Cambia de modelo en la conversación para seguir usándolo.")
                    .entrance(appeared, order: 1)
            }
            if let u = usage {
                if u.applies == false, let ws = u.workspace {
                    UsageCard(title: "Uso del espacio \(ws.name.prefix(1).uppercased() + ws.name.dropFirst())",
                              icon: "person.3.fill", accent: .gBrand,
                              pct: ws.pct, resetsAt: ws.resetsAt, delay: 0.15,
                              note: "Lo comparten todos los agentes del espacio; no cuenta en tu plan personal.")
                        .entrance(appeared, order: 1)
                } else if let key = u.ownKey {
                    // Una llave de OpenAI paga chat E imágenes: todo va en una sola tarjeta. Con
                    // otra llave (DeepSeek, Claude) las imágenes siguen yendo por la de casa y
                    // contando del plan, así que van en la suya.
                    // Con llave de OpenAI (sola, o junto a la del chat) las imágenes tampoco
                    // gastan del plan: todo va en la misma tarjeta.
                    let unified = u.ownImageKey == true
                    OwnKeyCard(key: key, imagesWeek: unified ? u.imagesWeek : nil, imagesHd: u.imagesWeekHd ?? 0).entrance(appeared, order: 1)
                    if !unified, let n = u.imagesWeek {
                        ImagesCard(made: n, left: u.ownImageKey == true ? nil : u.imagesLeft, cap: u.imagesCap,
                                   leftHd: u.imagesLeftHd, ownKey: u.ownImageKey == true, hd: u.imagesWeekHd ?? 0,
                                   maxQuality: u.plan.imageQuality ?? "low")
                            .entrance(appeared, order: 2)
                    }
                } else if u.exempt == true {
                    NoticeCard(icon: "sparkles", tint: .gBrand,
                               title: "Sin tope · acceso anticipado",
                               detail: "Estuviste desde el principio: este agente no tiene límite de uso.")
                        .entrance(appeared, order: 1)
                    if let n = u.imagesWeek {
                        ImagesCard(made: n, left: u.ownImageKey == true ? nil : u.imagesLeft, cap: u.imagesCap,
                                   leftHd: u.imagesLeftHd, ownKey: u.ownImageKey == true, hd: u.imagesWeekHd ?? 0,
                                   maxQuality: u.plan.imageQuality ?? "low")
                            .entrance(appeared, order: 2)
                    }
                } else if u.applies == false {
                    Text(agent.space?.kind == .workspace
                         ? "Este agente es del espacio \(agent.space?.title ?? "de equipo"): su uso lo cubre ese espacio, no tu plan personal."
                         : agent.compartidoPor != nil
                            ? "Este agente es de \(agent.compartidoPor!); su uso cuenta en su plan, no en el tuyo."
                            : "Su uso no cuenta en tu plan personal.")
                        .gMeta()
                        .padding(.horizontal, 4)
                        .entrance(appeared, order: 1)
                } else {
                    // Como Claude: la sesión de 5 h arriba, luego la semana.
                    if let session = u.session {
                        UsageCard(title: "Sesión actual", icon: "timer", accent: .gBrand, pct: session.pct,
                                  resetsAt: session.resetsAt ?? Date(), delay: 0.1,
                                  note: session.resetsAt == nil ? "Empieza con tu siguiente mensaje · dura 5 h" : nil,
                                  sessionStyle: true)
                            .entrance(appeared, order: 1)
                    }
                    UsageCard(title: "Uso de esta semana", icon: "calendar", accent: .gSky, pct: u.week.pct ?? 0,
                              resetsAt: u.week.resetsAt, delay: 0.15,
                              exhausted: u.exhausted == true && (u.week.pct ?? 0) >= 1)
                        .entrance(appeared, order: 1)
                    // Gratis no tiene tope mensual: sólo semana, y así se dice.
                    // Sólo si importa aquí: este agente usa un modelo top, o ya se gastó algo de ese tope.
                    if let premium = u.premium, premium.pct > 0 || Self.isPremiumModel(agent.model) {
                        UsageCard(title: "Claude y modelos top", icon: "sparkles", accent: .gSalmon, pct: premium.pct,
                                  resetsAt: u.week.resetsAt, delay: 0.25)
                            .entrance(appeared, order: 2)
                    }
                    // El mes es un respaldo: sólo se enseña cuando se acerca.
                    if let pct = u.month.pct, pct >= 0.8 {
                        UsageCard(title: "Uso de este mes", icon: "calendar.circle.fill", accent: .gGrass, pct: pct, resetsAt: u.month.resetsAt, delay: 0.3)
                            .entrance(appeared, order: 2)
                    }
                    if let n = u.imagesWeek {
                        ImagesCard(made: n, left: u.ownImageKey == true ? nil : u.imagesLeft, cap: u.imagesCap, leftHd: u.imagesLeftHd,
                                   ownKey: u.ownImageKey == true, hd: u.imagesWeekHd ?? 0,
                                   chatExhausted: u.exhausted == true,
                                   resetsOn: u.exhausted == true ? u.week.resetsAt : nil,
                                   medium: u.imagesLeftMedium,
                                   maxQuality: u.plan.imageQuality ?? "low").entrance(appeared, order: 3)
                    }
                }
            } else if loaded {
                Text("No pude leer tu uso. Revisa tu conexión.").gMeta().padding(.horizontal, 4)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
            }
        }
        .padding(.horizontal, Theme.Space.screenH)
        .task {
            if DemoData.encendido { usage = Self.demo; return }
            // Primero lo que ya se sabe (memoria o disco), luego la red en segundo plano.
            if usage == nil {
                usage = UsosDeAgentes.compartido.usos[agent.id] ?? UsoEnDisco.leer(agente: agent.id)
            }
            if let fresco = await GhostyAPI.usage(agentId: agent.id) {
                withAnimation(.easeOut(duration: 0.25)) { usage = fresco }
                UsosDeAgentes.compartido.usos[agent.id] = fresco
            }
            loaded = true
            withAnimation(.spring(duration: 0.55, bounce: 0.25)) { appeared = true }
        }
    }

    /// «Plan Gratis» + motor y modelo: que se vea qué trae el agente.
    private var planCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .symbolEffect(.bounce, value: appeared)
            VStack(alignment: .leading, spacing: 2) {
                if let u = usage, u.applies != false {
                    Text("Plan \(u.plan.name)").gCardTitle()
                }
                Text([engineName, agent.model].compactMap { $0 }.joined(separator: " · "))
                    .gMeta()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gPrimaryTint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Claude Sonnet y arriba (y los top de otros): los que cuentan en «Claude y modelos top».
    static func isPremiumModel(_ model: String?) -> Bool {
        guard let m = model?.lowercased() else { return false }
        return ["claude", "sonnet", "opus", "fable", "astra"].contains { m.contains($0) }
    }

    private var engineName: String {
        switch agent.engine {
        case "ghosty-lite": return "Ghosty Lite"
        case "claude":      return "Ghosty · Claude"
        default:            return agent.engine
        }
    }

    static var demo: PersonalUsage {
        if Gancho.valor("GHOSTY_DEMO_PLAN") == "byok-openai" {
            var u = demoFree
            u.ownKey = .init(provider: "openai", turnsWeek: 42, tokensWeek: 1_840_000, dailyTurns: [9, 14, 6, 11, 2, 0, 0])
            u.ownImageKey = true
            u.imagesWeekHd = 2
            return u
        }
        if Gancho.valor("GHOSTY_DEMO_PLAN") == "early" {
            return PersonalUsage(
                plan: .init(key: "free", name: "Gratis", imageQuality: "low"),
                week: .init(pct: 0.4, resetsAt: Date().addingTimeInterval(2 * 86400)),
                month: .init(pct: nil, resetsAt: Date().addingTimeInterval(20 * 86400)),
                applies: true, imagesWeek: 3, imagesLeft: 5, imagesCap: 8, workspace: nil, exempt: true)
        }
        if Gancho.valor("GHOSTY_DEMO_PLAN") == "exhausted" {
            return PersonalUsage(
                plan: .init(key: "free", name: "Gratis", imageQuality: "low"),
                week: .init(pct: 1, resetsAt: Date().addingTimeInterval(2 * 86400)),
                month: .init(pct: nil, resetsAt: Date().addingTimeInterval(20 * 86400)),
                applies: true, imagesWeek: 4, imagesLeft: 0, workspace: nil, exhausted: true)
        }
        if Gancho.valor("GHOSTY_DEMO_PLAN") == "byok-two" {
            var u = demoFree
            u.ownKey = .init(provider: "anthropic", turnsWeek: 42, tokensWeek: 1_840_000, dailyTurns: [9, 14, 6, 11, 2, 0, 0])
            u.ownImageKey = true
            u.imagesWeekHd = 2
            return u
        }
        if Gancho.valor("GHOSTY_DEMO_PLAN") == "byok" {
            var u = demoFree
            u.ownKey = .init(provider: "deepseek", turnsWeek: 42, tokensWeek: 1_840_000, dailyTurns: [9, 14, 6, 11, 2, 0, 0])
            return u
        }
        if Gancho.valor("GHOSTY_DEMO_PLAN") == "power" {
            return PersonalUsage(
                plan: .init(key: "power", name: "Power · cortesía", imageQuality: "high"),
                week: .init(pct: 0.12, resetsAt: Date().addingTimeInterval(2 * 86400)),
                month: .init(pct: 0.04, resetsAt: Date().addingTimeInterval(20 * 86400)),
                applies: true, imagesWeek: 3, imagesLeft: 256, imagesLeftHd: 30, workspace: nil)
        }
        return demoFree
    }

    private static let demoFree: PersonalUsage = PersonalUsage(
        plan: .init(key: "free", name: "Gratis"),
        session: .init(pct: 0.22, resetsAt: Date().addingTimeInterval(2 * 3600 + 57 * 60)),
        week: .init(pct: 0.23, resetsAt: Date().addingTimeInterval(2 * 86400)),
        month: .init(pct: nil, resetsAt: Date().addingTimeInterval(20 * 86400)),
        applies: true, imagesWeek: 4, imagesLeft: 6, workspace: nil)
}

/// Una ventana de uso: el % grande cuenta hacia arriba mientras la barra se llena.
private struct UsageCard: View {
    let title: String
    let icon: String
    /// El color de la tarjeta; al 80% pasa a `bird` y al 100% a rojo, como en la web.
    let accent: Color
    let pct: Double
    let resetsAt: Date
    let delay: Double
    var note: String? = nil
    /// Se acabó (sin recargas): en vez de «se renueva el…» se dice que está en pausa hasta cuándo.
    var exhausted = false
    /// Sesión de 5 h: «Se restablece en 2 h 57 min» en vez de una fecha.
    var sessionStyle = false
    @State private var shown = 0.0

    private var target: Double { min(1, max(0, pct)) }
    private var tint: Color { target >= 1 ? .gDanger : target >= 0.8 ? .gBird : accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gInk2)
                Spacer()
                // Con uso pero menos de 1%: «<1%», no un 0% que parece que no contó.
                Text(target > 0 && target < 0.005 && shown >= target ? "<1%" : "\(Int((shown * 100).rounded()))%")
                    .font(.gDisplay(30, .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: shown))
                    .foregroundStyle(target >= 1 ? Color.gDanger : Color.gInk)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.18))
                    Capsule()
                        .fill(tint)
                        .frame(width: shown > 0 ? max(8, g.size.width * shown) : 0)
                }
            }
            .frame(height: 8)
            if sessionStyle {
                if note == nil {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        Text(target >= 1 ? "Se acabó tu sesión · vuelve en \(Self.inHours(resetsAt))"
                             : "Se restablece en \(Self.inHours(resetsAt))")
                    }
                    .font(.system(size: 13, weight: target >= 1 ? .semibold : .regular))
                    .foregroundStyle(target >= 1 ? Color.gDanger : Color.gInk4)
                }
            } else if exhausted {
                HStack(spacing: 5) {
                    Image(systemName: "pause.circle.fill").font(.system(size: 12, weight: .semibold))
                    Text("Se acabó tu uso de la semana · vuelve el \(Self.date(resetsAt)) (\(Self.relative(resetsAt)))")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.gDanger)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    Text("Se renueva el \(Self.date(resetsAt)) · \(Self.relative(resetsAt))")
                }
                .gCaption()
            }
            if let note { Text(note).gCaption() }
        }
        .padding(16)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .onAppear {
            withAnimation(.spring(duration: 1.1, bounce: 0.15).delay(delay)) { shown = target }
        }
        .accessibilityElement(children: .combine)
    }

    private static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.timeZone = TimeZone(identifier: "America/Mexico_City")
        f.dateFormat = "EEEE d 'de' MMMM"
        return f.string(from: d)
    }

    /// «2 h 57 min».
    static func inHours(_ d: Date) -> String {
        let mins = max(0, Int(d.timeIntervalSinceNow / 60))
        return mins >= 60 ? "\(mins / 60) h \(mins % 60) min" : "\(mins) min"
    }

    /// «en 2 días» / «mañana» / «hoy».
    private static func relative(_ d: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
        switch days {
        case ..<1: return "hoy"
        case 1:    return "mañana"
        default:   return "en \(days) días"
        }
    }
}

/// Las imágenes de la semana: cuántas llevas y cuántas más te alcanzan. Los puntos
/// llenos son las hechas y los claros las que quedan; se encienden uno tras otro.
private struct ImagesCard: View {
    let made: Int
    let left: Int?
    /// Conteo semanal fijo, si lo hay: «Llevas 3 de 8».
    var cap: Int? = nil
    /// Si todas fueran HD: el default es normal y HD se pide, así que va aparte.
    var leftHd: Int? = nil
    /// Con llave propia de OpenAI: sin conteo del plan.
    var ownKey = false
    /// Cuántas de las hechas salieron en HD.
    var hd = 0
    /// Se acabó el uso del chat: las imágenes que quedan esperan a que vuelva (el agente no corre).
    var chatExhausted = false
    /// Se acabó el uso del chat: cuándo vuelve.
    var resetsOn: Date? = nil
    /// Pro: cuántas quedarían en calidad media.
    var medium: Int? = nil
    /// La mejor calidad que el plan deja pedir (`personal-plans.ts`, `imageQuality`): low | medium | high.
    let maxQuality: String
    @State private var lit = 0

    /// Con muchas, cada punto es una parte proporcional: nunca más de 20 puntos, y si ya
    /// hiciste alguna, al menos uno lleno.
    private var total: Int { made + (left ?? 0) }
    private var dots: Int { min(total, 20) }
    private var filledDots: Int {
        guard total > 20 else { return made }
        return made == 0 ? 0 : max(1, Int((Double(made) / Double(total) * 20).rounded()))
    }

    /// «lunes», en la zona de CDMX.
    static func weekday(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.timeZone = TimeZone(identifier: "America/Mexico_City")
        f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.gSalmon, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .symbolEffect(.bounce, value: lit)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Imágenes").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk)
                        // El default siempre es baja; media o alta son un DERECHO a pedirla.
                        Text(maxQuality == "high" ? "HD si la pides" : maxQuality == "medium" ? "Media si la pides" : "Baja calidad")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x9A5A36))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.gSalmon.opacity(0.25), in: Capsule())
                    }
                    Text((ownKey ? "Con tu llave de OpenAI · sin límite · llevas \(made)"
                          : cap.map { "Llevas \(made) de \($0) esta semana" } ?? "Llevas \(made) esta semana")
                         + (hd > 0 ? " · \(hd) HD" : "")).gCaption()
                }
                Spacer()
                if let left {
                    VStack(alignment: .trailing, spacing: 0) {
                        // Se lee de arriba abajo: «te quedan / 256 / o ~30 en HD».
                        Text(left == 1 ? "te queda" : "te quedan").gCaption()
                        // Con conteo fijo el número es exacto; con presupuesto, estimado.
                        Text(left == 0 || cap != nil ? "\(left)" : "~\(left)")
                            .font(.gDisplay(26, .bold))
                            .monospacedDigit()
                            .foregroundStyle(left == 0 ? Color.gDanger : Color.gInk)
                        if let leftHd, cap == nil {
                            Text("o ~\(leftHd) en HD").gCaption()
                        } else if let medium, cap == nil {
                            Text("o ~\(medium) en media").gCaption()
                        }
                    }
                }
            }
            if left != nil, dots > 0 {
                HStack(spacing: 5) {
                    ForEach(0..<dots, id: \.self) { i in
                        Circle()
                            .fill(i < filledDots ? Color.gSalmon : Color.gSalmon.opacity(0.25))
                            .frame(width: 10, height: 10)
                            .scaleEffect(i < lit ? 1 : 0.2)
                            .opacity(i < lit ? 1 : 0)
                    }
                }
            }
            if chatExhausted, (left ?? 0) > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "pause.circle").font(.system(size: 11, weight: .bold))
                    Text("Para pedirlas necesitas uso de chat: vuelve el \(Self.weekday(resetsOn ?? Date()))")
                }
                .gCaption()
            }
        }
        .padding(14)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .task {
            // Uno tras otro: primero las hechas, luego las que quedan.
            try? await Task.sleep(for: .milliseconds(350))
            for _ in 0..<dots {
                withAnimation(.spring(duration: 0.35, bounce: 0.5)) { lit += 1 }
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Corre con tu llave: el plan no se gasta, así que en vez de una barra que no se mueve se
/// enseña lo que MIDE gs de la semana — sin límite no es sin medir.
private struct OwnKeyCard: View {
    let key: PersonalUsage.OwnKey
    /// Con llave de OpenAI también paga las imágenes: su conteo va aquí, como tercer dato.
    var imagesWeek: Int? = nil
    var imagesHd = 0
    @State private var shownImages = 0
    @State private var shownTurns = 0
    @State private var shownTokens = 0.0
    @State private var grown = false
    @State private var keyTurn = false
    /// La columna tocada: su día y sus turnos salen arriba de la gráfica.
    @State private var selectedDay: Int?

    private var providerName: String {
        switch key.provider {
        case "anthropic", "anthropic-oauth": return "Claude"
        case "deepseek": return "DeepSeek"
        case "openai": return "OpenAI"
        case "google": return "Google"
        default: return key.provider.capitalized
        }
    }

    private var daily: [Int] { key.dailyTurns ?? [] }
    /// La del chat es de otro proveedor y la de OpenAI paga las imágenes.
    private var twoKeys: Bool { imagesWeek != nil && key.provider != "openai" }
    private static let dayLetters = ["L", "M", "M", "J", "V", "S", "D"]
    private static let dayNames = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Text("Esta semana").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.gInk3)
                .padding(.bottom, -8)
            HStack(spacing: 10) {
                stat(title: "Turnos", value: Text("\(shownTurns)").contentTransition(.numericText(value: Double(shownTurns))))
                stat(title: "Tokens", value: Text(Self.tokens(Int(shownTokens))).contentTransition(.numericText(value: shownTokens)))
                if imagesWeek != nil {
                    stat(title: "Imágenes", badge: imagesHd > 0 ? "\(imagesHd) HD" : nil,
                         value: Text("\(shownImages)").contentTransition(.numericText(value: Double(shownImages))))
                }
            }
            if daily.count == 7 { chart }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.gGrass.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.gGrass.opacity(0.25), lineWidth: 1))
        )
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.5).delay(0.1)) { keyTurn = true }
            withAnimation(.spring(duration: 1.1, bounce: 0.1).delay(0.2)) {
                shownTurns = key.turnsWeek ?? 0
                shownTokens = Double(key.tokensWeek ?? 0)
                shownImages = imagesWeek ?? 0
            }
            withAnimation(.spring(duration: 0.6, bounce: 0.3).delay(0.35)) { grown = true }
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(keyTurn ? 0 : -60))
                .scaleEffect(keyTurn ? 1 : 0.6)
                .frame(width: 44, height: 44)
                .background(Color.gGrass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(twoKeys ? "Con tus llaves de \(providerName) y OpenAI" : "Con tu llave de \(providerName)")
                    .font(.gDisplay(16)).foregroundStyle(Color.gInk)
                Text(twoKeys ? "\(providerName) paga el chat y OpenAI las imágenes: sin límite de uso, modelos ni imágenes."
                     : imagesWeek != nil ? "Paga el chat y las imágenes: sin límite de uso, modelos ni imágenes."
                     : "No gasta de tu plan: sin límite de uso ni de modelos.").gCaption()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("∞").font(.gDisplay(22, .bold)).foregroundStyle(Color.gGrass)
        }
    }

    private func stat(title: String, badge: String? = nil, value: some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                value
                    .font(.gDisplay(26, .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Color(hex: 0x9A5A36))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.gSalmon.opacity(0.3), in: Capsule())
                }
            }
            Text(title).gCaption().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Siete barras, una por día; crecen una tras otra. La de hoy va en color pleno.
    private var chart: some View {
        let top = max(daily.max() ?? 0, 1)
        let today = (Calendar(identifier: .iso8601).component(.weekday, from: Date()) + 5) % 7
        let focus = selectedDay ?? today
        return VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 4) {
            Text(Self.dayNames[focus].capitalized).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.gInk)
            Text("· \(daily[focus]) \(daily[focus] == 1 ? "turno" : "turnos")")
                .font(.system(size: 13)).foregroundStyle(Color.gInk3)
                .contentTransition(.numericText(value: Double(daily[focus])))
        }
        .animation(.snappy, value: focus)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 5) {
                    // El número arriba de cada barra: se lee sin tocar.
                    Text(daily[i] > 0 ? "\(daily[i])" : "")
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(i == focus ? Color.gInk : Color.gInk3)
                        .opacity(grown ? 1 : 0)
                    Capsule()
                        .fill(i == focus ? Color.gGrass : Color.gGrass.opacity(0.45))
                        .frame(width: 14, height: grown ? max(4, 54 * CGFloat(daily[i]) / CGFloat(top)) : 4)
                        .animation(.spring(duration: 0.6, bounce: 0.35).delay(0.35 + Double(i) * 0.05), value: grown)
                    Text(Self.dayLetters[i])
                        .font(.system(size: 11, weight: i == focus ? .bold : .medium))
                        .foregroundStyle(i == focus ? Color.gInk : Color.gInk3)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.snappy) { selectedDay = i }
                }
                .accessibilityLabel("\(Self.dayNames[i]): \(daily[i]) turnos")
            }
        }
        .frame(height: 88, alignment: .bottom)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 1234567 → «1.2 M», 45300 → «45 k».
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1f M", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000) k" }
        return "\(n)"
    }
}

/// Un aviso de una línea con su icono de color: acceso anticipado, modelo fuera del plan.
private struct NoticeCard: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    @State private var shown = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .symbolEffect(.bounce, value: shown)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.gDisplay(15.5)).foregroundStyle(Color.gInk)
                Text(detail).gCaption().fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear { shown = true }
    }
}

private extension View {
    /// Entrada escalonada: sube un poco y aparece, cada tarjeta un instante después.
    func entrance(_ on: Bool, order: Int) -> some View {
        self.opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 14)
            .animation(.spring(duration: 0.55, bounce: 0.25).delay(Double(order) * 0.07), value: on)
    }
}
