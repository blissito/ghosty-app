import SwiftUI

/// Tipografía del sistema (SF). Nunca tamaños sueltos en las vistas: si un tamaño
/// no está aquí, es que no existe en el diseño.
extension View {
    /// Título de pantalla — "Tu flota"
    func gScreenTitle() -> some View {
        font(.system(size: 27, weight: .bold, design: .default))
            .tracking(-0.7)
            .foregroundStyle(Color.gInk)
    }

    /// Encabezado de sección — "En curso", "Hoy", "Historial"
    func gSectionTitle() -> some View {
        font(.system(size: 17, weight: .semibold))
            .tracking(-0.2)
            .foregroundStyle(Color.gInk)
    }

    /// Nombre de agente o de fila
    func gRowTitle() -> some View {
        font(.system(size: 16, weight: .semibold))
            .tracking(-0.15)
            .foregroundStyle(Color.gInk)
    }

    /// Pregunta de la tarjeta de permiso
    func gCardTitle() -> some View {
        font(.system(size: 17, weight: .semibold))
            .tracking(-0.2)
            .foregroundStyle(Color.gInk)
    }

    /// Cuerpo de burbuja y de tarjeta
    func gBody() -> some View {
        font(.system(size: 16))
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
        font(.system(size: 16, weight: .semibold))
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
