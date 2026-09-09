import SwiftUI

struct HistoryPane: View {
    let store: any AgentStoring

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.log.isEmpty {
                EmptyState(icon: "clock.arrow.circlepath",
                           title: "Sin historial",
                           detail: "Los turnos cerrados de días anteriores se guardan aquí.")
                    .padding(.top, 60)
            } else {
                Text("Turnos anteriores").gSectionTitle().padding(.bottom, 4)
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
