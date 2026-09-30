import SwiftUI

/// Botón grande de la hoja de permisos. El primario lleva el degradado — es lo que
/// lo hace el único primario de la pantalla.
struct ActionButton: View {
    enum Kind { case primary, secondary, destructive }

    let title: String
    var kind: Kind = .secondary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .gButtonLabel()
                .foregroundStyle(kind == .primary ? .white : Color.gInk)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background {
                    switch kind {
                    case .primary:     Theme.primaryGradient
                    case .secondary:   Color.gFill
                    case .destructive: Color.gDangerTint
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .shadow(color: kind == .primary ? Color.gPrimary.opacity(0.28) : .clear,
                        radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}

/// Barra de progreso + cronómetro. Cuando el turno no reporta pasos —el contrato de
/// la caja sólo trae `chunk`/`usage`/`done`— se muestra indeterminada en vez de
/// inventar un porcentaje.
struct TurnProgress: View {
    let turn: TurnActivity
    @State private var corrimiento: CGFloat = -0.4

    var body: some View {
        HStack(spacing: 11) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gFillStrong)
                    if turn.totalSteps > 0 {
                        Capsule().fill(Color.gPrimary)
                            .frame(width: geo.size.width * turn.progress)
                    } else {
                        Capsule().fill(Color.gPrimary)
                            .frame(width: geo.size.width * 0.32)
                            .offset(x: geo.size.width * corrimiento)
                            .task {
                                while !Task.isCancelled {
                                    withAnimation(.easeInOut(duration: 1.1)) { corrimiento = 0.72 }
                                    try? await Task.sleep(for: .milliseconds(1150))
                                    withAnimation(.easeInOut(duration: 1.1)) { corrimiento = -0.4 }
                                    try? await Task.sleep(for: .milliseconds(1150))
                                }
                            }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 4)

            Text(turn.elapsed).gMono().foregroundStyle(Color.gInk3)
        }
    }
}

/// Icono en cuadro redondeado. Un solo sitio para el tamaño y el fondo.
struct TintedIcon: View {
    let systemName: String
    var tint: Color = .gInk2
    var background: Color = .gFill
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(tint)
            }
    }
}

extension LogEntry.Icon {
    var systemName: String {
        switch self {
        case .document: return "doc.text"
        case .web:      return "globe"
        case .calendar: return "calendar"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .cart:     return "cart"
        case .branch:   return "arrow.trianglehead.branch"
        }
    }
}

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TintedIcon(systemName: entry.icon.systemName)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk)
                Text(entry.detail).gMeta().fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.time).gMono(size: 12.5, weight: .regular).foregroundStyle(Color.gInk4)
        }
        .padding(.vertical, Theme.Space.row)
        .opacity(entry.muted ? 0.5 : 1)
    }
}

extension Artifact.Kind {
    var systemName: String {
        switch self {
        case .document: return "doc.text"
        case .board:    return "chart.bar"
        case .page:     return "macwindow"
        case .sheet:    return "tablecells"
        case .mail:     return "envelope"
        }
    }

    var tint: (fg: Color, bg: Color) {
        switch self {
        case .document: return (.gInk2, .gFill)
        case .board:    return (.gGreenInk, .gGreenTint)
        case .page:     return (.gPrimary, .gPrimaryTint)
        case .sheet:    return (.gInk2, .gFill)
        case .mail:     return (.gDangerInk, .gDangerTint)
        }
    }
}

struct ArtifactRow: View {
    let artifact: Artifact

    var body: some View {
        HStack(spacing: 13) {
            TintedIcon(systemName: artifact.kind.systemName,
                       tint: artifact.kind.tint.fg,
                       background: artifact.kind.tint.bg,
                       size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(artifact.title).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gInk).lineLimit(1)
                Text("\(artifact.area) · \(artifact.kindLabel)").gCaption()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.gInk4)
                .rotationEffect(.degrees(90))
        }
        .padding(.vertical, 12)
    }
}

