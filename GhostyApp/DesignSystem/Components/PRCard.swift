import SwiftUI

/// La tarjeta de revisión de PR.
///
/// El modelo emite los DATOS; los botones los pone la app. Si el modelo pudiera
/// declararlos, inventaría un "Mergear" que no existe. Y los botones no mandan
/// texto al chat: llaman a la acción directamente.
struct PRCard: View {
    let card: PullRequestCard
    var onApprove: () -> Void
    var onRequestChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.trianglehead.branch")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.gInk)
                Text("\(card.reference) · \(card.title)")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                ForEach(Array(card.chips.enumerated()), id: \.offset) { _, chip in
                    Text(chip.text)
                        .gChip()
                        .foregroundStyle(color(chip.tone).ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(color(chip.tone).bg)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                        .fixedSize()
                }
            }

            Rectangle().fill(Color.gSeparator).frame(height: 1)

            HStack(spacing: 7) {
                Button(action: onApprove) {
                    Text("Aprobar").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                        .padding(.horizontal, 16).frame(minHeight: 36)
                        .background(Color.gFill)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onRequestChanges) {
                    Text("Pedir cambios").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Color.gInk)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)

                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.gInk)
                    .frame(width: 36, height: 36)
                    .background(Color.gFill)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
        .padding(14)
        .background(Color.gCard)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .padding(9)
        .background(Color.gBubbleAgent)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .frame(maxWidth: 300, alignment: .leading)
    }

    private func color(_ t: PullRequestCard.Chip.Tone) -> (bg: Color, ink: Color) {
        switch t {
        case .green:   return (.gGreenTint, .gGreenInk)
        case .red:     return (.gDangerTint, .gDangerInk)
        case .neutral: return (.gFill, .gInk2)
        }
    }
}
