import SwiftUI

/// Los colores viven en código y no en un catálogo de assets a propósito: `actool`
/// sólo existe con Xcode instalado, y este proyecto tiene que compilar también con
/// SwiftPM a secas (el arnés de macOS). Una sola fuente de verdad, dos destinos.
extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }

    static let gBg           = Color(hex: 0xF4F4F7)
    static let gCard         = Color(hex: 0xFFFFFF)
    static let gInk          = Color(hex: 0x1A1A1E)
    static let gInk2         = Color(hex: 0x6B6E7B)
    static let gInk3         = Color(hex: 0x8A8C96)
    static let gInk4         = Color(hex: 0xA2A4AE)
    static let gSeparator    = Color(hex: 0xEDEDF1)
    static let gFill         = Color(hex: 0xEFEFF3)
    static let gFillStrong   = Color(hex: 0xE9E9EE)
    static let gBubbleAgent  = Color(hex: 0xEDEDF1)
    static let gBubbleUser   = Color(hex: 0xD8DCF4)
    static let gPrimary      = Color(hex: 0x6260C8)
    static let gPrimaryLight = Color(hex: 0x7A79DC)
    static let gPrimaryTint  = Color(hex: 0xEFEEFB)
    static let gDanger       = Color(hex: 0xD9564B)
    static let gDangerTint   = Color(hex: 0xFBEAE8)
    static let gDangerInk    = Color(hex: 0xC4483D)
    static let gGreen        = Color(hex: 0x6AB94E)
    static let gGreenTint    = Color(hex: 0xE8F3E4)
    static let gGreenInk     = Color(hex: 0x3F7A2A)
}

enum Theme {
    enum Radius {
        static let card: CGFloat = 20
        static let bubble: CGFloat = 20
        static let control: CGFloat = 15
        static let chip: CGFloat = 8
        static let icon: CGFloat = 11
        static let pill: CGFloat = 19
        static let sheet: CGFloat = 28
    }

    enum Space {
        static let screenH: CGFloat = 20
        static let cardH: CGFloat = 16
        static let row: CGFloat = 13
        /// Aire para que la píldora de pestañas no tape el final del contenido.
        static let tabBarClearance: CGFloat = 92
        /// La píldora mide 56 y se separa 4 del borde: el compositor va encima de eso.
        static let composerClearance: CGFloat = 68
    }

    /// El primario es degradado, no plano: es lo que hace que "Permitir" se lea
    /// como el único primario de la pantalla.
    static let primaryGradient = LinearGradient(
        colors: [.gPrimaryLight, .gPrimary],
        startPoint: .top, endPoint: .bottom
    )
}

struct GhostyCardStyle: ViewModifier {
    var radius: CGFloat = Theme.Radius.card
    func body(content: Content) -> some View {
        content
            .background(Color.gCard)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.055), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 9, x: 0, y: 6)
    }
}

extension View {
    func ghostyCard(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(GhostyCardStyle(radius: radius))
    }

    /// Separador de 1 px alineado al texto, como en las listas del diseño.
    func ghostySeparator(inset: CGFloat = 0) -> some View {
        overlay(alignment: .bottom) {
            Rectangle().fill(Color.gSeparator)
                .frame(height: 1)
                .padding(.leading, inset)
        }
    }
}
