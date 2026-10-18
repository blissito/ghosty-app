import Foundation

/// Lector de `text/event-stream` por líneas. Puro: no sabe de red.
///
/// ⚠️ No se usa `URLSession.bytes(for:).lines`: `AsyncLineSequence` se come las líneas VACÍAS, y en
/// SSE la línea vacía es justo la que cierra un evento. Con AG-UI cada evento cabe en un `data:`, así
/// que funcionaría por casualidad, hasta que un servidor parta un JSON en dos `data:` (el estándar lo
/// permite). El transporte corta los bytes en líneas a mano y se las da a esto.
struct SSEParser {
    struct Message: Equatable, Sendable {
        var event: String
        var data: String
        var id: String?
    }

    private var event = "message"
    private var data: [String] = []
    private var id: String?

    /// Una línea SIN su salto. Devuelve el evento que esa línea cierra, si cierra uno.
    mutating func line(_ raw: String) -> Message? {
        let l = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if l.isEmpty { return flush() }
        if l.hasPrefix(":") { return nil }  // `: ping`
        let field: Substring, value: Substring
        if let i = l.firstIndex(of: ":") {
            field = l[..<i]
            var v = l[l.index(after: i)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            value = v
        } else {
            field = l[...]; value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        case "id": id = String(value)
        default: break
        }
        return nil
    }

    /// Fin del flujo: lo que quedó sin línea vacía también cuenta.
    mutating func finish() -> Message? { flush() }

    private mutating func flush() -> Message? {
        defer { event = "message"; data = []; id = nil }
        guard !data.isEmpty else { return nil }
        return Message(event: event, data: data.joined(separator: "\n"), id: id)
    }

    /// Todo un texto SSE de una vez (pruebas y flujos grabados).
    static func messages(in text: String) -> [Message] {
        var p = SSEParser()
        var out: [Message] = []
        for l in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let m = p.line(String(l)) { out.append(m) }
        }
        if let m = p.finish() { out.append(m) }
        return out
    }

    /// Los eventos AG-UI de un texto SSE (lo que no es JSON con `type` se ignora).
    static func events(in text: String) -> [AGUIEvent] {
        messages(in: text).compactMap { AGUIEvent(json: $0.data) }
    }
}
