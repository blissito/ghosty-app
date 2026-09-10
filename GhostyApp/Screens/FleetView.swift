import SwiftUI

/// Tu flota: los agentes conectados en este teléfono. Tocar uno lo pone activo;
/// el **+** conecta otro.
///
/// El **+** NO crea agentes: crear uno levanta una caja y cuesta dinero, y eso vive
/// en Studio. Además, con un token de agente el API lo prohíbe.
struct FleetView: View {
    let store: LiveAgentStore
    var onConectar: () -> Void
    var onEditar: (AgentAccount) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Tu flota").gScreenTitle()
                    Spacer()
                    // Ya no se "añade" un agente desde aquí: los agentes son de la
                    // cuenta. Este botón abre la cuenta, y el icono lo dice.
                    Button(action: onConectar) {
                        TintedIcon(systemName: "person.crop.circle", tint: .gInk, background: .gCard, size: 36)
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 6)

                Text(resumen)
                    .gMeta()
                    .padding(.bottom, 16)

                VStack(spacing: 0) {
                    ForEach(Array(store.agents.enumerated()), id: \.element.id) { i, agente in
                        fila(agente, ultima: i == store.agents.count - 1)
                    }
                }
                .padding(.horizontal, Theme.Space.cardH)
                .ghostyCard()

                Text("Tus agentes salen de tu cuenta de Ghosty Studio. Para crear o configurar uno, entra desde la web.")
                    .gCaption()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 8)
        }
    }

    /// Cuántos hay y cuántos están ocupados. Lo segundo es la información nueva: con
    /// trabajo en paralelo, "3 agentes conectados" ya no dice lo que pasa.
    private var resumen: String {
        let n = store.agents.count
        let ocupados = store.trabajando.count
        let base = n == 1 ? "Un agente conectado" : "\(n) agentes conectados"
        guard ocupados > 0 else { return base }
        return base + (ocupados == 1 ? " · 1 trabajando" : " · \(ocupados) trabajando")
    }

    private func fila(_ agente: Agent, ultima: Bool) -> some View {
        let canal = store.canales[agente.id]
        return HStack(spacing: 13) {
            GhostyMascot(tone: agente.tone, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(agente.name).gRowTitle()
                // ⚠️ Lo que está HACIENDO manda sobre el motor: el motor es lo mismo
                // siempre y la tarea es lo único que cambia mientras esperas.
                if let turno = canal?.turno {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("\(turno.detail) · \(turno.elapsed)")
                            .gMeta()
                            .lineLimit(1)
                    }
                } else if canal?.permisoPendiente != nil {
                    Text("Espera tu permiso")
                        .gMeta()
                        .foregroundStyle(Color.gPrimary)
                } else {
                    Text(agente.engine).gMeta()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Detener sin ir a su conversación: si lo dejaste trabajando, pararlo no
            // debería obligarte a volver a donde estabas.
            if canal?.trabajando == true {
                Button { store.detener(canal) } label: {
                    TintedIcon(systemName: "stop.fill", tint: .gInk2, background: .gFill, size: 30)
                }
                .buttonStyle(.plain)
            }

            if agente.id == store.selectedAgentID {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.gPrimary)
            }

            Button {
                if let c = Credentials.accounts.first(where: { $0.id == agente.id }) {
                    onEditar(c)
                }
            } label: {
                TintedIcon(systemName: "ellipsis", tint: .gInk3, background: .gFill, size: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Theme.Space.row)
        .contentShape(Rectangle())
        .onTapGesture { store.seleccionar(agente.id) }
        .ghostySeparator(inset: ultima ? .infinity : 61)
    }
}
