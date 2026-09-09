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
                    Button(action: onConectar) {
                        TintedIcon(systemName: "plus", tint: .gInk, background: .gCard, size: 36)
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 6)

                Text(store.agents.count == 1
                     ? "Un agente conectado"
                     : "\(store.agents.count) agentes conectados")
                    .gMeta()
                    .padding(.bottom, 16)

                VStack(spacing: 0) {
                    ForEach(Array(store.agents.enumerated()), id: \.element.id) { i, agente in
                        fila(agente, ultima: i == store.agents.count - 1)
                    }
                }
                .padding(.horizontal, Theme.Space.cardH)
                .ghostyCard()

                Text("Un token `agt_` alcanza sólo a su agente y no puede listar ni borrar. Es el que se le da a alguien más.")
                    .gCaption()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 8)
        }
    }

    private func fila(_ agente: Agent, ultima: Bool) -> some View {
        HStack(spacing: 13) {
            GhostyMascot(tone: agente.tone, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(agente.name).gRowTitle()
                Text(agente.engine).gMeta()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
