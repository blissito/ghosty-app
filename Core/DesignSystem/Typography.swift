import SwiftUI

/// Títulos en Poppins (la de la web, `app.css`), cuerpo en la del sistema (SF, pariente de
/// Inter). Nunca tamaños sueltos en las vistas: si un tamaño no está aquí, no existe.
extension Font {
    /// Poppins al peso pedido; escala con el tamaño de texto del sistema.
    static func gDisplay(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        let name = switch weight {
        case .bold, .heavy, .black: "Poppins-Bold"
        case .medium, .regular: "Poppins-Medium"
        default: "Poppins-SemiBold"
        }
        return .custom(name, size: size)
    }
}

extension Font {
    /// Inter (la del cuerpo de la web): el texto del chat. Variable, así que el peso sale
    /// con `.weight()` sobre la misma fuente.
    static func gReading(_ size: CGFloat) -> Font { .custom("Inter", size: size) }
}

extension View {
    /// Título de pantalla — "Tu flota"
    func gScreenTitle() -> some View {
        font(.gDisplay(26, .bold))
            .tracking(-0.4)
            .foregroundStyle(Color.gInk)
    }

    /// Encabezado de sección — "En curso", "Hoy", "Historial"
    func gSectionTitle() -> some View {
        font(.gDisplay(17))
            .tracking(-0.1)
            .foregroundStyle(Color.gInk)
    }

    /// Nombre de agente o de fila
    func gRowTitle() -> some View {
        font(.gDisplay(15.5))
            .tracking(-0.1)
            .foregroundStyle(Color.gInk)
    }

    /// Pregunta de la tarjeta de permiso
    func gCardTitle() -> some View {
        font(.gDisplay(16.5))
            .tracking(-0.1)
            .foregroundStyle(Color.gInk)
    }

    /// Cuerpo de burbuja y de tarjeta
    func gBody() -> some View {
        font(.gReading(16))
            .foregroundStyle(Color.gInk)
    }

    /// Subtítulo de fila
    func gMeta() -> some View {
        font(.system(size: 14))
            .foregroundStyle(Color.gInk3)
    }

    /// Hora, contadores, texto terciario
    func gCaption() -> some View {
        font(.system(size: 13))
            .foregroundStyle(Color.gInk4)
    }

    /// Etiqueta de botón
    func gButtonLabel() -> some View {
        font(.gDisplay(15.5))
    }

    /// Chip de estado
    func gChip() -> some View {
        font(.system(size: 12.5, weight: .semibold))
    }

    /// Cronómetros y montos: cifras de ancho fijo para que no bailen
    func gMono(size: CGFloat = 13, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight, design: .default).monospacedDigit())
    }

    /// Identificadores de código dentro de prosa
    func gCode() -> some View {
        font(.system(size: 14, design: .monospaced))
    }
}
