import SwiftUI

struct ActivityPane: View {
    let store: any AgentStoring

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let turno = store.currentTurn {
                SectionHeader(title: "En curso").padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        TintedIcon(systemName: "chevron.left.forwardslash.chevron.right",
                                   tint: .gPrimary, background: .gPrimaryTint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(turno.title).font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.gInk)
                            Text(turno.totalSteps > 0
                                 ? "\(turno.detail) · paso \(turno.step) de \(turno.totalSteps)"
                                 : turno.detail)
                                .gMeta().fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button { Task { await store.stopTurn() } } label: {
                            RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
                                .fill(Color.gInk)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 2.5).fill(.white)
                                        .frame(width: 9, height: 9)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    TurnProgress(turn: turno)
                }
                .padding(15)
                .ghostyCard()
                .padding(.bottom, 24)
            }

            if store.log.isEmpty && store.currentTurn == nil {
                EmptyState(icon: "waveform.path.ecg",
                           title: "Sin actividad todavía",
                           detail: "Cuando el agente trabaje, aquí queda lo que hizo y a qué hora.")
                    .padding(.top, 50)
            } else if !store.log.isEmpty {
                Text("Hoy").gSectionTitle().padding(.bottom, 4)
                VStack(spacing: 0) {
                    ForEach(Array(store.log.enumerated()), id: \.element.id) { i, e in
                        LogRow(entry: e)
                            .ghostySeparator(inset: i == store.log.count - 1 ? .infinity : 44)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.screenH)
    }
}
