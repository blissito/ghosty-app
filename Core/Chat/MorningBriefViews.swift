import SwiftUI

/// Lo que escribe gs en el resumen de la mañana, en pedazos: lo de antes de la primera tarjeta,
/// las tarjetas (`## Título`, renglones y quizá `→ Acción sugerida: …`) y el cierre.
struct MorningBriefContent: Equatable {
    struct Card: Equatable, Identifiable {
        let index: Int
        let title: String
        let body: String
        let action: String?
        var id: Int { index }
    }

    var intro: String
    var cards: [Card]
    var outro: String

    /// `nil` si el texto no trae tarjetas: entonces se pinta como cualquier respuesta.
    init?(_ text: String) {
        var intro: [String] = [], cards: [Card] = [], outro: [String] = []
        var title: String?, body: [String] = [], action: String?
        func close() {
            guard let t = title else { return }
            cards.append(Card(index: cards.count, title: t,
                              body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                              action: action))
            title = nil; body = []; action = nil
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                close()
                title = String(trimmed.dropFirst(3))
            } else if title != nil, let a = Self.action(in: trimmed) {
                action = a
            } else if title != nil, Self.isClosing(trimmed) {
                close()
                outro.append(trimmed)
            } else if title != nil {
                body.append(line)
            } else if !cards.isEmpty {
                outro.append(line)
            } else {
                intro.append(line)
            }
        }
        close()
        guard !cards.isEmpty else { return nil }
        self.intro = intro.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.cards = cards
        self.outro = outro.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func action(in line: String) -> String? {
        for p in ["→ Acción sugerida:", "-> Acción sugerida:"] where line.hasPrefix(p) {
            let a = line.dropFirst(p.count).trimmingCharacters(in: .whitespaces)
            return a.isEmpty ? nil : a
        }
        return nil
    }

    private static func isClosing(_ line: String) -> Bool {
        line.lowercased().hasPrefix("eso es todo por hoy")
    }
}

/// Las tarjetas del resumen, como Pulse: pocas, finitas, cada una con su 👍/👎 y su acción.
/// La acción NO se ejecuta aquí: se le pide al agente con un mensaje normal y él pregunta
/// antes de mandar, pagar o borrar, como en cualquier conversación.
struct MorningBriefCards: View {
    let content: MorningBriefContent
    let rating: (Int) -> Int
    let onRate: (_ card: Int, _ rating: Int) -> Void
    let onAction: (_ card: MorningBriefContent.Card, _ action: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !content.intro.isEmpty { GhostyMarkdown(markdown: content.intro) }
            ForEach(content.cards) { card in cardView(card) }
            Text(content.outro.isEmpty ? "Eso es todo por hoy." : content.outro)
                .gMeta().foregroundStyle(Color.gInk3)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .accessibilityIdentifier("resumen-fin")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cardView(_ card: MorningBriefContent.Card) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.gInk)
            if !card.body.isEmpty { GhostyMarkdown(markdown: card.body) }
            HStack(spacing: 0) {
                if let action = card.action {
                    Button { onAction(card, action) } label: {
                        Text(action)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.gPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.gPrimaryTint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("resumen-accion-\(card.index)")
                }
                Spacer(minLength: 8)
                thumb(card, up: true)
                thumb(card, up: false)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.gSeparator, lineWidth: 0.5))
        // `.contain`: con el id puesto directo, tapaba los de los botones de adentro.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("resumen-tarjeta-\(card.index)")
    }

    private func thumb(_ card: MorningBriefContent.Card, up: Bool) -> some View {
        let value = up ? 1 : -1
        let selected = rating(card.index) == value
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy(duration: 0.2)) { onRate(card.index, selected ? 0 : value) }
        } label: {
            Image(systemName: (up ? "hand.thumbsup" : "hand.thumbsdown") + (selected ? ".fill" : ""))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.gPrimary : Color.gInk3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("resumen-\(up ? "up" : "down")-\(card.index)")
        .accessibilityLabel(up ? "Más de esto" : "Menos de esto")
        .accessibilityValue(selected ? "seleccionado" : "")
    }
}

/// La barra de arriba del hilo del resumen: el audio del día («Escúchalo»), «Ajustar» y
/// «Apagar». Apagar es UN toque y se puede deshacer desde el mismo lugar.
struct MorningBriefBar: View {
    let audio: Delivery?
    let onAdjust: () -> Void
    @State private var brief = MorningBriefStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let audio {
                // El nombre del archivo («resumen-2026-10-23.mp3») no le dice nada a nadie.
                ReproductorDeEntrega(entrega: { var e = audio; e.title = "Escúchalo · tu resumen de hoy"; return e }())
            }
            HStack(spacing: 8) {
                Label(brief.brief?.enabled == false ? "Resumen apagado" : (brief.brief?.summary ?? ""),
                      systemImage: "sun.horizon")
                    .gMeta().foregroundStyle(Color.gInk2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Ajustar", action: onAdjust)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.gPrimary)
                    .accessibilityIdentifier("resumen-ajustar")
                let on = brief.brief?.enabled ?? false
                Button(on ? "Apagar" : "Prender") {
                    Task { await brief.update { $0.enabled = !on } }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Color.gInk2 : Color.gPrimary)
                .accessibilityIdentifier(on ? "resumen-apagar" : "resumen-prender")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16).padding(.top, 6)
    }
}
