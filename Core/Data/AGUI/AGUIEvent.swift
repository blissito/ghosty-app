import Foundation

/// Un evento AG-UI tal como llega por el cable (`data: {json}`), sin interpretar.
///
/// ⚠️ Se guarda el JSON entero y no un enum cerrado: AG-UI crece (ACTIVITY_*, REASONING_*…) y gs
/// le pone campos propios a sus CUSTOM. Un evento que no conocemos se deja pasar —el reductor lo
/// ignora— en vez de tirar el flujo por un tipo nuevo. Ver `~/ghostykit/docs/protocol.md`.
struct AGUIEvent: @unchecked Sendable {
    let type: String
    let raw: [String: Any]

    init?(json: String) {
        guard let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let t = o["type"] as? String else { return nil }
        self.type = t
        self.raw = o
    }

    init(type: String, _ fields: [String: Any] = [:]) {
        var r = fields
        r["type"] = type
        self.type = type
        self.raw = r
    }

    subscript(_ k: String) -> Any? { raw[k] }
    func string(_ k: String) -> String? { raw[k] as? String }

    /// La hora del SERVIDOR al emitirlo (epoch ms, campo base de AG-UI), si la trae.
    var timestamp: Double? { (raw["timestamp"] as? NSNumber)?.doubleValue }

    /// El mismo evento con `timestamp` puesto (lo pone el transporte con el `Date` de la respuesta).
    func withTimestamp(_ ms: Double) -> AGUIEvent {
        var r = raw
        r["timestamp"] = ms
        return AGUIEvent(type: type, r)
    }
}

/// Un mensaje AG-UI de `MESSAGES_SNAPSHOT`: `user`, `assistant` (con `toolCalls`), `tool`, `reasoning`.
struct AGUIMessage: @unchecked Sendable {
    let id: String
    let role: String
    let raw: [String: Any]

    init?(_ o: [String: Any]) {
        guard let role = o["role"] as? String else { return nil }
        self.id = o["id"] as? String ?? UUID().uuidString
        self.role = role
        self.raw = o
    }

    /// El texto: `content` string o la concatenación de sus partes `{type:"text"}`.
    var text: String {
        if let s = raw["content"] as? String { return s }
        guard let parts = raw["content"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }

    /// Las partes que no son texto (imágenes, documentos, audio).
    var attachments: [AGUIAttachment] {
        guard let parts = raw["content"] as? [[String: Any]] else { return [] }
        return parts.compactMap(AGUIAttachment.init(part:))
    }

    var toolCalls: [(id: String, name: String, arguments: String)] {
        (raw["toolCalls"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            let f = c["function"] as? [String: Any]
            return (id, f?["name"] as? String ?? "tool", f?["arguments"] as? String ?? "")
        }
    }

    var toolCallId: String? { raw["toolCallId"] as? String }
    var failed: Bool {
        if let e = raw["error"] as? String { return !e.isEmpty }
        return raw["error"] as? Bool == true
    }
}

/// Una parte de contenido AG-UI que no es texto.
struct AGUIAttachment: Sendable, Equatable {
    var name: String?
    var mimeType: String
    /// `url` o `data` (base64), según `source.type`.
    var url: String?
    var data: String?

    init(name: String?, mimeType: String, url: String? = nil, data: String? = nil) {
        self.name = name; self.mimeType = mimeType; self.url = url; self.data = data
    }

    init?(part p: [String: Any]) {
        guard let type = p["type"] as? String, type != "text",
              let source = p["source"] as? [String: Any] else { return nil }
        let mime = (p["mimeType"] as? String) ?? (source["mimeType"] as? String)
            ?? (type == "image" ? "image/*" : "application/octet-stream")
        let value = source["value"] as? String
        let isData = source["type"] as? String == "data"
        self.init(name: (p["filename"] as? String) ?? (p["name"] as? String), mimeType: mime,
                  url: isData ? nil : value, data: isData ? value : nil)
    }
}
