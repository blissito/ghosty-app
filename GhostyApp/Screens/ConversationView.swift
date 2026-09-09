import SwiftUI

struct ConversationView: View {
    let store: any AgentStoring
    var onOpenSheet: () -> Void

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

    private var compositor: some View {
        HStack(spacing: 10) {
            TintedIcon(systemName: "paperclip", tint: .gInk3, background: .gCard, size: 46)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 3)

            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.gInk3)
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
                if borrador.trimmingCharacters(in: .whitespaces).isEmpty {
                    Image(systemName: "mic")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.gInk3)
                } else {
                    Button(action: enviar) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Theme.primaryGradient)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
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