/// La cabecera del chat del diseño (`Ghosty App.dc.html`): historial a la izquierda, la
/// píldora del agente al centro (avatar 32, nombre 700 16 y chevron) y «nuevo chat» a la
/// derecha. Botones de 44, sin fondo: el hilo pasa por debajo sin cajas que lo tapen.
///
/// El punto de estado va SOBRE el avatar y sólo cuando dice algo (trabajando o esperando
/// tu permiso): en reposo el diseño no pinta nada, y un punto gris fijo era ruido.
struct AgentHeader: View {
    /// Motor y, si no es tuyo, de dónde es: cuatro «Ghosty» no se distinguen por el nombre.
    static func subtitle(_ agent: Agent) -> String {
        switch agent.space?.kind {
        case .workspace?: return "\(agent.engine) · \(agent.space!.name)"
        case .shared?: return "\(agent.engine) · compartido"
        default: return agent.compartidoPor != nil ? "\(agent.engine) · compartido" : agent.engine
        }
    }

    let agent: Agent
    /// El estado se PREGUNTA al store: guardado en el `Agent` se desincroniza del turno.
    var estado: AgentStatus?
    var onTap: (() -> Void)?
    /// Mantener presionado el agente: la lista para cambiarlo (tocar abre su ficha).
    var onMantener: (() -> Void)?
    /// El botón de la derecha. `nil` = no se pinta.
    var onNueva: (() -> Void)?
    /// El botón de la izquierda: abre el historial de conversaciones (ya no es pestaña).
    var onHistorial: (() -> Void)?
    /// Hay conversaciones con algo sin ver: punto sobre el botón del historial.
    var puntoHistorial = false
    /// La flecha de atrás a «Chats» (desde el rediseño estilo WhatsApp). Gana sobre el
    /// historial: dentro de un hilo, la lista ES el historial.
    var onVolver: (() -> Void)?
    /// Cuántas conversaciones te esperan en «Chats»: el número junto a la flecha.
    var pendientesAtras = 0
    /// ⭐ de la conversación, como en Android: `nil` = sin estrella (hilo sin sesión aún).
    var favorito: Bool?
    var onFavorito: (() -> Void)?

    private var status: AgentStatus { estado ?? agent.status }
    private var trabajando: Bool { if case .working = status { return true } else { return false } }
    @State private var latiendo = false

    private var punto: Color? {
        switch status {
        case .working: return .gGreen
        case .awaitingApproval: return .gDanger
        case .idle: return nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if let onVolver {
                Button(action: onVolver) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.gInk)
                        if pendientesAtras > 0 {
                            Text("\(pendientesAtras)")
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.gInk)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.gPressIcon)
                .accessibilityLabel(pendientesAtras > 0 ? "Chats, \(pendientesAtras) sin leer" : "Chats")
                .accessibilityIdentifier("volver-a-chats")
            } else if let onHistorial {
                Button(action: onHistorial) {
                    GhostyIcons.historial.dibujo(Color.gInk, size: 20)
                        .overlay(alignment: .topTrailing) {
                            if puntoHistorial {
                                Circle().fill(Color.gPrimary)
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(Color.gBg, lineWidth: 1.5))
                                    .offset(x: 3, y: 1)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.gPressIcon)
                .accessibilityLabel(puntoHistorial ? "Historial, con novedades" : "Historial")
                .accessibilityIdentifier("abrir-historial")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }

            Spacer(minLength: 4)

            Button { onTap?() } label: {
                HStack(spacing: 8) {
                    AgentAvatar(tone: agent.tone, size: 32)
                        // Late mientras trabaja: el «cargando» de la cabecera sin texto.
                        .scaleEffect(latiendo ? 1.08 : 1)
                        .animation(trabajando
                                   ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                                   : .easeOut(duration: 0.2), value: latiendo)
                        .onChange(of: trabajando, initial: true) { _, t in latiendo = t }
                        .overlay(alignment: .bottomTrailing) {
                            if let punto {
                                Circle().fill(punto).frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(Color.gBg, lineWidth: 2))
                                    .offset(x: 1, y: 1)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: punto)
                    Text(agent.name)
                        .font(.system(size: 16, weight: .bold))
                        .tracking(-0.16)
                        .foregroundStyle(Color.gInk)
                        .lineLimit(1)
                }
                .padding(.leading, 4).padding(.trailing, 8)
                .frame(height: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.gPressPill)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in onMantener?() })
            .accessibilityIdentifier("cabecera-agente")
            .accessibilityLabel("\(agent.name), \(Self.subtitle(agent)). Cambiar de agente")

