import SwiftUI

struct UserBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .gBody()
            .lineSpacing(3)
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(Color.gBubbleUser)
            .clipShape(.rect(topLeadingRadius: Theme.Radius.bubble,
                             bottomLeadingRadius: Theme.Radius.bubble,
                             bottomTrailingRadius: 8,
                             topTrailingRadius: Theme.Radius.bubble,
                             style: .continuous))
            .frame(maxWidth: 268, alignment: .trailing)
    }
}

/// La burbuja del agente renderiza **markdown**, no texto plano: lo que la caja
/// manda trae encabezados, listas, tablas y bloques de código, y verlo con los
/// asteriscos crudos es exactamente la queja que originó este trabajo.
struct AgentBubble: View {
    let text: String
    let tools: ToolRun?
    let trailing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GhostyMarkdown(markdown: text)

            if let tools {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.gGreen)
                        .frame(width: 18, height: 18)
                        .overlay {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    Text("Corrió \(tools.count) herramientas").gMeta()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gInk4)
                }
            }

            if let trailing {
                GhostyMarkdown(markdown: trailing)
            }
        }
        .padding(15)
        .background(Color.gBubbleAgent)
        .clipShape(.rect(topLeadingRadius: Theme.Radius.bubble,
                         bottomLeadingRadius: 8,
                         bottomTrailingRadius: Theme.Radius.bubble,
                         topTrailingRadius: Theme.Radius.bubble,
                         style: .continuous))
        .frame(maxWidth: 300, alignment: .leading)
    }
}

/// Los tres puntos. Se anima con opacidad y no con escala para que no salte la
/// altura de la fila mientras el agente piensa.
struct TypingBubble: View {
    @State private var fase = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.gInk4)
                    .frame(width: 6, height: 6)
                    .opacity(fase == i ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.gBubbleAgent)
        .clipShape(Capsule())
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.easeInOut(duration: 0.28)) { fase = (fase + 1) % 3 }
            }
        }
    }
}
