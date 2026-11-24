import Foundation

// Lo que gs calcula para cada fila de Desarrollo y el cliente sólo pinta (24-nov-2026):
// `actions` (qué botones hay), `compose` (a dónde irá un mensaje) y `claim` (la última señal de la terminal).
// Una acción que esta versión no conoce NUNCA se esconde: sale como botón neutro con su `label`.

struct DevAction: Identifiable, Hashable {
    enum Kind: Hashable {
        case op, link, start
        /// Un `kind` nuevo del servidor.
        case other(String)
    }

    let id: String
    let label: String
    let kind: Kind
    var op: String?
    var href: URL?
    /// Si viene, se pregunta antes de ejecutarla.
    var confirm: String?
    var destructive = false
    var primary = false
    var isDisabled = false
    /// Por qué no se puede ahora (`disabled.why`).
    var disabledWhy: String?

    /// Un elemento de `actions[]`. Sin `id` se usa el `label` (y viceversa): nada se descarta si se puede pintar.
    static func from(json j: [String: Any]) -> DevAction? {
        let rawID = (j["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rawLabel = (j["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let id = rawID ?? rawLabel else { return nil }
        let label = rawLabel ?? id.replacingOccurrences(of: "_", with: " ").capitalized
        let kind: Kind
        switch j["kind"] as? String {
        case "op": kind = .op
        case "link": kind = .link
        case "start": kind = .start
        case let k?: kind = .other(k)
        case nil: kind = (j["href"] as? String) != nil ? .link : .op
        }
        let disabled = j["disabled"] as? [String: Any]
        return DevAction(id: id, label: label, kind: kind, op: j["op"] as? String,
                         href: (j["href"] as? String).flatMap(URL.init(string:)),
                         confirm: (j["confirm"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                         destructive: j["destructive"] as? Bool ?? false, primary: j["primary"] as? Bool ?? false,
                         isDisabled: disabled != nil, disabledWhy: disabled?["why"] as? String)
    }

    /// `nil` = el servidor no mandó `actions` (gs viejo): ahí se usa el respaldo calculado en el cliente.
    static func list(from any: Any?) -> [DevAction]? {
        guard let arr = any as? [[String: Any]] else { return nil }
        return arr.compactMap(DevAction.from(json:))
    }
}

/// A dónde irá un mensaje escrito en una fila `local`, calculado ANTES de escribir.
struct DevCompose: Hashable {
    let enabled: Bool
    /// `terminal` | `cloud` (sólo con `enabled`).
    var routedTo: String?
    var writer: String?
    /// Una línea con el motivo (sólo sin `enabled`).
    var why: String?
    /// Lo que destraba el campo (p. ej. `resume_factory_and_send`).
    var action: DevAction?

    static func from(json any: Any?) -> DevCompose? {
        guard let j = any as? [String: Any], let enabled = j["enabled"] as? Bool else { return nil }
        let action = (j["action"] as? [String: Any]).flatMap(DevAction.from(json:))
        return DevCompose(enabled: enabled, routedTo: j["routedTo"] as? String, writer: j["writer"] as? String,
                          why: j["why"] as? String, action: action)
    }

    /// El texto que enseña el campo cuando está apagado: nunca queda vacío.
    var disabledText: String { (why?.isEmpty == false ? why : nil) ?? "Por ahora no hay a quién mandarle el mensaje." }
}

/// Última señal del claim de una fila `local` y si venció.
struct DevClaim: Hashable {
    let at: Date?
    let stale: Bool

    static func from(json any: Any?) -> DevClaim? {
        guard let j = any as? [String: Any] else { return nil }
        return DevClaim(at: DevDate.parse(j["at"] as? String), stale: j["stale"] as? Bool ?? false)
    }

    /// «Sin señal desde hace 9 h» (sólo si venció).
    var staleLine: String? {
        guard stale else { return nil }
        return at.map { "Sin señal desde \(DevDate.ago($0))" } ?? "Sin señal de la terminal"
    }
}

/// Lo que respondió gs al mandar un mensaje a una fila `local`.
struct DevSent: Equatable {
    /// `terminal` | `cloud`.
    let routedTo: String?
    let writer: String?

    /// Lo que se le dice a la persona: siempre con dueño, nunca «esperando a tu agente».
    var line: String {
        switch routedTo {
        case "cloud": return "Lo tomó Ghosty en la nube."
        case "terminal": return "Le llegó a \(writer.map { "@\($0)" } ?? "tu terminal")."
        default: return "Mensaje enviado."
        }
    }
}

enum DevSendResult {
    case sent(DevSent)
    /// 409 `no_destination`: nadie puede recibirlo; el campo se apaga con este `compose`.
    case blocked(DevCompose)
    case failed(String)
}

enum DevActionOutcome: Equatable {
    case done
    case open(URL)
    case failed(String)
}

extension DevStore {
    /// Ejecuta una acción del servidor. `runID` es el id de la tarjeta (`nil` en una fila `local` sin tarjeta).
    func perform(_ a: DevAction, repo: String, issue: Int?, runID: String?) async -> DevActionOutcome {
        switch a.kind {
        case .link:
            if let u = a.href { return .open(u) }
            return .failed("Esta acción no trae a dónde ir.")
        case .start:
            guard let issue, issue > 0 else { return .failed("Falta el número del issue.") }
            return await post("api/v2/me/dev-runs", ["repo": repo, "issue": issue], then: runID)
        case .op, .other:
            let op = a.op ?? a.id
            if op == "release_claim" {
                guard let issue, issue > 0 else { return .failed("Falta el número del issue.") }
                return await post("api/v2/me/dev-runs", ["op": "release_claim", "repo": repo, "issue": issue], then: runID)
            }
            if let runID, !runID.hasPrefix("pr:") {
                if let err = await act(runID, op: op) { return .failed(err) }
                await refresh()
                return .done
            }
            if let u = a.href { return .open(u) }
            return .failed("Esta versión de la app no sabe «\(a.label)». Hazlo desde la web.")
        }
    }

    private func post(_ path: String, _ body: [String: Any], then runID: String?) async -> DevActionOutcome {
        var body = body
        body["from"] = "ios"
        do {
            _ = try await request(path, method: "POST", body: body)
            await refresh()
            if let runID { await loadDetail(runID) }
            return .done
        } catch {
            return .failed((error as? DevError)?.message ?? "No se pudo. Intenta otra vez.")
        }
    }

    /// Manda un mensaje a una fila `local` (`op: message`): gs decide a dónde va y siempre lo dice.
    func sendMessage(repo: String, issue: Int?, pr: Int?, content: String) async -> DevSendResult {
        var body: [String: Any] = ["op": "message", "repo": repo, "content": content, "from": "ios"]
        if let pr { body["pr"] = pr } else if let issue { body["issue"] = issue }
        do {
            let j = try await request("api/v2/me/dev-runs", method: "POST", body: body) as? [String: Any]
            await refresh()
            return .sent(DevSent(routedTo: j?["routedTo"] as? String, writer: j?["writer"] as? String))
        } catch let e as DevError {
            if e.code == 409, let c = DevCompose.from(json: e.body?["compose"]), !c.enabled { return .blocked(c) }
            return .failed(e.message)
        } catch {
            return .failed("No se pudo mandar. Intenta otra vez.")
        }
    }

    /// Reanuda la fábrica del repo (lo que destraba `resume_factory_and_send`). `nil` = listo.
    func resumeFactory(repo: String) async -> String? {
        do {
            _ = try await request("api/v2/me/repos/\(repo)/factory", method: "POST", body: ["action": "resume"])
            return nil
        } catch {
            return (error as? DevError)?.message ?? "No pude reanudar la fábrica."
        }
    }
}
