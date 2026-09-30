import Foundation

/// El renglón gris de cada fila de «Chats»: lo último que se dijo, de quién, y cuántas
/// respuestas del agente llegaron después de tu último mensaje (la insignia verde).
///
/// Sale de los mensajes que YA están en el teléfono (el hilo abierto o su copia en
/// `CacheDeHilos`): pedirle a gs una vista previa por fila costaría una llamada por
/// conversación cada vez que se pinta la lista. Es lo que hace Android (`recomputePreviews`).
struct VistaPrevia: Equatable, Sendable {
    var texto: String
    /// Lo último lo mandaste tú: la fila dice «Tú: …».
    var deTi: Bool
    /// Mensajes del agente después de tu último mensaje.
    var respuestas: Int

    static func de(_ mensajes: [Message]) -> VistaPrevia? {
        guard let ultimo = mensajes.last(where: { linea(de: $0) != nil }),
              let t = linea(de: ultimo) else { return nil }
        let ultimoTuyo = mensajes.lastIndex { if case .user = $0.kind { return true } else { return false } }
        let despues = ultimoTuyo.map { mensajes[($0 + 1)...] } ?? mensajes[...]
        let respuestas = despues.filter(\.esDelAgente).count
        if case .user = ultimo.kind { return VistaPrevia(texto: t, deTi: true, respuestas: respuestas) }
        return VistaPrevia(texto: t, deTi: false, respuestas: respuestas)
    }

    /// Una línea legible de un mensaje, o `nil` si no dice nada (escribiendo, sistema).
    private static func linea(de m: Message) -> String? {
        switch m.kind {
        case .user(let t, let adjuntos, _):
            if let voz = adjuntos.first(where: \.esVoz) {
                return "🎤 Nota de voz (\(NotaDeVoz.reloj(voz.segundos ?? 0)))"
            }
            let limpio = plano(t)
            if !limpio.isEmpty { return limpio }
            if let a = adjuntos.first { return (a.esImagen ? "📷 " : "📎 ") + a.nombre }
            return nil
        case .agent(let t, _, let trailing):
            let limpio = plano(trailing.map { t + " " + $0 } ?? t)
            return limpio.isEmpty ? nil : limpio
        case .entrega(let e):
            if e.esNotaDeVoz { return "🎤 Nota de voz" + (e.segundosDeVoz.map { $0 > 0 ? " (\(NotaDeVoz.reloj($0)))" : "" } ?? "") }
            return (e.esImagen ? "📷 " : "📎 ") + e.titulo
        case .prCard:
            return "Pull request"
        case .sistema, .typing:
            return nil
        }
    }

    /// Markdown fuera: en una línea gris sólo cabe el texto.
    static func plano(_ markdown: String) -> String {
        var s = markdown
        // Bloques de código y fences de Teams (eb-file, eb-audio…) no son texto que leer.
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_`#>|~]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(s.trimmingCharacters(in: .whitespaces).prefix(160))
    }
}
