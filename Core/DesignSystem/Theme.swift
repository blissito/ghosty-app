import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Los colores viven en código y no en un catálogo de assets a propósito: `actool`
/// sólo existe con Xcode instalado, y este proyecto tiene que compilar también con
/// SwiftPM a secas (el arnés de macOS). Una sola fuente de verdad, dos destinos.
///
/// La paleta es la del diseño de Brenda (`Ghosty App.dc.html`, 2026-09): clara, sin
/// sombras pesadas y con bordes finos. El prototipo sólo define el modo claro; el oscuro
/// se deriva aquí (hoy la app fuerza claro con `UIUserInterfaceStyle`, pero los tokens ya
/// están listos para cuando se quite).
extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Un color que cambia con el modo claro/oscuro del sistema.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { rasgos in
            UIColor(hexRGB: rasgos.userInterfaceStyle == .dark ? dark : light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { apariencia in
            let oscuro = apariencia.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hexRGB: oscuro ? dark : light)
        })
        #else
        self.init(hex: light)
        #endif
    }

    // MARK: Superficies
    // ⚠️ Paleta OFICIAL de ghosty.studio (`app/app.css`) desde el 2026-09-29, la misma que
    // Android: brand #8483E0, dark #191A20, metal #4B5563, irongray #81838E, outlines
    // #E1E3E7, surfaceThree #F6F6FA, danger #ED695F. El cuerpo de la app es BLANCO.
    static let gBg           = Color(light: 0xFFFFFF, dark: 0x0E0E12)
    static let gCard         = Color(light: 0xFFFFFF, dark: 0x1C1B22)
    /// La tarjeta al presionarla (`style-active` del prototipo).
    static let gCardPressed  = Color(light: 0xFAFAFD, dark: 0x23222A)
    /// Encabezado de tabla y cajitas de cita dentro de una tarjeta.
    static let gCardSunken   = Color(light: 0xF6F6FA, dark: 0x17161C)
    /// La superficie oscura: barra de pestañas, toast, tarjeta del plan, botón de enviar.
    /// En modo oscuro se aclara un poco para despegarse del fondo.
    static let gDark         = Color(light: 0x191A20, dark: 0x2A2933)
    /// Texto secundario sobre `gDark`.
    static let gDarkInk2     = Color(hex: 0xA3A2B0)
    /// Icono de pestaña inactiva sobre `gDark`.
    static let gTabInactive  = Color(hex: 0x8E8D9C)

    // MARK: Tinta
    static let gInk          = Color(light: 0x191A20, dark: 0xF2F1F6)
    /// Texto de cuerpo un punto más suave (viñetas, pasos).
    static let gInkBody      = Color(light: 0x2A2933, dark: 0xDCDBE3)
    static let gInk2         = Color(light: 0x4B5563, dark: 0xA3A2B0)
    static let gInk3         = Color(light: 0x81838E, dark: 0x8E8D9C)
    static let gInk4         = Color(light: 0xB6B6BA, dark: 0x6C6B7A)
    /// Chevrones de fila.
    static let gChevron      = Color(light: 0xB9B8C6, dark: 0x5E5D6B)

    // MARK: Bordes y rellenos
    /// El borde fino de tarjetas y compositor.
    static let gSeparator    = Color(light: 0xE1E3E7, dark: 0x2C2B34)
    /// La línea entre filas de una lista.
    static let gHairline     = Color(light: 0xE9EBEF, dark: 0x26252D)
    static let gFill         = Color(light: 0xF6F6FA, dark: 0x26252D)
    /// Agarradera de hoja, interruptor apagado, aro de paso pendiente.
    static let gFillStrong   = Color(light: 0xE1E3E7, dark: 0x3A3943)
    static let gBubbleAgent  = Color(light: 0xF0F0F4, dark: 0x24232B)
    /// ⚠️ Tinte, no el morado lleno del diseño: la burbuja con texto blanco llega con el
    /// chat nuevo (fase 3). Hasta entonces la tinta de la burbuja es `gInk`.
    static let gBubbleUser   = Color(light: 0xEEECFD, dark: 0x2E2A55)

    // MARK: Primario (plano, sin degradado)
    static let gPrimary      = Color(light: 0x8483E0, dark: 0x8B7DF2)
    static let gPrimaryLight = Color(light: 0xAEADEF, dark: 0xA89DF5)
    static let gPrimaryPressed = Color(light: 0x6E6DCC, dark: 0x6F60E0)
    static let gPrimaryTint  = Color(light: 0xF5F5FC, dark: 0x2A2650)
    /// Fondo de la fila seleccionada en una hoja.
    static let gPrimaryWash  = Color(light: 0xF5F5FC, dark: 0x24213F)
    /// El aro de la mascota en el chat vacío.
    static let gPrimaryRing  = Color(light: 0xECECFB, dark: 0x2A2650)
    /// La insignia «Pro» sobre la tarjeta oscura.
    static let gLavender     = Color(hex: 0xC9C2FF)

    // MARK: Estados
    static let gDanger       = Color(light: 0xED695F, dark: 0xFF6B6B)
    static let gDangerTint   = Color(light: 0xFDECEC, dark: 0x3A1C1E)
    static let gDangerInk    = Color(light: 0xD2524A, dark: 0xFF8A8A)
    static let gGreen        = Color(light: 0x1E9E5A, dark: 0x3CCB7F)
    static let gGreenTint    = Color(light: 0xE3F5EA, dark: 0x16301F)
    static let gGreenInk     = Color(light: 0x1E9E5A, dark: 0x5FD896)

    // La paleta oficial de la web (gs `app.css`): mismos nombres, mismos hex.
    static let gBird         = Color(hex: 0xEDC75A)
    static let gSky          = Color(hex: 0x76D3CB)
    static let gCloud        = Color(hex: 0x8AD7C9)
    static let gGrass        = Color(hex: 0x7FBE60)
    static let gLime         = Color(hex: 0xBFDD78)
    static let gSalmon       = Color(hex: 0xE4AE8E)
    static let gBrand        = Color(hex: 0x9A99EA)
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hexRGB h: UInt32) {
        self.init(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                  blue: CGFloat(h & 0xFF) / 255, alpha: 1)
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(hexRGB h: UInt32) {
        self.init(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                  blue: CGFloat(h & 0xFF) / 255, alpha: 1)
    }
}
#endif

