import SwiftUI

struct FleetView: View {
    let store: any AgentStoring
    var onOpenAgent: (Agent) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Tu flota").gScreenTitle()
                    Spacer()
                    TintedIcon(systemName: "plus", tint: .gInk, background: .gCard, size: 36)
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                }
                .padding(.bottom, 16)

                VStack(spacing: 0) {
                    ForEach(Array(store.agents.enumerated()), id: \.element.id) { i, agente in
                        AgentRow(
                            agent: agente,
                            onStop: { Task { await store.stopTurn() } },
                            onOpen: { onOpenAgent(agente) }
                        )
                        .ghostySeparator(inset: i == store.agents.count - 1 ? .infinity : 61)
                    }
                }
                .padding(.horizontal, Theme.Space.cardH)
                .ghostyCard()

                if !store.deliveredToday.isEmpty {
                    Text("Entregado hoy").gSectionTitle().padding(.top, 26).padding(.bottom, 12)
                    VStack(spacing: 0) {
                        ForEach(Array(store.deliveredToday.enumerated()), id: \.element.id) { i, art in
                            ArtifactRow(artifact: art)
                                .ghostySeparator(inset: i == store.deliveredToday.count - 1 ? .infinity : 51)
                        }
                    }
                    .padding(.horizontal, Theme.Space.cardH)
                    .ghostyCard()
                }
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 8)
        }
    }
}
