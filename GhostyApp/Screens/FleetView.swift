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

    /// La tarjeta de un agente: quién es y qué hace, lo último que dijo, y por dónde
    /// pedirle algo. Los tres pisos alineados con el texto, no con la mascota.
    private func fila(_ agente: Agent, ultima: Bool) -> some View {
        let canal = store.canales[agente.id]
        return VStack(alignment: .leading, spacing: 9) {
            cabecera(agente, canal: canal)
            if let dicho = ultimoDicho(canal) {
                Text(dicho)
                    .gMeta()
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.sangria)
            }
            pedir(agente, canal: canal)
        }
        .padding(.vertical, Theme.Space.row)
        .ghostySeparator(inset: ultima ? .infinity : 0)
    }

    /// Lo que ocupa la mascota más su hueco: los pisos de abajo se alinean con el nombre.
    private static let sangria: CGFloat = 61

    private func cabecera(_ agente: Agent, canal: Canal?) -> some View {
        HStack(spacing: 13) {
            GhostyMascot(tone: agente.tone, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(agente.name).gRowTitle()
                // ⚠️ `StatusLine` es de la casa y ya sabe pintar los tres estados —incluido
                // el punto rojo de "espera tu visto bueno"—. La flota se había inventado los
                // suyos, así que el mismo agente se veía distinto aquí y en la cabecera del
                // chat.
                HStack(spacing: 6) {
                    StatusLine(status: agente.status)
                    // El reloj sí es de aquí: es lo único que `AgentStatus` no lleva.
                    // Con varias conversaciones a la vez, el reloj solo no basta: hay
                    // que decir CUÁNTAS. "2 en curso · 1:04" es la información nueva.
                    if let canal, let vivo = canal.enCurso.last {
                        Text(canal.enCurso.count > 1
                             ? "\(canal.enCurso.count) en curso · \(vivo.transcurrido)"
                             : vivo.transcurrido)
                            .gMono()
                            .foregroundStyle(Color.gInk4)
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Detener sin ir a su conversación: si lo dejaste trabajando, pararlo no
            // debería obligarte a volver a donde estabas.
            // El mismo botón de detener que dibuja `AgentRow`: cuadrado oscuro con el
            // stop blanco. Un icono distinto para la misma acción se lee como otra cosa.
            if let canal, canal.trabajando {
                Button { store.detenerTodo(canal) } label: {
                    RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
                        .fill(Color.gInk)
                        .frame(width: 34, height: 34)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2.5).fill(Color.white)
                                .frame(width: 9, height: 9)
                        }
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
        guard let m = canal?.hilos.last?.mensajes.last(where: {
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
                    .gBody()
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .onSubmit { mandar(a: agente.id) }

                if !(borradores[agente.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { mandar(a: agente.id) } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Theme.primaryGradient, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.cardH - 4)
            .padding(.vertical, 8)
            .background(Color.gFill,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .padding(.leading, Self.sangria)
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
