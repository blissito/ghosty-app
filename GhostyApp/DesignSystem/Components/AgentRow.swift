import SwiftUI

/// Punto de color + texto: el estado va DEBAJO del nombre, que es lo que hace que
/// una lista de agentes se lea de un vistazo.
struct StatusLine: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .working(let tarea):
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.gPrimary)
                Text(tarea).gMeta().foregroundStyle(Color.gPrimary)
                    .lineLimit(1).truncationMode(.tail)
            case .awaitingApproval:
                Circle().fill(Color.gDanger).frame(width: 7, height: 7)
                Text("Espera tu visto bueno").gMeta()
            case .idle(let desde):
                Text("En reposo · \(desde)").gMeta().foregroundStyle(Color.gInk4)
            }
        }
    }
}

struct AgentRow: View {
    let agent: Agent
    var onStop: (() -> Void)?
    var onOpen: (() -> Void)?

    var body: some View {
        HStack(spacing: 13) {
            GhostyMascot(tone: agent.tone, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).gRowTitle()
                StatusLine(status: agent.status)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch agent.status {
            case .working:
                Button { onStop?() } label: {
                    RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
                        .fill(Color.gInk)
                        .frame(width: 34, height: 34)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2.5).fill(Color.white)
                                .frame(width: 9, height: 9)
                        }
                }
                .buttonStyle(.plain)
            case .awaitingApproval:
                Text("1").gChip().foregroundStyle(.white)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(Color.gDanger)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            case .idle:
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.gInk4.opacity(0.7))
            }
        }
        .padding(.vertical, Theme.Space.row)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
    }
}
