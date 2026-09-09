import SwiftUI

enum SheetPane: String, CaseIterable, Identifiable, Hashable {
    case activity, permissions, history, memory
    var id: String { rawValue }

    /// El nombre del panel. Se usa para VoiceOver: el segmentado es sólo iconos.
    var nombre: String {
        switch self {
        case .activity:    return "Actividad"
        case .permissions: return "Permisos"
        case .history:     return "Historial"
        case .memory:      return "Memoria"
        }
    }

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
    let store: LiveAgentStore
    var onAjustes: () -> Void
    var onNuevaConversacion: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// El panel abierto, RECORDADO entre aperturas y entre arranques.
    ///
    /// ⚠️ Era `@State` y por eso siempre volvía a Actividad: `.sheet(item:)` construye la
    /// vista de nuevo cada vez que se abre, así que el estado local nace virgen. Quien
    /// estaba mirando el historial tenía que volver a buscarlo en cada visita.
    @AppStorage("ghosty.panelDeLaHoja") private var panelGuardado = SheetPane.activity.rawValue

    /// Gancho de desarrollo: el simulador no acepta toques por script, así que sin esto
    /// no hay forma de verificar un panel que no sea el primero. Gana sobre lo guardado.
    private static let panelForzado =
        SheetPane(rawValue: ProcessInfo.processInfo.environment["GHOSTY_PANE"] ?? "")

    private var pane: Binding<SheetPane> {
        Binding(
            get: { Self.panelForzado ?? SheetPane(rawValue: panelGuardado) ?? .activity },
            set: { panelGuardado = $0.rawValue },
        )
    }

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

            SegmentedIconBar(items: SheetPane.allCases, icon: \.icon, label: \.nombre, selection: pane)
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.top, 16)

            ScrollView {
                Group {
                    switch pane.wrappedValue {
                    case .activity:    ActivityPane(store: store)
                    case .permissions: PermissionsPane(store: store)
                    case .history:     HistoryPane(store: store, onAbrir: { dismiss() })
                    case .memory:
                        EmptyState(icon: "brain",
                                   title: "Memoria",
                                   detail: "Lo que el agente recuerda de ti. Su caja todavía no lo expone, así que no hay nada que leer ni corregir.")
                            .padding(.top, 60)
                    }
                }
                // El contenido de la hoja no debe quedar pegado al borde inferior:
                // con varios turnos el último se leía a medias.
                .padding(.bottom, 28)
            }
            .padding(.top, 20)
            .scrollIndicators(.hidden)
        }
        .background(Color.gBg)
    }
}