            Spacer(minLength: 4)

            if let favorito, let onFavorito {
                Button(action: onFavorito) {
                    Image(systemName: favorito ? "star.fill" : "star")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(favorito ? Color.gBird : Color.gInk)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.gPressIcon)
                .accessibilityLabel(favorito ? "Quitar de favoritos" : "Agregar a favoritos")
                .accessibilityIdentifier("hilo-favorito")
            }
            if let onNueva {
                Button(action: onNueva) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.gInk)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.gPressIcon)
                .accessibilityLabel("Nuevo chat")
                .accessibilityIdentifier("nueva-conversacion-cabecera")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: puntoHistorial)
    }
}

/// Los iconos de trazo del chat (los `<path d=…>` del prototipo), en su `viewBox`.
enum ChatIcons {
    /// Nuevo chat, viewBox 20: `M9 3.5H5a1.5 1.5 0 00-1.5 1.5v10A1.5 1.5 0 005 16.5h10
    /// a1.5 1.5 0 001.5-1.5v-4` + `M14.5 2.8l2.7 2.7L10 12.7H7.3V10z`.
    static let nuevoChat = GhostyStrokeIcon(viewBox: 20) { p in
        p.move(to: CGPoint(x: 9, y: 3.5))
        p.addLine(to: CGPoint(x: 5, y: 3.5))
        p.addQuadCurve(to: CGPoint(x: 3.5, y: 5), control: CGPoint(x: 3.5, y: 3.5))
        p.addLine(to: CGPoint(x: 3.5, y: 15))
        p.addQuadCurve(to: CGPoint(x: 5, y: 16.5), control: CGPoint(x: 3.5, y: 16.5))
        p.addLine(to: CGPoint(x: 15, y: 16.5))
        p.addQuadCurve(to: CGPoint(x: 16.5, y: 15), control: CGPoint(x: 16.5, y: 16.5))
        p.addLine(to: CGPoint(x: 16.5, y: 11))
        p.move(to: CGPoint(x: 14.5, y: 2.8))
        p.addLine(to: CGPoint(x: 17.2, y: 5.5))
        p.addLine(to: CGPoint(x: 10, y: 12.7))
        p.addLine(to: CGPoint(x: 7.3, y: 12.7))
        p.addLine(to: CGPoint(x: 7.3, y: 10))
        p.closeSubpath()
    }

    /// ＋ del compositor, viewBox 18: `M9 3v12M3 9h12`.
    static let mas = GhostyStrokeIcon(viewBox: 18) { p in
        p.move(to: CGPoint(x: 9, y: 3)); p.addLine(to: CGPoint(x: 9, y: 15))
        p.move(to: CGPoint(x: 3, y: 9)); p.addLine(to: CGPoint(x: 15, y: 9))
    }

    /// Enviar, viewBox 18: `M9 14V4M4.5 8.5L9 4l4.5 4.5`.
    static let enviar = GhostyStrokeIcon(viewBox: 18) { p in
        p.move(to: CGPoint(x: 9, y: 14)); p.addLine(to: CGPoint(x: 9, y: 4))
        p.move(to: CGPoint(x: 4.5, y: 8.5)); p.addLine(to: CGPoint(x: 9, y: 4))
        p.addLine(to: CGPoint(x: 13.5, y: 8.5))
    }

