import SwiftUI

/// El panel único del brief de la mañana (gs `/me/digest`): prendido, «Con voz», hora y días. Cada
/// cambio se guarda en el acto, como los ajustes de iOS. Se abre desde Perfil.
struct DailyDigestSheet: View {
    @State private var store = DailyDigestStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let d = store.digest {
                    Section {
                        Toggle("Brief de la mañana", isOn: binding(\.enabled))
                            .tint(Color.gPrimary)
                            .accessibilityIdentifier("brief-toggle")
                    } footer: {
                        Text("Cada mañana tu agente te deja en el chat lo que tienes en curso y lo que te necesita. Si no hay nada que contar, no te avisa. No usa tu saldo.")
                    }
                    if d.enabled {
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
