import Foundation

// Lo que gs calcula para cada fila de Desarrollo y el cliente sólo pinta (24-nov-2026):
// `actions` (qué botones hay), `compose` (a dónde irá un mensaje) y `claim` (la última señal de la terminal).
// Una acción que esta versión no conoce NUNCA se esconde: sale como botón neutro con su `label`.

struct DevAction: Identifiable, Hashable {
    enum Kind: Hashable {
        case op, link, start
        /// GET de sólo lectura a `href` (p. ej. la cola del log de la caja): se muestra el texto.
        case read
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
    /// Campos que se piden antes de ejecutar (`edit_criterion`); van con su `name` en el cuerpo del POST.
    var fields: [DevActionField] = []

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
        case "read": kind = .read
        case let k?: kind = .other(k)
        case nil: kind = (j["href"] as? String) != nil ? .link : .op
        }
        let disabled = j["disabled"] as? [String: Any]
        return DevAction(id: id, label: label, kind: kind, op: j["op"] as? String,
                         href: (j["href"] as? String).flatMap(URL.init(string:)),
                         confirm: (j["confirm"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                         destructive: j["destructive"] as? Bool ?? false, primary: j["primary"] as? Bool ?? false,
                         isDisabled: disabled != nil, disabledWhy: disabled?["why"] as? String,
                         fields: (j["fields"] as? [[String: Any]] ?? []).compactMap(DevActionField.from(json:)))
    }

    /// `nil` = el servidor no mandó `actions` (gs viejo): ahí se usa el respaldo calculado en el cliente.
    static func list(from any: Any?) -> [DevAction]? {
        guard let arr = any as? [[String: Any]] else { return nil }
        return arr.compactMap(DevAction.from(json:))
    }
}

/// «Qué sigue y a quién le toca» (`next` de gs, la misma fuente que la web): `owner` = you · nobody · agent · ghosty · blocked.
struct DevNext: Hashable {
    let label: String
    let owner: String
    let why: String?