    /// Micrófono, viewBox 18: cápsula `6.5,2 5×9 r2.5` + `M3.8 8.5a5.2 5.2 0 0010.4 0M9 13.7V16`.
    static let microfono = GhostyStrokeIcon(viewBox: 18) { p in
        p.addRoundedRect(in: CGRect(x: 6.5, y: 2, width: 5, height: 9),
                         cornerSize: CGSize(width: 2.5, height: 2.5))
        p.move(to: CGPoint(x: 3.8, y: 8.5))
        // Del lado izquierdo al derecho pasando por ABAJO (ángulo decreciente 180 → 0).
        p.addArc(center: CGPoint(x: 9, y: 8.5), radius: 5.2,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        p.move(to: CGPoint(x: 9, y: 13.7)); p.addLine(to: CGPoint(x: 9, y: 16))
    }

    /// Chevron de la tarjeta de sugerencia, viewBox 16: `M6 3.5L10.5 8 6 12.5`.
    static let chevronDerecha = GhostyStrokeIcon(viewBox: 16) { p in
        p.move(to: CGPoint(x: 6, y: 3.5))
        p.addLine(to: CGPoint(x: 10.5, y: 8))
        p.addLine(to: CGPoint(x: 6, y: 12.5))
    }

    /// Chevron chico del chip de herramientas, viewBox 10: `M3.5 2l3 3-3 3`.
    static let chevronChico = GhostyStrokeIcon(viewBox: 10) { p in
        p.move(to: CGPoint(x: 3.5, y: 2))
        p.addLine(to: CGPoint(x: 6.5, y: 5))
        p.addLine(to: CGPoint(x: 3.5, y: 8))
    }

    /// Palomita del paso hecho, viewBox 10: `M2 5.2l2 2L8 3`.
    static let check = GhostyStrokeIcon(viewBox: 10) { p in
        p.move(to: CGPoint(x: 2, y: 5.2))
        p.addLine(to: CGPoint(x: 4, y: 7.2))
        p.addLine(to: CGPoint(x: 8, y: 3))
    }

    // MARK: viewBox 22 (sugerencias y hoja «Agregar»)

    /// Documento: `M6 3.5h6.5L17 8v10.5H6zM12.5 3.5V8H17`.
    private static func hoja(_ p: inout Path) {
        p.move(to: CGPoint(x: 6, y: 3.5))
        p.addLine(to: CGPoint(x: 12.5, y: 3.5))
        p.addLine(to: CGPoint(x: 17, y: 8))
        p.addLine(to: CGPoint(x: 17, y: 18.5))
        p.addLine(to: CGPoint(x: 6, y: 18.5))
        p.closeSubpath()
        p.move(to: CGPoint(x: 12.5, y: 3.5))
        p.addLine(to: CGPoint(x: 12.5, y: 8))
        p.addLine(to: CGPoint(x: 17, y: 8))
    }

    static let documento = GhostyStrokeIcon(viewBox: 22) { p in hoja(&p) }

    /// PDF: la hoja con dos renglones (`M8.5 12h5M8.5 15h3.5`).
    static let pdf = GhostyStrokeIcon(viewBox: 22) { p in
        hoja(&p)
        p.move(to: CGPoint(x: 8.5, y: 12)); p.addLine(to: CGPoint(x: 13.5, y: 12))
        p.move(to: CGPoint(x: 8.5, y: 15)); p.addLine(to: CGPoint(x: 12, y: 15))
    }

    /// Tabla: `M4 5h14v12H4zM4 9h14M4 13h14M9.5 9v8`.
    static let tabla = GhostyStrokeIcon(viewBox: 22) { p in
        p.addRect(CGRect(x: 4, y: 5, width: 14, height: 12))
        p.move(to: CGPoint(x: 4, y: 9)); p.addLine(to: CGPoint(x: 18, y: 9))
        p.move(to: CGPoint(x: 4, y: 13)); p.addLine(to: CGPoint(x: 18, y: 13))
        p.move(to: CGPoint(x: 9.5, y: 9)); p.addLine(to: CGPoint(x: 9.5, y: 17))
    }

    /// Cotización (un ticket): `M6 3.5h10v15l-2-1.3-1.5 1.3-1.5-1.3-1.5 1.3L8 17.2l-2 1.3z
    /// M8.5 8h5M8.5 11h5M8.5 14h3`.
    static let cotizacion = GhostyStrokeIcon(viewBox: 22) { p in
        p.move(to: CGPoint(x: 6, y: 3.5))
        p.addLine(to: CGPoint(x: 16, y: 3.5))
        p.addLine(to: CGPoint(x: 16, y: 18.5))
        p.addLine(to: CGPoint(x: 14, y: 17.2))
        p.addLine(to: CGPoint(x: 12.5, y: 18.5))
        p.addLine(to: CGPoint(x: 11, y: 17.2))
        p.addLine(to: CGPoint(x: 9.5, y: 18.5))
        p.addLine(to: CGPoint(x: 8, y: 17.2))
        p.addLine(to: CGPoint(x: 6, y: 18.5))
        p.closeSubpath()
        p.move(to: CGPoint(x: 8.5, y: 8)); p.addLine(to: CGPoint(x: 13.5, y: 8))
        p.move(to: CGPoint(x: 8.5, y: 11)); p.addLine(to: CGPoint(x: 13.5, y: 11))
        p.move(to: CGPoint(x: 8.5, y: 14)); p.addLine(to: CGPoint(x: 11.5, y: 14))
    }

    /// Foto: `M4 5h14v12H4zM4 14l4-4 3.5 3.5L14 11l4 4M14.5 8.5h.01`.
    static let foto = GhostyStrokeIcon(viewBox: 22) { p in
        p.addRect(CGRect(x: 4, y: 5, width: 14, height: 12))
        p.move(to: CGPoint(x: 4, y: 14))
        p.addLine(to: CGPoint(x: 8, y: 10))
        p.addLine(to: CGPoint(x: 11.5, y: 13.5))
        p.addLine(to: CGPoint(x: 14, y: 11))
        p.addLine(to: CGPoint(x: 18, y: 15))
        p.move(to: CGPoint(x: 14.5, y: 8.5)); p.addLine(to: CGPoint(x: 14.51, y: 8.5))
    }

    /// Cámara: `M3.5 7.5h3l1.5-2h6l1.5 2h3v10h-15z` + lente de r 2.8 en (11, 12.2).
    static let camara = GhostyStrokeIcon(viewBox: 22) { p in
        p.move(to: CGPoint(x: 3.5, y: 7.5))
        p.addLine(to: CGPoint(x: 6.5, y: 7.5))
        p.addLine(to: CGPoint(x: 8, y: 5.5))
        p.addLine(to: CGPoint(x: 14, y: 5.5))
        p.addLine(to: CGPoint(x: 15.5, y: 7.5))
        p.addLine(to: CGPoint(x: 18.5, y: 7.5))
        p.addLine(to: CGPoint(x: 18.5, y: 17.5))
        p.addLine(to: CGPoint(x: 3.5, y: 17.5))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: 11 - 2.8, y: 12.2 - 2.8, width: 5.6, height: 5.6))
    }

    /// Programar (reloj): no está en el prototipo; mismo trazo y `viewBox`.
    static let reloj = GhostyStrokeIcon(viewBox: 22) { p in
        p.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 15, height: 15))
        p.move(to: CGPoint(x: 11, y: 7)); p.addLine(to: CGPoint(x: 11, y: 11))
        p.addLine(to: CGPoint(x: 13.5, y: 13.5))
    }
}

/// Encabezado de la hoja: ✕ y compartir. Sin barra de pestañas — dentro de una hoja
/// no existe.
struct SheetHeader: View {
    var onClose: () -> Void

    var body: some View {
        HStack {
            Button(action: onClose) {
                TintedIcon(systemName: "xmark", tint: .gInk, background: .gSeparator, size: 34)
            }
            .accessibilityIdentifier("cerrar-hoja")
            .buttonStyle(.plain)
            Spacer()
            TintedIcon(systemName: "square.and.arrow.up", tint: .gInk, background: .gSeparator, size: 34)
        }
    }
}

/// Encabezado de sección con el "…" a la derecha.
struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title).gSectionTitle()
            Spacer()
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.gInk3)
        }
    }
}
