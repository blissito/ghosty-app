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
