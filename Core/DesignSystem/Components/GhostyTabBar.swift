import SwiftUI

enum GhostyTab: String, CaseIterable, Identifiable {
    // ⚠️ Conversaciones YA NO es pestaña (rediseño 2026-09): el historial se abre desde el
    // botón de la cabecera del chat. Su `rawValue` viejo (`conversations`) lo sigue
    // entendiendo el gancho `GHOSTY_TAB`, que abre la hoja del historial.
    case chat, artifacts, connectors, perfil
    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat:       return "Chats"
        case .artifacts:  return "Archivos"
        case .connectors: return "Integraciones"
        case .perfil:     return "Perfil"
        }
    }

    var icon: GhostyStrokeIcon {
        switch self {
        case .chat:       return GhostyIcons.chat
        case .artifacts:  return GhostyIcons.archivos
        case .connectors: return GhostyIcons.integraciones
        case .perfil:     return GhostyIcons.perfil
        }
    }
}

/// La barra flotante oscura del diseño, no `TabView`.
///
/// `TabView` nativo no da fondo de píldora con márgenes, sombra propia ni pestaña
/// activa con relleno. Se puede forzar con `UITabBarAppearance`, pero eso se rompió
/// con el tab bar de iOS 26 — justo la versión que corre aquí.
///
/// Las pestañas —la activa se ensancha con su etiqueta sobre una píldora blanca al 14 %;
/// las demás son sólo icono—, un divisor y, a la DERECHA pegado a Chats, el avatar del
/// agente (abre «Cambiar de agente»). Rediseño estilo WhatsApp, igual que Android.
struct GhostyTabBar: View {
    @Binding var selection: GhostyTab
    /// Qué pestañas se pintan. Quien decide la lista es `RootView`.
    var tabs: [GhostyTab] = GhostyTab.allCases
    /// Pestañas con algo que no has visto. Un punto, no un número.
    var puntos: Set<GhostyTab> = []
    /// El agente actual: su avatar es el primer botón de la barra.
    var agente: Agent?
    /// La hoja del agente está abierta: el avatar se resalta.
    var agenteAbierto = false
    /// Hay algo sin ver en OTRO agente: punto sobre el avatar.
    var puntoEnAgente = false
    var onAgente: () -> Void = {}

    @Namespace private var resaltado

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                boton(tab)
            }

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 28)
                .padding(.horizontal, 4)

            Button(action: onAgente) {
                Group {
                    // Fondo blanco y el fantasma a buen tamaño dentro (no el 66 % de AgentAvatar).
                    ZStack {
                        Circle().fill(Color.white)
                        if let agente {
                            GhostyMascot(tone: agente.tone, height: 34)
                                .offset(y: 2)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .overlay(alignment: .topTrailing) {
                    if puntoEnAgente { punto.offset(x: 1, y: 1) }
                }
                .padding(.horizontal, 6)
                .frame(height: 56)
                .background(agenteAbierto ? Color.white.opacity(0.12) : .clear, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.gPressTab)
            .accessibilityLabel(agente.map { "Agente \($0.name). Cambiar de agente" } ?? "Cambiar de agente")
            .accessibilityIdentifier("tab-agente")
        }
        .padding(6)
        .frame(height: Theme.Space.tabBarHeight)
        .background(Color.gDark, in: RoundedRectangle(cornerRadius: Theme.Radius.tabBar, style: .continuous))
        .ghostyFloatingShadow()
        .padding(.horizontal, Theme.Space.tabBarSide)
    }

    private func boton(_ tab: GhostyTab) -> some View {
        let activa = selection == tab
        let color: Color = activa ? .white : .gTabInactive
        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { selection = tab }
        } label: {
            HStack(spacing: 6) {
                tab.icon.dibujo(color, size: 22)
                    .overlay(alignment: .topTrailing) {
                        if puntos.contains(tab) { punto.offset(x: 3, y: -1) }
                    }
                if activa {
                    Text(tab.label)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(-0.13)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                }
            }
            .padding(.leading, activa ? 16 : 0)
            .padding(.trailing, activa ? 12 : 0)
            .frame(minWidth: activa ? 48 : 44, maxWidth: activa ? nil : .infinity)
            .frame(height: 48)
            .background {
                if activa {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .matchedGeometryEffect(id: "activa", in: resaltado)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.gPressTab)
        .layoutPriority(activa ? 1 : 0)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(activa ? .isSelected : [])
        .accessibilityIdentifier("tab-\(tab.rawValue)")
    }

    /// El aro del color de la barra lo despega del trazo del icono.
    private var punto: some View {
        Circle()
            .fill(Color.gPrimaryLight)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.gDark, lineWidth: 1.5))
    }
}