    static func from(json j: Any?) -> DevNext? {
        guard let d = j as? [String: Any], let label = d["label"] as? String, !label.isEmpty else { return nil }
        return DevNext(label: label, owner: d["owner"] as? String ?? "", why: (d["why"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// El renglón de la tarjeta, como la web: «Siguiente: En fila · le toca a Ghosty».
    var ownerText: String {
        switch owner {
        case "you": "te toca a ti"
        case "nobody": "no le toca a nadie ahora"
        case "agent": "le toca al agente"
        case "ghosty": "le toca a Ghosty"
        case "blocked": "en espera"
        default: owner
        }
    }
    /// Pide a la persona: le toca a ella o a nadie.
    var wantsPerson: Bool { owner == "you" || owner == "nobody" }

    /// La regla de «N te necesitan» (`needsAttention` de gs): nunca lo que no ha empezado, lo que está en fila,
    /// lo que espera a otro pendiente ni lo cerrado.
    func needsAttention(phase: String, notStarted: Bool, blocked: Bool) -> Bool {
        if owner == "you" { return !notStarted }
        guard owner == "nobody" else { return false }
        return !notStarted && !blocked && !["queued", "blocked", "merged", "done", "stopped", "failed"].contains(phase)
    }
}

/// `attempts` llega como arreglo (lista) o número (tarjeta de PR vieja).
func devAttemptsCount(_ any: Any?) -> Int {
    if let a = any as? [Any] { return a.count }
    return any as? Int ?? 0
}

/// Un campo que gs pide antes de ejecutar una acción («Número del criterio», «Texto nuevo»).
struct DevActionField: Hashable, Identifiable {
    let name: String
    let label: String
    /// `number` | `text`
    let type: String
    var id: String { name }

    static func from(json j: [String: Any]) -> DevActionField? {
        guard let name = j["name"] as? String, !name.isEmpty else { return nil }
        return DevActionField(name: name, label: j["label"] as? String ?? name, type: j["type"] as? String ?? "text")
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

/// Lo que pasaría al mandar un pendiente a la nube AHORA (`GET …/dev-runs/capacity`), sin hacerlo.
struct DevCapacity: Equatable {
    let slots: Int
    let used: Int
    let fits: Bool
    let queued: Bool
    /// PRs cuya vista previa se apagaría para hacer lugar.
    let evicts: [Int]
    let minutes: Int?
    let buyURL: URL?

    /// El renglón de la ficha: «Cajas: 6 de 6 ocupadas · apagaría la vista previa del PR #152 · ~44 min».
    var line: String {
        var parts = ["Cajas: \(used) de \(slots) ocupadas"]
        if !fits {
            if !evicts.isEmpty { parts.append("apagaría la vista previa del PR " + evicts.map { "#\($0)" }.joined(separator: ", ")) }
            else if queued { parts.append("quedaría en fila") }
            else { parts.append("no hay caja libre") }
        }
        if let m = minutes, m > 0 { parts.append("~\(m) min") }
        return parts.joined(separator: " · ")
    }
    /// Sin lugar, sin nada que apagar y sin fila: mandarlo sólo acabaría en «sin caja libre».
    var blocked: Bool { !fits && evicts.isEmpty && !queued }
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
    /// Lo que devolvió una acción `read` (el log de la caja).
    case text(String)
    case failed(String)
}

extension DevStore {
    /// Cabe o no un pendiente de `repo` en la nube ahora (1 s; falla callado).
    func capacity(repo: String) async -> DevCapacity? {
        guard let j = try? await request("api/v2/me/dev-runs/capacity", query: [URLQueryItem(name: "repo", value: repo)]) as? [String: Any],
              let slots = j["slots"] as? Int else { return nil }
        return DevCapacity(slots: slots, used: j["used"] as? Int ?? 0, fits: j["fits"] as? Bool ?? true, queued: j["queued"] as? Bool ?? false,
                           evicts: (j["evicts"] as? [[String: Any]] ?? []).compactMap { $0["pr"] as? Int },
                           minutes: (j["estimate"] as? [String: Any])?["minutes"] as? Int,
                           buyURL: (j["buyUrl"] as? String).flatMap(URL.init(string:)))
    }

    /// Ejecuta una acción del servidor. `runID` es el id de la tarjeta (`nil` en una fila `local` sin tarjeta).
    /// `values`: lo que la persona llenó en `fields`.
    /// Mismo camino que la web (`runServerAction` de gs) y que ghosty-dev: start = `claim --cloud`, release_claim = `unclaim`,
    /// edit_criterion = `criteria --set`, handoff_to_terminal = `teleport`, box_logs = `box logs`; el resto, `act` del run o del PR.
    func perform(_ a: DevAction, repo: String, issue: Int?, pr: Int? = nil, runID: String?, values: [String: Any] = [:]) async -> DevActionOutcome {
        switch a.kind {
        case .read:
            guard let h = a.href else { return .failed("Esta acción no trae qué leer.") }
            // `href` llega relativo (`/api/v2/me/…`): se pide con la sesión de la app.
            let path = h.absoluteString.hasPrefix("/") ? String(h.absoluteString.dropFirst()) : h.absoluteString
            if path.hasPrefix("http") { return .open(h) }
            var comps = URLComponents(string: path)
            let query = comps?.queryItems ?? []
            comps?.queryItems = nil
            do {
                let j = try await request(comps?.string ?? path, query: query) as? [String: Any]
                let t = (j?["text"] as? String) ?? ""
                return .text(t.isEmpty ? "(vacío)" : t)
            } catch {
                return .failed((error as? DevError)?.message ?? "No pude leerlo.")
            }
        case .link:
            if let u = a.href { return .open(u) }
            return .failed("Esta acción no trae a dónde ir.")
        case .start:
            // Como la web: con PR conocido va también (la nube adopta su rama en vez de empezar de cero); un PR sin
            // pendiente va como `{repo, pr, writer: cloud}` (= `claim --cloud --pr`).
            var body: [String: Any]
            if let issue, issue > 0 { body = ["repo": repo, "issue": issue]; if let pr { body["pr"] = pr } }
            else if let pr { body = ["repo": repo, "pr": pr, "writer": "cloud"] }
            else { return .failed("Falta el número del issue.") }
            body["from"] = "ios"
            do {
                let j = try await request("api/v2/me/dev-runs", method: "POST", body: body) as? [String: Any]
                // Arrancó: se abre el pendiente nuevo, como la web.
                let started = (j?["id"] as? String) ?? ((j?["started"] as? [String: Any])?["id"] as? String)
                Task { await refresh(); if let started { pendingRunID = started } }
                return .done
            } catch {
                return .failed((error as? DevError)?.message ?? "No se pudo. Intenta otra vez.")
            }
        case .op, .other:
            let op = a.op ?? a.id
            // Como en la web: `edit_criterion` va a la lista con `{op, repo, issue, …fields}`, sea nube, PR o terminal.
            if op == "edit_criterion" {
                guard let issue, issue > 0 else { return .failed("Falta el número del issue.") }
                var body: [String: Any] = ["op": op, "repo": repo, "issue": issue]
                for (k, v) in values { body[k] = v }
                return await post("api/v2/me/dev-runs", body, then: runID)
            }
            if op == "release_claim" {
                guard let issue, issue > 0 else { return .failed("Falta el número del issue.") }
                return await post("api/v2/me/dev-runs", ["op": "release_claim", "repo": repo, "issue": issue], then: runID)
            }
            // «Seguir en mi terminal»: gs detiene la nube y contesta el comando para traer la rama (= `ghosty-dev teleport`).
            if op == "handoff_to_terminal", let runID, Self.prPath(runID) == nil {
                do {
                    let j = try await request("api/v2/me/dev-runs/\(runID)", method: "POST", body: ["op": op, "from": "ios"]) as? [String: Any]
                    Task { await refresh() }
                    let h = j?["handoff"] as? [String: Any]
                    guard let cmd = h?["command"] as? String else { return .done }
                    return .text("Córrelo en tu terminal, dentro del repo:\n\n\(cmd)" + ((h?["branch"] as? String).map { "\n\nRama: \($0)" } ?? ""))
                } catch {
                    return .failed((error as? DevError)?.message ?? "No se pudo. Intenta otra vez.")
                }
            }
            // Run de la nube o tarjeta de PR (`act` sabe la ruta de cada uno, igual que `useDevRun` de la web).
            if let runID {
                if let err = await act(runID, op: op) { return .failed(err) }
                Task { await refresh() }
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
            // Ya salió: la lista se pone al día por detrás (antes el botón esperaba la recarga entera y parecía colgado).
            Task { await refresh(); if let runID { await loadDetail(runID) } }
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
            Task { await refresh() }
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
