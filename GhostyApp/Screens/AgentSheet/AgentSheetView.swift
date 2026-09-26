import SwiftUI

/// La hoja del agente. Se abre al tocar el avatar: su plan y cuánto va.
/// ⚠️ Tuvo pestañas de Actividad y Permisos. Actividad era ruido; el permiso vive ahora
/// en el chat, encima del compositor (`PermissionCard`), que es donde se contesta.
struct AgentSheetView: View {
    let agent: Agent
    let store: LiveAgentStore
    var onAjustes: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    TintedIcon(systemName: "xmark", tint: .gInk, background: .gSeparator, size: 34)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cerrar-hoja")
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
                StatusLine(status: store.estado(de: agent.id)).font(.system(size: 12.5))
            }
            .padding(.top, 10)

            ScrollView {
                UsagePane(agent: agent)
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
