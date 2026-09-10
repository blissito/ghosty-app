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

/// Cabecera con el avatar arriba al centro y el estado debajo. Es la firma visual de
/// Muse y lo que hace que el agente "exista" aunque no le escribas.
struct AgentHeader: View {
    let agent: Agent
    /// El estado se PREGUNTA al store: guardado en el `Agent` se desincroniza del turno.
    var estado: AgentStatus?
    var onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 5) {
            GhostyMascot(tone: agent.tone, height: 46)
            Text(agent.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gInk)
            StatusLine(status: estado ?? agent.status)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.screenH)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
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
