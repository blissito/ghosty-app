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
            if let u = usage {
                if u.applies == false {
                    Text(agent.space?.kind == .workspace
                         ? "El uso de este agente lo cubre su espacio de equipo."
                         : "Este agente es de otra cuenta; su uso no cuenta en tu plan.")
                        .gMeta()
                        .padding(.horizontal, 4)
                        .entrance(appeared, order: 1)
                } else {
                    UsageCard(title: "Uso de esta semana", pct: u.week.pct ?? 0,
                              resetsAt: u.week.resetsAt, delay: 0.15)
                        .entrance(appeared, order: 1)
                    // Gratis no tiene tope mensual: sólo semana, y así se dice.
                    if let pct = u.month.pct {
                        UsageCard(title: "Uso de este mes", pct: pct, resetsAt: u.month.resetsAt, delay: 0.3)
                            .entrance(appeared, order: 2)
                    }
                    if let n = u.imagesWeek {
                        ImagesCard(count: n).entrance(appeared, order: 3)
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
            usage = DemoData.encendido ? Self.demo : await GhostyAPI.usage(agentId: agent.id)
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

    private var engineName: String {
        switch agent.engine {
        case "ghosty-lite": return "Ghosty Lite"
        case "claude":      return "Ghosty · Claude"
        default:            return agent.engine
        }
    }

    private static let demo = PersonalUsage(
        plan: .init(key: "free", name: "Gratis"),
        week: .init(pct: 0.23, resetsAt: Date().addingTimeInterval(2 * 86400)),
        month: .init(pct: nil, resetsAt: Date().addingTimeInterval(20 * 86400)),
        applies: true, imagesWeek: 4)
}

/// Una ventana de uso: el % grande cuenta hacia arriba mientras la barra se llena.
private struct UsageCard: View {
    let title: String
    let pct: Double
    let resetsAt: Date
    let delay: Double
    @State private var shown = 0.0

    private var target: Double { min(1, max(0, pct)) }
    private var tint: Color { target >= 1 ? .gDanger : target >= 0.8 ? .orange : .gPrimary }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gInk2)
                Spacer()
                Text("\(Int((shown * 100).rounded()))%")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: shown))
                    .foregroundStyle(target >= 0.8 ? tint : Color.gInk)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gSeparator)
                    Capsule()
                        .fill(target >= 0.8 ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.primaryGradient))
                        .frame(width: shown > 0 ? max(8, g.size.width * shown) : 0)
                }
            }
            .frame(height: 8)
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                Text("Se renueva el \(Self.date(resetsAt)) · \(Self.relative(resetsAt))")
            }
            .gCaption()
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

/// Cuántas imágenes lleva la semana; el número cuenta hacia arriba.
private struct ImagesCard: View {
    let count: Int
    @State private var shown = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.gPrimary)
                .frame(width: 38, height: 38)
                .background(Color.gPrimaryTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .symbolEffect(.bounce, value: shown)
            Text("Imágenes esta semana").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.gInk)
            Spacer()
            Text("\(shown)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(shown)))
                .foregroundStyle(Color.gInk)
        }
        .padding(14)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .onAppear {
            withAnimation(.spring(duration: 0.9).delay(0.45)) { shown = count }
        }
        .accessibilityElement(children: .combine)
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
