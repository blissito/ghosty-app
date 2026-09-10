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

    /// Lo que llevas escrito para cada agente. Por agente y no uno solo: si escribes a
    /// dos, lo tecleado no puede saltar de una fila a otra.
    @State private var borradores: [String: String] = [:]

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
        // Entrar a la flota ES verlo: el punto de la pestaña se apaga aquí, no al tocar
        // cada agente. Lo que anunciaba —que alguien terminó— ya está en pantalla.
        .onAppear { store.vistoTodo() }
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
        .contentShape(Rectangle())
        .onTapGesture { store.seleccionar(agente.id) }
    }

    /// Lo último que dijo el agente en su conversación, recortado.
    private func ultimoDicho(_ canal: Canal?) -> String? {
        guard let m = canal?.mensajes.last(where: {
            if case .agent = $0.kind { return true } else { return false }
        }), case .agent(let t, _, _) = m.kind else { return nil }
        let limpio = t.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return limpio.isEmpty ? nil : limpio
    }

    /// Mandarle algo SIN cambiar de conversación. Es lo que convierte esta pantalla en un
    /// puesto de mando: poner a dos a trabajar deja de exigir ir y volver.
    ///
    /// ⚠️ Sin adjuntos a propósito. Adjuntar es del chat, y meterlo aquí sería duplicar
    /// medio compositor —cámara, carrete, archivos, voz— en una fila de una lista.
    @ViewBuilder
    private func pedir(_ agente: Agent, canal: Canal?) -> some View {
        // ⚠️ Mientras trabaja NO se enseña el campo. Encolarlo sería mentir sobre cuándo
        // corre, y mandarlo encima cortaría el turno que ya está en marcha.
        if canal?.trabajando != true {
            HStack(spacing: 8) {
                TextField("Pídele algo…", text: Binding(
                    get: { borradores[agente.id] ?? "" },
                    set: { borradores[agente.id] = $0 }))
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .onSubmit { mandar(a: agente.id) }

                if !(borradores[agente.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { mandar(a: agente.id) } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Theme.primaryGradient, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.gFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.leading, 61)
        }
    }

    private func mandar(a id: String) {
        let texto = (borradores[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texto.isEmpty else { return }
        borradores[id] = ""
        // No cambia de agente: el chip sobre el chat es quien lo enseña trabajando.
        Task { await store.send(texto, a: id) }
    }
}
