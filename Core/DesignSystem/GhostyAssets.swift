import SwiftUI

/// Carga los PNG de la mascota funcione donde funcione: con SwiftPM salen de
/// `Bundle.module`, dentro de la app de Xcode salen de `Bundle.main`.
enum GhostyAssets {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
}

/// Un fantasma del tono que le toque, con la proporción del logo (120×144).
struct GhostyMascot: View {
    let tone: AgentTone
    var height: CGFloat

    var body: some View {
        Image(tone.assetName, bundle: GhostyAssets.bundle)
            .resizable()
            .interpolation(.high)
            .aspectRatio(120.0 / 144.0, contentMode: .fit)
            .frame(height: height)
    }
}

/// El avatar redondo del agente (barra de pestañas, cabecera, hojas).
///
/// El lila es el de Ghosty y tiene su retrato (`ghosty-avatar`, del diseño); los otros
/// tonos no tienen retrato todavía, así que va su fantasma completo sobre blanco.
struct AgentAvatar: View {
    let tone: AgentTone
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.white)
            if tone == .lila {
                Image("ghosty-avatar", bundle: GhostyAssets.bundle)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                GhostyMascot(tone: tone, height: size * 0.66)
                    .offset(y: size * 0.04)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
