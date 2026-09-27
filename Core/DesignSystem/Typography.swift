import SwiftUI

/// La tipografía del diseño es la DEL SISTEMA (SF), como el prototipo
/// (`-apple-system`). Poppins e Inter salieron con el rediseño de 2026-09; los nombres
/// `gDisplay`/`gReading` se conservan para no tocar a todos los que los usan.
/// Nunca tamaños sueltos en las vistas: si un tamaño no está aquí, no existe.
extension Font {
    /// Títulos y etiquetas con peso. Escala con el tamaño de texto del sistema.
    static func gDisplay(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    /// El cuerpo del chat.
    static func gReading(_ size: CGFloat) -> Font { .system(size: size) }
}

extension View {
    /// Título de pantalla — «Chats», «Archivos» (800 32, −0.03 em)
    func gScreenTitle() -> some View {
        font(.system(size: 32, weight: .heavy))
            .tracking(-0.96)
            .foregroundStyle(Color.gInk)
    }

    /// Subtítulo bajo el título de pantalla (400 14)
    func gScreenSubtitle() -> some View {
        font(.system(size: 14))
            .foregroundStyle(Color.gInk2)
    }

    /// Encabezado de sección en mayúsculas — «HOY», «USO POR AGENTE» (600 12, +0.05 em)
    func gSectionCaps() -> some View {
        font(.system(size: 12, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(Color.gInk3)
    }

    /// Encabezado de sección — «En curso», «Historial»
    func gSectionTitle() -> some View {
        font(.system(size: 17, weight: .bold))
            .foregroundStyle(Color.gInk)
    }

    /// Nombre de agente o de fila (600 15)
    func gRowTitle() -> some View {
        font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.gInk)
    }

    /// Pregunta de la tarjeta de permiso
    func gCardTitle() -> some View {
        font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.gInk)
    }

    /// Cuerpo de burbuja y de tarjeta (400 15)
    func gBody() -> some View {
        font(.system(size: 15))
            .foregroundStyle(Color.gInk)
    }

    /// Subtítulo de fila (400 13)
    func gMeta() -> some View {
        font(.system(size: 13))
            .foregroundStyle(Color.gInk3)
    }

    /// Hora, contadores, texto terciario (400 12)
    func gCaption() -> some View {
        font(.system(size: 12))
            .foregroundStyle(Color.gInk3)
    }

    /// Etiqueta de botón (600 15)
    func gButtonLabel() -> some View {
        font(.system(size: 15, weight: .semibold))
    }

    /// Chip de estado (600 12)
    func gChip() -> some View {
        font(.system(size: 12, weight: .semibold))
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
