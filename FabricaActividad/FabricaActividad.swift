import ActivityKit
import SwiftUI
import WidgetKit

/// La Live Activity de un pedido de la Fábrica, en la pantalla bloqueada y en la Dynamic Island.
/// Sólo compila esto y `FactoryActivityAttributes.swift`: una extensión de widget vive con poca
/// memoria, así que nada de `Core/` entero. Los colores son los de `Theme.swift`, copiados.
@main
struct FabricaActividadBundle: WidgetBundle {
    var body: some Widget { FabricaActividad() }
}

private extension Color {
    static let brand = Color(red: 0x84 / 255, green: 0x83 / 255, blue: 0xE0 / 255)
    static let amber = Color(red: 0xD9 / 255, green: 0x8E / 255, blue: 0x04 / 255)
    static let amberSoft = Color(red: 0xF5 / 255, green: 0xB8 / 255, blue: 0x3D / 255)
    static let green = Color(red: 0x2E / 255, green: 0xA0 / 255, blue: 0x5A / 255)
}

/// El color de la etapa: ámbar si te espera, verde al terminar, morado mientras trabaja.
private func tone(_ s: FactoryActivityAttributes.ContentState) -> Color {
    s.needsYou ? .amber : s.stage == "done" ? .green : .brand
}

private func symbol(_ s: FactoryActivityAttributes.ContentState) -> String {
    if s.needsYou { return "hand.raised.fill" }
    switch s.stage {
    case "done": return "checkmark.circle.fill"
    case "cancelled": return "xmark.circle.fill"
    case "checking": return "checklist"
    case "planning": return "doc.text"
    default: return "hammer.fill"
    }
}

struct FabricaActividad: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FactoryActivityAttributes.self) { ctx in
            LockScreen(attributes: ctx.attributes, state: ctx.state, stale: ctx.isStale)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.92))
                .widgetURL(link(ctx.attributes))
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("#\(ctx.attributes.runId)", systemImage: symbol(s))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tone(s))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let since = s.sinceDate {
                        Text(since, style: .timer).monospacedDigit().font(.system(size: 14))
                            .foregroundStyle(.secondary).frame(maxWidth: 64, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.headline).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if let stalled = s.stalled {
                            Text(LocalizedStringKey("Se atoró: " + stalled)).font(.system(size: 13)).foregroundStyle(Color.amberSoft).lineLimit(2)
                        } else if let now = s.now {
                            Text(now).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(ctx.attributes.title).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: s.stalled != nil ? "hourglass" : symbol(s))
                    .foregroundStyle(s.stalled != nil ? Color.amberSoft : tone(s))
            } compactTrailing: {
                if s.needsYou {
                    Text("Tú").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.amberSoft)
                } else if let since = s.sinceDate {
                    Text(since, style: .timer).monospacedDigit().font(.system(size: 13)).frame(maxWidth: 44)
                }
            } minimal: {
                Image(systemName: symbol(s)).foregroundStyle(tone(s))
            }
            .widgetURL(link(ctx.attributes))
            .keylineTint(tone(s))
        }
    }

    private func link(_ a: FactoryActivityAttributes) -> URL? {
        var c = URLComponents()
        c.scheme = "com.fixtergeek.ghostyapp"
        c.host = "pedido"
        c.queryItems = [URLQueryItem(name: "espacio", value: a.slug), URLQueryItem(name: "id", value: String(a.runId))]
        return c.url
    }
}

/// La pantalla bloqueada: el pedido, quién trabaja y en qué, su reloj y el atasco si lo hay.
private struct LockScreen: View {
    let attributes: FactoryActivityAttributes
    let state: FactoryActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol(state)).font(.system(size: 13, weight: .semibold)).foregroundStyle(tone(state))
                Text("Pedido #\(attributes.runId) · \(attributes.title)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let since = state.sinceDate, !state.needsYou {
                    Text(since, style: .timer).monospacedDigit().font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: 56, alignment: .trailing)
                }
            }
            Text(state.headline).font(.system(size: 17, weight: .bold)).foregroundStyle(state.needsYou ? Color.amber : .primary)
            if let stalled = state.stalled {
                Label { Text(LocalizedStringKey("Se atoró: " + stalled)).lineLimit(2) } icon: { Image(systemName: "hourglass") }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.amber)
            } else if let now = state.now {
                Text(now).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            if state.stepsDone > 0, !state.needsYou {
                Text(stale ? "\(state.stepsDone) pasos · sin noticias recientes" : "\(state.stepsDone) pasos hechos")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }
}
