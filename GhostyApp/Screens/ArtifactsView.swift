import SwiftUI

struct ArtifactsView: View {
    let store: any AgentStoring
    var onOpenSheet: () -> Void

    @State private var pestana = 0

    var body: some View {
        VStack(spacing: 0) {
            if let agente = store.selectedAgent {
                AgentHeader(agent: agente, onTap: onOpenSheet).padding(.top, 8)
            }

            // Sub-pestañas de verdad, no navegación duplicada: Artefactos y Archivos
            // son dos listas del mismo sitio.
            HStack(spacing: 3) {
                ForEach(["Artefactos", "Archivos"].indices, id: \.self) { i in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pestana = i }
                    } label: {
                        Text(["Artefactos", "Archivos"][i])
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(pestana == i ? Color.gInk : Color.gInk3)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background {
                                if pestana == i {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(Color.gCard)
                                        .shadow(color: .black.opacity(0.09), radius: 2, y: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color.gFillStrong)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 16)

            ScrollView {
                if pestana == 0 && store.artifacts.isEmpty {
                    EmptyState(icon: "circle.grid.2x2",
                               title: "Sin artefactos",
                               detail: "Lo que el agente entregue —documentos, tableros, páginas— queda aquí.")
                        .padding(.top, 60)
                } else if pestana == 0 {
                    VStack(spacing: 0) {
                        ForEach(Array(store.artifacts.enumerated()), id: \.element.id) { i, art in
                            ArtifactRow(artifact: art)
                                .ghostySeparator(inset: i == store.artifacts.count - 1 ? .infinity : 51)
                        }
                    }
                    .padding(.horizontal, Theme.Space.cardH)
                    .ghostyCard()
                    .padding(.horizontal, Theme.Space.screenH)
                    .padding(.top, 16)
                } else {
                    EmptyState(icon: "folder", title: "Sin archivos",
                               detail: "Lo que subas o el agente guarde aparece aquí.")
                        .padding(.top, 60)
                }
            }
        }
    }
}

/// Estado vacío honesto. Las pestañas que no existen se dicen, no se disfrazan con
/// contenido inventado.
struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.gInk4)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.gInk2)
            Text(detail).gMeta().multilineTextAlignment(.center)
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
    }
}
