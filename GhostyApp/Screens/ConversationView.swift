import SwiftUI

struct ConversationView: View {
    let store: LiveAgentStore
    var onOpenSheet: () -> Void
    var onConectarAgente: () -> Void

    @State private var borrador = ""
    @FocusState private var escribiendo: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let agente = store.selectedAgent {
                AgentHeader(agent: agente, onTap: { escribiendo = false; onOpenSheet() })
                    .padding(.top, 8)
                    .padding(.bottom, 14)
            }

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if store.messages.isEmpty {
                            EmptyState(
                                icon: "bubble.left.and.text.bubble.right",
                                title: "Pídele algo",
                                detail: "Este hilo habla con tu caja de verdad. Lo que contesta se pinta como markdown."
                            )
                            .padding(.top, 90)
                        }
                        ForEach(store.messages) { mensaje in
                            fila(mensaje).id(mensaje.id)
                        }
                        Color.clear.frame(height: 1).id("fondo")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded { escribiendo = false }
                )
                .onChange(of: store.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { scroll.scrollTo("fondo", anchor: .bottom) }
                }
                // También al crecer el ÚLTIMO mensaje: la respuesta llega en trozos y
                // sin esto el texto nuevo queda fuera de vista mientras se escribe.
                .onChange(of: textoDelUltimo) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) { scroll.scrollTo("fondo", anchor: .bottom) }
                }
            }

            compositor
        }
    }

    private var textoDelUltimo: Int {
        guard case .agent(let t, _, _) = store.messages.last?.kind else { return 0 }
        return t.count
    }

    @ViewBuilder
    private func fila(_ mensaje: Message) -> some View {
        switch mensaje.kind {
        case .user(let t):
            HStack { Spacer(minLength: 40); UserBubble(text: t) }
        case .agent(let t, let tools, let trailing):
            HStack { AgentBubble(text: t, tools: tools, trailing: trailing); Spacer(minLength: 30) }
        case .prCard(let card):
            HStack {
                PRCard(card: card,
                       onApprove:        { Task { await store.respondToPR(card, approve: true) } },
                       onRequestChanges: { Task { await store.respondToPR(card, approve: false) } })
                Spacer(minLength: 30)
            }
        case .typing:
            HStack { TypingBubble(); Spacer() }
        }
    }

    /// El compositor sólo trae controles que hacen algo.
    ///
    /// Antes tenía un clip y un micrófono que no hacían nada: la API de la caja
    /// recibe `content` y punto —ni adjuntos ni audio—, así que dibujarlos era
    /// prometer lo que no hay. El `+` sí abre lo que de verdad se puede hacer.
    private var compositor: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Button {
                        store.nuevaConversacion()
                    } label: {
                        Label("Nueva conversación", systemImage: "arrow.counterclockwise")
                    }

                    if store.agents.count > 1 {
                        Menu {
                            ForEach(store.agents) { a in
                                Button {
                                    escribiendo = false
                                    store.seleccionar(a.id)
                                } label: {
                                    if a.id == store.selectedAgentID {
                                        Label(a.name, systemImage: "checkmark")
                                    } else {
                                        Text(a.name)
                                    }
                                }
                            }
                        } label: {
                            Label("Cambiar de agente", systemImage: "arrow.left.arrow.right")
                        }
                    }

                    Divider()

                    Button {
                        escribiendo = false
                        onConectarAgente()
                    } label: {
                        Label("Conectar otro agente", systemImage: "plus.circle")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.gInk3)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }

                TextField("Mensaje", text: $borrador, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .lineLimit(1...4)
                    .focused($escribiendo)
                    .submitLabel(.send)
                    .onSubmit(enviar)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Listo") { escribiendo = false }
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.gPrimary)
                        }
                    }

                Button(action: enviar) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(borrador.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? AnyShapeStyle(Color.gInk4.opacity(0.45))
                                    : AnyShapeStyle(Theme.primaryGradient))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(borrador.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(Color.gCard)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func enviar() {
        let texto = borrador
        borrador = ""
        Task { await store.send(texto) }
    }
}
