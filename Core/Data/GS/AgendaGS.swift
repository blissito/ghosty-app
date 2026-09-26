import Foundation

/// Los turnos programados de una conversación: lo que el agente hará cuando nadie mire.
///
/// Un trabajo de días no es un turno de días: son muchos turnos cortos con reloj, y el
/// reloj vive en gs (`ScheduledTurn`), donde nadie duerme. Aquí sólo se pide, se crea y
/// se cancela. Va aparte de `ClienteGS` a propósito: no es transporte del turno, es
/// agenda, y así no obliga al protocolo del WebSocket a fingir que sabe programar.
struct TurnoProgramado: Identifiable, Hashable {
    let id: String
    let prompt: String
    let dueAt: Date
    let repeatMin: Int?
    let until: Date?
    /// "user" | "agent" — quién lo programó.
    let createdBy: String

    var seRepite: Bool { repeatMin != nil }
}

enum AgendaGS {
    private static func url(_ agentID: String, _ sessionID: String, _ sufijo: String = "") -> URL {
        Session.base.appendingPathComponent(
            "api/v2/me/agents/\(agentID)/conversations/\(sessionID)/schedule\(sufijo)")
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoSinFraccion = ISO8601DateFormatter()

    private static func fecha(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? isoSinFraccion.date(from: s)
    }

    private static func pedir(_ url: URL, metodo: String = "GET",
                              cuerpo: [String: Any]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: url)
        r.httpMethod = metodo
        r.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        r.assumesHTTP3Capable = false
        if let cuerpo {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: cuerpo)
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        guard (200..<300).contains(codigo) else {
            // El servidor contesta con un código corto (`tope`, `repeticion_corta`…) y un
            // `detalle` legible. Se enseña el detalle: es la única pista que hay.
            let detalle = json["detalle"] as? String ?? "El servidor contestó \(codigo)."
            throw ACPClient.Fallo.remoto(detalle)
        }
        return json
    }

    private static func parsear(_ r: [String: Any]) -> TurnoProgramado? {
        guard let id = r["id"] as? String, let prompt = r["prompt"] as? String,
              let due = fecha(r["dueAt"]) else { return nil }
        return TurnoProgramado(id: id, prompt: prompt, dueAt: due,
                               repeatMin: r["repeatMin"] as? Int,
                               until: fecha(r["until"]),
                               createdBy: r["createdBy"] as? String ?? "user")
    }

    static func listar(agentID: String, sessionID: String) async throws -> [TurnoProgramado] {
        let r = try await pedir(url(agentID, sessionID))
        return (r["programados"] as? [[String: Any]] ?? []).compactMap(parsear)
    }

    /// `repetirCadaMin` exige `hasta`: el servidor lo rechaza si falta, y con razón — una
    /// repetición sin fin es una bolsa de tokens que se vacía sola.
    static func programar(agentID: String, sessionID: String, prompt: String, cuando: Date,
                          repetirCadaMin: Int? = nil, hasta: Date? = nil) async throws -> TurnoProgramado {
        var cuerpo: [String: Any] = ["prompt": prompt, "dueAt": iso.string(from: cuando)]
        if let repetirCadaMin {
            cuerpo["repeatMin"] = repetirCadaMin
            if let hasta { cuerpo["until"] = iso.string(from: hasta) }
        }
        let r = try await pedir(url(agentID, sessionID), metodo: "POST", cuerpo: cuerpo)
        guard let t = (r["programado"] as? [String: Any]).flatMap(parsear) else {
            throw ACPClient.Fallo.remoto("el servidor no devolvió el turno programado")
        }
        return t
    }

    static func cancelar(agentID: String, sessionID: String, id: String) async throws {
        _ = try await pedir(url(agentID, sessionID, "/\(id)"), metodo: "DELETE")
    }
}
