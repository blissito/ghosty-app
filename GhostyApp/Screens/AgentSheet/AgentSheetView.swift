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
                BotonDeCristal(simbolo: "xmark", etiqueta: "Cerrar") { dismiss() }
                    .accessibilityIdentifier("cerrar-hoja")
                Spacer()
                BotonDeCristal(simbolo: "gearshape", etiqueta: "Ajustes", accion: onAjustes)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            VStack(spacing: 5) {
                GhostyMascot(tone: agent.tone, height: 52)
                Text(agent.name).font(.gDisplay(16)).foregroundStyle(Color.gInk)
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

/// Botón redondo de Liquid Glass (iOS 26); antes de iOS 26, el círculo gris de siempre.
struct BotonDeCristal: View {
    let simbolo: String
    let etiqueta: String
    var accion: () -> Void

    var body: some View {
        Button(action: accion) {
            Image(systemName: simbolo)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.gInk)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .modifier(Cristal())
        .accessibilityLabel(etiqueta)
    }

    private struct Cristal: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
            } else {
                content
                    .buttonStyle(.plain)
                    .background(Color.gSeparator, in: Circle())
            }
        }
    }
}
