import SwiftUI

/// El panel único del brief de la mañana (gs `/me/digest`): prendido, «Con voz», hora y días. Cada
/// cambio se guarda en el acto, como los ajustes de iOS. Se abre desde Perfil.
struct DailyDigestSheet: View {
    @State private var store = DailyDigestStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pickingPauseDay = false
    @State private var pauseDay = Date()

    var body: some View {
        NavigationStack {
            Form {
                if let d = store.digest {
                    Section {
                        Toggle("Brief de la mañana", isOn: enabledBinding)
                            .tint(Color.gPrimary)
                            .accessibilityIdentifier("brief-toggle")
                    } footer: {
                        Text("Cada mañana tu agente te deja en el chat lo que tienes en curso y lo que te necesita. Si no hay nada que contar, no te avisa. No usa tu saldo.")
                    }
                    if d.enabled {
                        pauseSection(d)
                        Section {
                            Toggle("Con voz", isOn: binding(\.voice))
                                .tint(Color.gPrimary)
                                .accessibilityIdentifier("brief-voz")
                            DatePicker("Hora", selection: horaBinding(d), displayedComponents: .hourAndMinute)
                                .accessibilityIdentifier("brief-hora")
                            Picker("Días", selection: binding(\.days)) {
                                Text("Todos los días").tag(DailyDigest.everyDay)
                                Text("Lunes a viernes").tag(DailyDigest.weekdays)
                                if d.days != DailyDigest.weekdays && d.days != DailyDigest.everyDay {
                                    Text("Personalizado").tag(d.days)
                                }
                            }
                            .accessibilityIdentifier("brief-dias")
                        } footer: {
                            Text(d.voice ? "Con voz, el brief trae un audio para escucharlo. Nunca se reproduce solo." : "Sólo texto.")
                        }
                    }
                    if let e = store.error {
                        Section { Text(e).foregroundStyle(Color.gDangerInk) }
                    }
                } else if let e = store.error {
                    Section { Text(e).foregroundStyle(Color.gDangerInk) }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.gBg)
            .navigationTitle("Brief de la mañana")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }.accessibilityIdentifier("brief-listo")
                }
            }
        }
        .presentationBackground(Color.gBg)
        .task { await store.load(force: true) }
        .sheet(isPresented: $pickingPauseDay) {
            NavigationStack {
                DatePicker("Vuelve el", selection: $pauseDay, in: pauseRange, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .navigationTitle("¿Qué día vuelve?")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { pickingPauseDay = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Pausar") {
                                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: pauseDay)).day ?? 1
                                pause(days: days)
                                pickingPauseDay = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Prender o apagar quita la pausa, igual que en gs.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.digest?.enabled ?? true },
            set: { on in Task { await store.update { $0.enabled = on; $0.pausedUntil = nil } } }
        )
    }

    /// «En pausa · vuelve el…» con «Reanudar», o las opciones. La pausa regresa sola.
    @ViewBuilder
    private func pauseSection(_ d: DailyDigest) -> some View {
        if let until = d.pausedUntil {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("En pausa")
                        Text("Vuelve el \(DailyDigest.pauseLabel(until)).").font(.footnote).foregroundStyle(Color.gInk3)
                    }
                    Spacer()
                    Button("Reanudar") { Task { await store.update { $0.pausedUntil = nil } } }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("brief-reanudar")
                }
            }
        } else {
            Section("Pausar") {
                Menu {
                    Button("3 días") { pause(days: 3) }
                    Button("1 semana") { pause(days: 7) }
                    Button("2 semanas") { pause(days: 14) }
                    Button("Hasta una fecha…") {
                        pauseDay = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
                        pickingPauseDay = true
                    }
                } label: {
                    Text("Pausar unos días").frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("brief-pausar")
            }
        }
    }

    private func pause(days: Int) {
        let day = DailyDigest.localDay(after: days)
        Task { await store.update { $0.pausedUntil = day } }
    }

    /// Mañana a 90 días, lo que acepta gs.
    private var pauseRange: ClosedRange<Date> {
        let cal = Calendar.current
        let today = Date()
        return (cal.date(byAdding: .day, value: 1, to: today) ?? today)...(cal.date(byAdding: .day, value: 90, to: today) ?? today)
    }

    private func binding<T: Equatable>(_ k: WritableKeyPath<DailyDigest, T>) -> Binding<T> {
        Binding(
            get: { store.digest?[keyPath: k] ?? DailyDigest()[keyPath: k] },
            set: { v in Task { await store.update { $0[keyPath: k] = v } } }
        )
    }

    private func horaBinding(_ d: DailyDigest) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: d.hour, minute: d.minute, second: 0, of: Date()) ?? Date() },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                Task { await store.update { $0.hour = c.hour ?? 7; $0.minute = c.minute ?? 30 } }
            }
        )
    }
}
