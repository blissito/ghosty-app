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

/// Cabecera de chips, como la de Grok: una píldora al centro con la mascota, el nombre
/// y un punto de estado; un chip redondo a la derecha para empezar otra conversación.
///
/// ⚠️ Era la mascota grande arriba con el nombre y el estado debajo (la firma de Muse), y
/// se comía un cuarto de la pantalla en cada chat. Lo que hace que el agente «exista» es
/// el punto de estado y su nombre siempre a la vista, no 46 pt de mascota: aquí cabe en
/// una fila de 36 pt y el hilo gana esa altura.
struct AgentHeader: View {
    let agent: Agent
    /// El estado se PREGUNTA al store: guardado en el `Agent` se desincroniza del turno.
    var estado: AgentStatus?
    var onTap: (() -> Void)?
    /// El chip de la derecha. `nil` = no se pinta.
    var onNueva: (() -> Void)?

    private var status: AgentStatus { estado ?? agent.status }
    private var trabajando: Bool { if case .working = status { return true } else { return false } }
    @State private var latiendo = false

    /// Verde trabajando, rojo esperándote, gris en reposo: lo que decía la línea entera
    /// de estado, en 8 pt.
    private var punto: Color {
        switch status {
        case .working: return .gGreenInk
        case .awaitingApproval: return .gDanger
        case .idle: return .gInk4
        }
    }

    var body: some View {
        ZStack {
            Button { onTap?() } label: {
                HStack(spacing: 7) {
                    GhostyMascot(tone: agent.tone, height: 22)
                        // Late mientras trabaja: es el «estado de carga» de la cabecera,
                        // sin una línea de texto que lo diga.
                        .scaleEffect(latiendo ? 1.12 : 1)
                        .animation(trabajando
                                   ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                                   : .easeOut(duration: 0.2), value: latiendo)
                        .onChange(of: trabajando, initial: true) { _, t in latiendo = t }
                        .overlay(alignment: .bottomTrailing) {
                            Circle().fill(punto).frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.gCard, lineWidth: 1.5))
                                .offset(x: 2, y: 1)
                        }
                    Text(agent.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                        .lineLimit(1)
                    // Motor y «compartido»: cuatro «Ghosty» no se distinguen por el nombre.
                    Text(agent.compartidoPor != nil ? "\(agent.engine) · compartido" : agent.engine)
                        .font(.system(size: 11)).foregroundStyle(Color.gInk3)
                        .lineLimit(1)
                }
                .padding(.leading, 10).padding(.trailing, 14)
                .frame(height: 36)
                .background(Color.gCard, in: Capsule())
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cabecera-agente")
            .frame(maxWidth: 260)

            if let onNueva {
                HStack {
                    Spacer()
                    Button(action: onNueva) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.gInk)
                            .frame(width: 36, height: 36)
                            .background(Color.gCard, in: Circle())
                            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("nueva-conversacion-cabecera")
                }
                .padding(.horizontal, Theme.Space.screenH)
            }
        }
        .frame(maxWidth: .infinity)
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
