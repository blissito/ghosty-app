import SwiftUI

enum SheetPane: String, CaseIterable, Identifiable, Hashable {
    case activity, permissions, history, memory
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .activity:    return "waveform.path.ecg"
        case .permissions: return "checkmark.shield"
        case .history:     return "clock.arrow.circlepath"
        case .memory:      return "brain"
        }
    }
}

/// La hoja del agente. Se abre al tocar el avatar y **no tiene barra de pestañas**:
/// aquí la navegación es el segmentado de cuatro. Meter las dos era navegación
/// duplicada, y era el error que había en la primera versión del diseño.
struct AgentSheetView: View {
    let agent: Agent
    let store: any AgentStoring
    var onAjustes: () -> Void
    var onNuevaConversacion: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var pane: SheetPane = .activity

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    TintedIcon(systemName: "xmark", tint: .gInk, background: .gSeparator, size: 34)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: onAjustes) {
                    TintedIcon(systemName: "gearshape", tint: .gInk, background: .gSeparator, size: 34)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            VStack(spacing: 5) {
                GhostyMascot(tone: agent.tone, height: 52)
                Text(agent.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk)
                StatusLine(status: agent.status).font(.system(size: 12.5))
            }
            .padding(.top, 10)

            if let onNuevaConversacion {
                Button {
                    onNuevaConversacion()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Nueva conversación").font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Color.gPrimary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.gPrimaryTint)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.top, 18)
            }

            SegmentedIconBar(items: SheetPane.allCases, icon: \.icon, selection: $pane)
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.top, 16)

            ScrollView {
                switch pane {
                case .activity:    ActivityPane(store: store)
                case .permissions: PermissionsPane(store: store)
                case .history:     HistoryPane(store: store)
                case .memory:
                    EmptyState(icon: "brain",
                               title: "Memoria",
                               detail: "Lo que el agente recuerda de ti, en un archivo que puedes leer y corregir.")
                        .padding(.top, 60)
                }
            }
            .padding(.top, 20)
        }
        .background(Color.gBg)
    }
}
