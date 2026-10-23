import SwiftUI

/// Los ajustes del resumen de la mañana: prendido/apagado, hora, días, qué agente lo escribe y
/// «Probar ahora». Se abre desde Perfil y desde la barra del hilo del resumen («Ajustar»).
struct MorningBriefSheet: View {
    let store: LiveAgentStore
    @State private var brief = MorningBriefStore.shared
    @State private var running = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let b = brief.brief {
                    Section {
                        Toggle("Resumen de la mañana", isOn: binding(\.enabled))
                            .tint(Color.gPrimary)
                            .accessibilityIdentifier("resumen-toggle")
                    } footer: {
                        Text("Tu agente revisa tu correo, tu agenda y tus pendientes y te deja de 3 a 5 tarjetas con un audio. Si no hay nada nuevo, no te avisa. Usa tu saldo como cualquier otro mensaje.")
                    }
                    if !b.hasSources {
                        Section {
                            Button { dismiss(); store.requestedTab = .perfil; store.integracionesPedidas = true } label: {
                                Label("Conecta tu correo para un mejor resumen", systemImage: "envelope.badge")
                                    .foregroundStyle(Color.gPrimary)
                            }
                            .accessibilityIdentifier("resumen-conectar")
                        } footer: {
                            Text("Sin correo ni agenda, tu agente usa lo que ya sabe: tus turnos programados, tus pendientes y lo que te preguntó.")
                        }
                    }
                    if b.enabled {
                        Section {
                            DatePicker("Hora", selection: horaBinding(b), displayedComponents: .hourAndMinute)
                                .accessibilityIdentifier("resumen-hora")
                            Picker("Días", selection: binding(\.days)) {
                                Text("Lunes a viernes").tag(MorningBrief.weekdays)
                                Text("Todos los días").tag(MorningBrief.everyDay)
                                if b.days != MorningBrief.weekdays && b.days != MorningBrief.everyDay {
                                    Text("Personalizado").tag(b.days)
                                }
                            }
                            .accessibilityIdentifier("resumen-dias")
                            if agentes.count > 1 {
                                Picker("Lo escribe", selection: binding(\.agentId)) {
                                    Text("Tu agente principal (\(nombrePrincipal))").tag(String?.none)
                                    ForEach(agentes, id: \.id) { a in Text(a.name).tag(Optional(a.id)) }
                                }
                                .accessibilityIdentifier("resumen-agente")
                            }
                        }
                        Section {
                            Button {
                                running = true
                                Task {
                                    if let r = await brief.runNow() {
                                        dismiss()
                                        store.open(agent: r.agentId, session: r.sessionId, fallback: nil)
                                    }
                                    running = false
                                }
                            } label: {
                                HStack {
                                    Text(running ? "Preparando…" : "Probar ahora")
                                    Spacer()
                                    if running { ProgressView() }
                                }
                            }
                            .disabled(running)
                            .accessibilityIdentifier("resumen-probar")
                        }
                    }
                    if let e = brief.error {
                        Section { Text(e).foregroundStyle(Color.gDangerInk) }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.gBg)
            .navigationTitle("Resumen de la mañana")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }.accessibilityIdentifier("resumen-listo")
                }
            }
        }
        .presentationBackground(Color.gBg)
        .task { await brief.load(force: true) }
    }

    private var nombrePrincipal: String {
        store.agents.first { DefaultAgentStore.shared.isDefault($0.id) }?.name ?? "automático"
    }

    /// Sólo los tuyos: un agente compartido contigo no lee tu correo.
    private var agentes: [Agent] {
        store.agents.filter { $0.compartidoPor == nil }
    }

    /// Cada cambio se guarda en el acto, como los ajustes de iOS: no hay botón «Guardar».
    private func binding<T: Equatable>(_ k: WritableKeyPath<MorningBrief, T>) -> Binding<T> {
        Binding(
            get: { brief.brief?[keyPath: k] ?? MorningBrief()[keyPath: k] },
            set: { v in Task { await brief.update { $0[keyPath: k] = v } } }
        )
    }

    private func horaBinding(_ b: MorningBrief) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: b.hour, minute: b.minute, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                Task { await brief.update { $0.hour = c.hour ?? 8; $0.minute = c.minute ?? 0 } }
            }
        )
    }
}
