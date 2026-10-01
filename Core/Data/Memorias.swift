import Foundation

/// Lo que el agente recuerda de la persona en TODOS sus chats (gs `api/v2/me/memories`).
///
/// ⚠️ Es de la CUENTA: con `agentId` vacío vale para todos sus agentes; con uno, sólo para
/// ése. Nunca entra en los turnos de los clientes de WhatsApp o Messenger (eso lo hace gs).
struct MemoriaDelAgente: Identifiable, Equatable, Sendable {
    let id: String
    var texto: String
    /// `nil` = la usan todos los agentes.
    var agenteID: String?
    /// La guardó el agente («recuerda que…») o la persona a mano.
    var delAgente: Bool
    var creada: Date?
    var editada: Date?

    init(id: String, texto: String, agenteID: String? = nil, delAgente: Bool = false,
         creada: Date? = nil, editada: Date? = nil) {
        self.id = id
        self.texto = texto
        self.agenteID = agenteID
        self.delAgente = delAgente
        self.creada = creada
        self.editada = editada
    }

    init?(_ j: [String: Any]) {
        guard let id = j["id"] as? String, let texto = j["content"] as? String else { return nil }
        self.init(id: id, texto: texto,
                  agenteID: (j["agentId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  delAgente: j["source"] as? String == "agent",
                  creada: MemoriasAPI.fecha(j["createdAt"]),
                  editada: MemoriasAPI.fecha(j["updatedAt"]))
    }
}

/// El cliente de las memorias. Los errores llegan legibles de gs (`{error}`, p. ej. el
/// tope de 500 caracteres o el 409 de las 200 memorias): se enseñan tal cual.
enum MemoriasAPI {
    static func listar(agente: String? = nil) async throws -> [MemoriaDelAgente] {
        var c = URLComponents(url: Session.base.appendingPathComponent("api/v2/me/memories"),
                              resolvingAgainstBaseURL: false)!
        if let agente { c.queryItems = [URLQueryItem(name: "agente", value: agente)] }
        let j = try await pedir(c.url!)
        return (j["memories"] as? [[String: Any]] ?? []).compactMap(MemoriaDelAgente.init)
    }

    static func crear(_ texto: String, agente: String?) async throws -> MemoriaDelAgente {
        var cuerpo: [String: Any] = ["content": texto]
        if let agente { cuerpo["agentId"] = agente }
        let j = try await pedir(Session.base.appendingPathComponent("api/v2/me/memories"), metodo: "POST", cuerpo: cuerpo)
        guard let m = (j["memory"] as? [String: Any]).flatMap(MemoriaDelAgente.init) else { throw GhostyAPI.Fallo.mensaje("No pude guardarla.") }
        return m
    }

    static func editar(_ id: String, texto: String) async throws -> MemoriaDelAgente {
        let j = try await pedir(Session.base.appendingPathComponent("api/v2/me/memories/\(id)"), metodo: "PATCH",
                                cuerpo: ["content": texto])
        guard let m = (j["memory"] as? [String: Any]).flatMap(MemoriaDelAgente.init) else { throw GhostyAPI.Fallo.mensaje("No pude guardarla.") }
        return m
    }

    static func olvidar(_ id: String) async throws {
        _ = try await pedir(Session.base.appendingPathComponent("api/v2/me/memories/\(id)"), metodo: "DELETE")
    }

    private static func pedir(_ url: URL, metodo: String = "GET", cuerpo: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = metodo
        req.assumesHTTP3Capable = false
        req.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        if let cuerpo {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: cuerpo)
        }
        let datos: Data, resp: URLResponse
        do { (datos, resp) = try await URLSession.shared.data(for: req) }
        catch { throw GhostyAPI.Fallo.mensaje("Sin conexión. Inténtalo de nuevo.") }
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any] ?? [:]
        guard (200..<300).contains(codigo) else {
            throw GhostyAPI.Fallo.mensaje((j["error"] as? String) ?? "El servidor contestó \(codigo).")
        }
        return j
    }

    static func fecha(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
