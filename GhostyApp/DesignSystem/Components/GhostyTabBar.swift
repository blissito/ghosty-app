import SwiftUI

enum GhostyTab: String, CaseIterable, Identifiable {
    case chat, fleet, ideas, goals, artifacts, connectors
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .chat:      return "bubble.left"
        case .fleet:     return "square.split.2x1"
        case .ideas:     return "lightbulb"
        case .goals:     return "checkmark.square"
        case .artifacts: return "circle.grid.2x2"
        case .connectors: return "puzzlepiece.extension"
        }
    }
}

/// Píldora flotante propia, no `TabView`.
///
/// `TabView` nativo no da fondo de píldora con márgenes, sombra propia ni pestaña
/// activa con relleno. Se puede forzar con `UITabBarAppearance`, pero eso se rompió
/// con el tab bar de iOS 26 — justo la versión que corre aquí.
struct GhostyTabBar: View {
    @Binding var selection: GhostyTab
    /// Qué pestañas se pintan.
    ///
    /// ⚠️ NO es `allCases`, y ésa es la gracia: una pestaña que existe en el enum pero
    /// todavía no tiene pantalla —o que no aplica a este agente— **no se enseña**. Una
    /// barra con tres de cinco destinos vacíos no se lee como "beta temprana", se lee como
    /// "está roto". Quien decide la lista es `RootView`, que es quien sabe con qué cuenta
    /// se entró.
    var tabs: [GhostyTab] = GhostyTab.allCases
    /// Pestañas con algo que no has visto. Un punto, no un número: cuántos agentes
    /// terminaron no cambia lo que vas a hacer —ir a mirar—, y un contador en una barra
    /// de cinco iconos es ruido que hay que descifrar.
    var puntos: Set<GhostyTab> = []
    @Namespace private var resaltado

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection = tab
                    }
                } label: {
                    ZStack {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.gFillStrong)
                                .matchedGeometryEffect(id: "activa", in: resaltado)
                        }
                        Image(systemName: tab.icon)
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(selection == tab ? Color.gInk : Color.gInk4)
                            .overlay(alignment: .topTrailing) {
                                if puntos.contains(tab) {
                                    Circle()
                                        .fill(Color.gPrimary)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 5, y: -3)
                                }
                            }
                    }
                    // 44 pt de alto mínimo: es el tamaño de toque, no una decisión estética
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        // Altura fija: el toque queda en 44 pt y la píldora no se estira al ZStack.
        .frame(height: 56)
        .background(Color.gCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous))
        .shadow(color: .black.opacity(0.07), radius: 1, x: 0, y: 1)
        .shadow(color: .black.opacity(0.07), radius: 14, x: 0, y: 8)
        .padding(.horizontal, 16)
    }
}