enum Theme {
    /// Radios del diseño: 12 (botoncitos), 14–16 (campos, tarjetas del hilo), 18 (listas),
    /// 20 (sugerencias, burbuja), 22 (tarjeta del plan), 28 (compositor), 34 (barra y hojas).
    enum Radius {
        static let card: CGFloat = 20
        static let bubble: CGFloat = 20
        static let control: CGFloat = 14
        static let chip: CGFloat = 12
        static let icon: CGFloat = 10
        static let pill: CGFloat = 22
        static let list: CGFloat = 18
        static let threadCard: CGFloat = 16
        static let plan: CGFloat = 22
        static let composer: CGFloat = 28
        static let sheet: CGFloat = 34
        static let tabBar: CGFloat = 34
    }

    enum Space {
        static let screenH: CGFloat = 18
        static let cardH: CGFloat = 16
        static let row: CGFloat = 13
        /// La barra flotante: 68 de alto, a 28 del borde de la pantalla y 12 de los lados.
        static let tabBarHeight: CGFloat = 68
        static let tabBarBottom: CGFloat = 28
        static let tabBarSide: CGFloat = 12
        /// Aire para que la barra no tape el final de una lista, medido desde el borde
        /// SEGURO (en un iPhone con indicador de inicio, 34 pt). `RootView` lo recalcula
        /// con el borde real; éste es el valor de un iPhone moderno.
        static let tabBarClearance: CGFloat = 74
        /// El compositor va 10 pt encima de la barra.
        static let composerClearance: CGFloat = 72
    }

    /// Sombras del diseño, en CSS: `0 8px 24px rgba(20,16,50,.28)` (barra),
    /// `0 4px 16px rgba(20,16,50,.05)` (compositor), `0 4px 12px rgba(91,75,214,.35)`
    /// (botón primario redondo). El radio de SwiftUI es la mitad del blur de CSS.
    enum Shadow {
        static let tinta = Color(hex: 0x141032)
        static let morado = Color(hex: 0x5B4BD6)
    }

    /// Se llamaba así cuando el primario era degradado. El diseño nuevo es plano: se
    /// conserva el nombre para no tocar a todos los que lo usan.
    static let primaryGradient = LinearGradient(
        colors: [.gPrimary, .gPrimary],
        startPoint: .top, endPoint: .bottom
    )
}

/// Tarjeta del diseño: blanca, con borde fino y SIN sombra.
struct GhostyCardStyle: ViewModifier {
    var radius: CGFloat = Theme.Radius.card
    var borde: Bool = true
    func body(content: Content) -> some View {
        content
            .background(Color.gCard)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if borde {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.gSeparator, lineWidth: 1)
                }
            }
    }
}

extension View {
    func ghostyCard(radius: CGFloat = Theme.Radius.card, borde: Bool = true) -> some View {
        modifier(GhostyCardStyle(radius: radius, borde: borde))
    }

    /// Separador de 1 px alineado al texto, como en las listas del diseño.
    func ghostySeparator(inset: CGFloat = 0) -> some View {
        overlay(alignment: .bottom) {
            Rectangle().fill(Color.gHairline)
                .frame(height: 1)
                .padding(.leading, inset)
        }
    }

    /// La sombra de la barra flotante.
    func ghostyFloatingShadow() -> some View {
        shadow(color: Theme.Shadow.tinta.opacity(0.28), radius: 12, x: 0, y: 8)
    }

    /// La sombra suave del compositor.
    func ghostySoftShadow() -> some View {
        shadow(color: Theme.Shadow.tinta.opacity(0.05), radius: 8, x: 0, y: 4)
    }

    /// El halo del botón primario redondo (micrófono).
    func ghostyPrimaryShadow() -> some View {
        shadow(color: Theme.Shadow.morado.opacity(0.35), radius: 6, x: 0, y: 4)
    }
}
