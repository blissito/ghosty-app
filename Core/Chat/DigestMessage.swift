import SwiftUI

/// El brief de la mañana dentro del hilo. gs lo deja como mensaje del agente en markdown plano
/// (`renderDigestMessage` en `app/lib/daily-digest/digest.ts`):
///
/// ```
/// ---
/// *☀️ Brief de la mañana · lunes 2 de noviembre*
/// ```eb-audio …```            ← opcional; `BloqueEbFile` lo saca como entrega con su reproductor
/// **2 cosas en curso y 1 que te necesita**
/// - renglón…
/// ¿Te sirve? [Sí](…/brief/r/<token>?a=yes) · [No](…?a=no) · [Ya no me lo mandes](…?a=off)
/// ```
///
/// Igual que /c (`DigestMessage.tsx`): etiqueta ámbar arriba, el cuerpo en markdown y el pie
/// chico y gris que llama a `POST /api/v2/digest/r/:token` sin salir del chat.
struct DigestMessage: Equatable {
    let dateLabel: String
    let body: String
    /// El token firmado del pie, o `nil` si el mensaje no trae pie.
    let token: String?

    static let label = "Brief de la mañana"

    /// ¿Es un brief? Tolerante al `---` de arriba, al selector de variación del ☀️ y a que el pie
    /// cambie de palabras: lo que manda es la liga `/brief/r/<token>`.
    static func split(_ text: String) -> DigestMessage? {
        let header = #"^\s*(?:---[ \t]*\n)?\s*\*☀\x{FE0F}?\s*Brief de la mañana · ([^*\n]+)\*[ \t]*(?:\n|$)"#
        guard let re = try? NSRegularExpression(pattern: header),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(m.range, in: text),
              let dateR = Range(m.range(at: 1), in: text) else { return nil }
        var lines = String(text[whole.upperBound...]).components(separatedBy: "\n")
        var token: String?
        // El pie: el último renglón con ligas `/brief/r/<token>`.
        if let i = lines.lastIndex(where: { $0.contains("/brief/r/") }) {
            token = tokenOf(lines[i])
            lines.remove(at: i)
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return DigestMessage(dateLabel: String(text[dateR]).trimmingCharacters(in: .whitespaces),
                             body: body, token: token)
    }

    /// El token de la primera liga `…/brief/r/<token>?a=…` del renglón.
    static func tokenOf(_ line: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"/brief/r/([^/?#)\s]+)"#),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r = Range(m.range(at: 1), in: line) else { return nil }
        return String(line[r])
    }

    /// Para la vista previa de Chats: «☀️ Brief de la mañana · …» y el encabezado en negritas.
    static func preview(_ text: String) -> String? {
        guard let d = split(text) else { return nil }
        return "☀️ \(label) · \(d.dateLabel)\n\(d.body)"
    }
}

/// Cómo se pinta: etiqueta ámbar, cuerpo y pie. El audio no va aquí: llega como entrega aparte
/// (el reproductor de siempre, sin autoplay).
struct DigestMessageView: View {
    let digest: DigestMessage
    @State private var store = DailyDigestStore.shared
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "sun.max.fill").font(.system(size: 11, weight: .semibold))
                Text("\(DigestMessage.label) · \(digest.dateLabel)")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.gAmberInk)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.gAmberTint, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("digest-label")

            if !digest.body.isEmpty { GhostyMarkdown(markdown: digest.body) }

            if let token = digest.token { footer(token) }
        }
    }

    @ViewBuilder
    private func footer(_ token: String) -> some View {
        let done = store.reactions[token]
        HStack(spacing: 4) {
            switch done {
            case "off":
                Text("Listo, ya no te lo mando.")
                link("Volver a prenderlo", "on", token, id: "digest-on")
            case "on":
                Text("Listo, mañana te llega otra vez.")
            case .some:
                Text("¡Gracias! Lo anoto.")
            case nil:
                Text(failed ? "No se pudo. ¿Te sirve?" : "¿Te sirve?")
                link("Sí", "yes", token, id: "digest-yes")
                Text("·")
                link("No", "no", token, id: "digest-no")
                Text("·")
                link("Ya no me lo mandes", "off", token, id: "digest-off")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.gInk3)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("digest-footer")
    }

    private func link(_ title: String, _ action: String, _ token: String, id: String) -> some View {
        Button {
            guard !busy else { return }
            busy = true
            Task {
                failed = !(await store.react(token: token, action: action))
                busy = false
            }
        } label: {
            Text(title).underline()
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier(id)
    }
}
