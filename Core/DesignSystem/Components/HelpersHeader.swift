import SwiftUI

/// El remate de los ayudantes (subagentes nativos): gs lo escribe con un encabezado markdown
/// (`---\n*Terminó «X», «Y» · 8:12 a. m.*\n\n`, `wakeHeader` en gs). Igual que /c
/// (`SubagentsPanel.tsx`, `WakeHeader`): «Mensaje de N ayudantes · hora», una flamita por
/// ayudante y una pastilla «Listo» por encargo. El resto del texto sigue siendo la respuesta.
struct HelpersHeader: View {
    let titles: [String]
    let time: String

    /// El encabezado y lo que sigue, o `nil` si el texto no es un remate.
    static func split(_ text: String) -> (header: HelpersHeader, rest: String)? {
        let pattern = #"^---\n\*(Terminó (.+?)|Resumen) · ([^*]+)\*\n\n"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(m.range, in: text),
              let timeRange = Range(m.range(at: 3), in: text) else { return nil }
        var titles: [String] = []
        if let listRange = Range(m.range(at: 2), in: text) {
            let list = String(text[listRange])
            let quoted = try? NSRegularExpression(pattern: "«([^»]+)»")
            titles = quoted?.matches(in: list, range: NSRange(list.startIndex..., in: list))
                .compactMap { Range($0.range(at: 1), in: list).map { String(list[$0]) } } ?? []
        }
        let time = String(text[timeRange]).trimmingCharacters(in: .whitespaces)
        return (HelpersHeader(titles: titles, time: time), String(text[whole.upperBound...]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: -6) {
                    ForEach(Array(titles.prefix(4).enumerated()), id: \.offset) { _, _ in
                        AnimatedFlame(height: 18)
                            .frame(width: 18 * 13 / 15, height: 18)
                            .padding(2)
                            .background(Circle().fill(Color.gBg))
                    }
                }
                Text(summary).font(.system(size: 12)).foregroundStyle(Color.gInk3)
            }
            if !titles.isEmpty {
                // Las pastillas se acomodan en renglones.
                FlowLayout(spacing: 6) {
                    ForEach(titles, id: \.self) { title in
                        // En la app (no en /c) la pastilla abre la hoja de subagentes.
                        Button { SubagentsLayer.shared.isSheetOpen = true } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Color.gGreen).frame(width: 6, height: 6)
                            Text(title).foregroundStyle(Color.gInk).lineLimit(1)
                            Text("Listo").foregroundStyle(Color.gGreenInk)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.gFill))
                        .overlay(Capsule().stroke(Color.gSeparator, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.bottom, 4) // + los 8 del VStack de la burbuja = 12, como /c
    }

    private var summary: String {
        let who = titles.isEmpty ? "Resumen de los ayudantes"
            : "Mensaje de \(titles.count) \(titles.count == 1 ? "ayudante" : "ayudantes")"
        return "\(who) · \(time)"
    }
}

/// Acomoda las vistas en renglones, como `flex-wrap`.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
