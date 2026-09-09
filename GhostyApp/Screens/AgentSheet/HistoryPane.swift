import SwiftUI

/// Los turnos de días anteriores. La misma bitácora que Actividad, sin los de hoy.
struct HistoryPane: View {
    let store: LiveAgentStore

    private var anteriores: [TurnRecord] {
        let cal = Calendar.current
        return store.bitacora.records.filter {
            $0.agentID == store.selectedAgentID && !cal.isDateInToday($0.startedAt)
        }
    }

    private var porDia: [(dia: Date, turnos: [TurnRecord])] {
        let cal = Calendar.current
        let grupos = Dictionary(grouping: anteriores) { cal.startOfDay(for: $0.startedAt) }
        return grupos.sorted { $0.key > $1.key }.map { (dia: $0.key, turnos: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if anteriores.isEmpty {
                EmptyState(icon: "clock.arrow.circlepath",
                           title: "Sin historial",
                           detail: "Los turnos de días anteriores se guardan aquí.")
                    .padding(.top, 60)
            } else {
                ForEach(porDia, id: \.dia) { grupo in
                    Text(grupo.dia.formatted(.dateTime.weekday(.wide).day().month()))
                        .gSectionTitle()
                        .padding(.top, 8).padding(.bottom, 10)

                    VStack(spacing: 0) {
                        ForEach(Array(grupo.turnos.enumerated()), id: \.element.id) { i, r in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(r.prompt).font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.gInk).lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("\(r.elapsedText) · \(r.totalTokens) tokens").gMeta()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(r.startedAt.formatted(date: .omitted, time: .shortened))
                                    .gMono(size: 12.5, weight: .regular).foregroundStyle(Color.gInk4)
                            }
                            .padding(.vertical, Theme.Space.row)
                            .ghostySeparator(inset: i == grupo.turnos.count - 1 ? .infinity : 0)
                        }
                    }
                    .padding(.bottom, 14)
                }
            }
        }
        .padding(.horizontal, Theme.Space.screenH)
    }
}
