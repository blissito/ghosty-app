import SwiftUI

/// «Cambiar de agente»: el contenido de la `GhostySheet` que abre el avatar de la barra.
///
/// Agentes reales, con su tipo (personal, espacio o compartido), la barra de uso REAL
/// que dé `/me/usage` para cada uno y la palomita en el seleccionado. Nunca números
/// inventados: si el uso no llegó o no aplica (llave propia, sin tope), no hay barra.
struct CambiarAgenteSheet: View {
    let store: LiveAgentStore
    /// Se eligió uno (o el mismo): quien la abrió cierra la hoja y va al chat.
    var onElegido: () -> Void

    /// Uso por agente, compartido con Perfil: al reabrir la hoja las barras ya están.
    /// Ausente = todavía no llega o falló.
    @State private var cache = UsosDeAgentes.compartido
    private var usos: [String: PersonalUsage] { cache.usos }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(store.agents.enumerated()), id: \.element.id) { i, agente in
                let elegido = agente.id == store.selectedAgentID
                GhostySheetRow(title: agente.name, subtitle: Self.tipo(agente), selected: elegido,
                               action: { elegir(agente) },
                               leading: { AgentAvatar(tone: agente.tone, size: 40) },
                               // Sólo elegir: el uso vive en Perfil y en la hoja del agente de arriba.
                               extra: { EmptyView() })
                    .accessibilityIdentifier("agente-\(agente.id)")
                    // Las filas entran escalonadas, como el `gin` del prototipo.
                    .gIn(duration: 0.25, delay: 0.04 + Double(min(i, 6)) * 0.04)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.selectedAgentID)
    }

    /// La línea bajo el nombre: de quién es el agente.
    static func tipo(_ a: Agent) -> String {
        switch a.space?.kind {
        case .workspace?:
            let n = a.space!.name
            return "Espacio · \(n.prefix(1).uppercased() + n.dropFirst())"
        case .shared?:
            return a.compartidoPor.map { "Compartido · de \($0)" } ?? "Compartido contigo"
        default:
            if let de = a.compartidoPor { return "Compartido · de \(de)" }
            return "Personal · \(a.model ?? a.engine)"
        }
    }

    @ViewBuilder
    private func barra(de agente: Agent) -> some View {
        if let m = Self.medida(usos[agente.id]) {
            let pct = m.0, etiqueta = m.1
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gSeparator)
                        Capsule().fill(Color.gPrimary)
                            .frame(width: geo.size.width * min(1, max(0, pct)))
                    }
                }
                .frame(height: 4)
                Text(etiqueta)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.gInk2)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, 6)
            .transition(.opacity)
        }
    }

    /// Qué barra se enseña: la del espacio si el agente es de uno, la semanal del plan
    /// si le aplica. Llave propia o sin tope: ninguna (no hay tope que medir).
    static func medida(_ u: PersonalUsage?) -> (Double, String)? {
        guard let u else { return nil }
        if u.applies == false, let ws = u.workspace {
            return (ws.pct, "\(Int((ws.pct * 100).rounded())) % del espacio")
        }
        if u.ownKey != nil || u.exempt == true || u.applies == false { return nil }
        guard let pct = u.week.pct else { return nil }
        return (pct, "\(Int((pct * 100).rounded())) % de la semana")
    }

    private func elegir(_ agente: Agent) {
        store.seleccionar(agente.id)
        onElegido()
    }
}
