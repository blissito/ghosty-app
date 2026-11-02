import Foundation
import Observation

/// Una línea de «Tareas»: lo que el agente trae entre manos, al estilo Things.
///
/// Sale de `GET /api/v2/me/agents/:agentId/tasks` → `items` (el servidor ya los manda
/// ordenados). Todo se decodifica tolerante: un gs viejo no manda `items` y la hoja sale vacía
/// en vez de fallar.
struct AgentTaskItem: Identifiable, Hashable {
    enum Source: String { case approval, askHuman = "ask_human", subagent, scheduled, note, background }
    enum Status: String { case needsYou = "needs_you", working, upcoming, done, failed }

    let id: String
    let source: Source?
    let title: String
    let status: Status
    let detail: String?
    let progress: (done: Int, total: Int)?
    let dueAt: Date?
    let updatedAt: Date?
    let doneAt: Date?
    let sessionID: String?
    let url: URL?

    /// Sólo las notas se palomean a mano; lo demás lo resuelve el agente (o tú en su hilo).
    var isCheckable: Bool { source == .note }
    var isResolved: Bool { status == .done || status == .failed }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.status == b.status && a.title == b.title && a.detail == b.detail
            && a.progress?.done == b.progress?.done && a.progress?.total == b.progress?.total
            && a.dueAt == b.dueAt && a.sessionID == b.sessionID
    }
    func hash(into h: inout Hasher) { h.combine(id) }

    func with(status: Status) -> AgentTaskItem {
        AgentTaskItem(id: id, source: source, title: title, status: status, detail: detail,
                      progress: progress, dueAt: dueAt, updatedAt: Date(),
                      doneAt: status == .done ? Date() : nil, sessionID: sessionID, url: url)
    }
}

/// Los conteos que manda gs junto a `items` (para la insignia sin recorrer la lista).
struct AgentTaskCounts: Equatable {
    var needsYou = 0, working = 0, upcoming = 0, done = 0

    /// El número de la insignia: lo que te espera; si nada, lo que está corriendo.
    var badge: Int { needsYou > 0 ? needsYou : working }
    var badgeIsAlert: Bool { needsYou > 0 }
    /// ¿Algo se mueve? Entonces se pregunta cada 10 s; si no, cada minuto.
    var isActive: Bool { needsYou > 0 || working > 0 }
}

/// El transporte de «Tareas». Aparte de `ClienteGS` por lo mismo que `AgendaGS`: no es el
/// turno, es una lista que se consulta.
enum AgentTasksGS {
    private static func url(_ agentID: String) -> URL {
        Session.base.appendingPathComponent("api/v2/me/agents/\(agentID)/tasks")
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFraction = ISO8601DateFormatter()

    private static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? isoNoFraction.date(from: s)
    }

    private static func request(_ url: URL, method: String = "GET",
                                body: [String: Any]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        r.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
        r.assumesHTTP3Capable = false
        r.timeoutInterval = 15
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let detail = json["detalle"] as? String ?? json["error"] as? String
            throw ACPClient.Fallo.remoto(detail ?? "El servidor contestó \(code).")
        }
        return json
    }

    static func parse(_ r: [String: Any]) -> AgentTaskItem? {
        guard let id = r["id"] as? String, let title = r["title"] as? String,
              let status = (r["status"] as? String).flatMap(AgentTaskItem.Status.init) else { return nil }
        var progress: (Int, Int)?
        if let p = r["progress"] as? [String: Any], let done = p["done"] as? Int,
           let total = p["total"] as? Int, total > 0 {
            progress = (min(done, total), total)
        }
        let detail = (r["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AgentTaskItem(id: id, source: (r["source"] as? String).flatMap(AgentTaskItem.Source.init),
                             title: title, status: status, detail: detail, progress: progress,
                             dueAt: date(r["dueAt"]), updatedAt: date(r["updatedAt"]),
                             doneAt: date(r["doneAt"]),
                             sessionID: (r["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                             url: (r["url"] as? String).flatMap(URL.init(string:)))
    }

    static func list(agentID: String) async throws -> ([AgentTaskItem], AgentTaskCounts) {
        let r = try await request(url(agentID))
        let items = (r["items"] as? [[String: Any]] ?? []).compactMap(parse)
        var counts = AgentTaskCounts()
        if let c = r["counts"] as? [String: Any] {
            counts.needsYou = c["needsYou"] as? Int ?? 0
            counts.working = c["working"] as? Int ?? 0
            counts.upcoming = c["upcoming"] as? Int ?? 0
            counts.done = c["done"] as? Int ?? 0
        } else {
            // Sin `counts` (no debería pasar) se cuentan aquí.
            for i in items {
                switch i.status {
                case .needsYou: counts.needsYou += 1
                case .working: counts.working += 1
                case .upcoming: counts.upcoming += 1
                case .done, .failed: counts.done += 1
                }
            }
        }
        return (items, counts)
    }

    static func setDone(agentID: String, itemID: String, done: Bool) async throws {
        _ = try await request(url(agentID), method: "POST", body: ["id": itemID, "done": done])
    }
}

/// Las tareas de cada agente, compartidas entre la cabecera del hilo (insignia) y la hoja.
@MainActor @Observable
final class AgentTasksStore {
    static let shared = AgentTasksStore()

    private(set) var items: [String: [AgentTaskItem]] = [:]
    private(set) var counts: [String: AgentTaskCounts] = [:]
    /// Ya contestó gs al menos una vez para ese agente (para no pintar «vacío» antes de saber).
    private(set) var loaded: Set<String> = []
    private(set) var error: [String: String] = [:]
    /// Palomeos en vuelo: la UI los pinta ya, sin esperar al servidor.
    private var overrides: [String: AgentTaskItem.Status] = [:]

    func items(for agentID: String) -> [AgentTaskItem] {
        (items[agentID] ?? []).map { i in overrides[i.id].map { i.with(status: $0) } ?? i }
    }

    func counts(for agentID: String) -> AgentTaskCounts { counts[agentID] ?? AgentTaskCounts() }

    func refresh(_ agentID: String) async {
        guard !agentID.isEmpty else { return }
        if DemoData.encendido {
            // Modo demo: una lista fija para poder mirar la hoja sin servidor.
            if items[agentID] == nil {
                let demo = Self.demoItems()
                items[agentID] = demo
                counts[agentID] = AgentTaskCounts(needsYou: 1, working: 1, upcoming: 2, done: 4)
            }
            loaded.insert(agentID)
            return
        }
        do {
            let (list, c) = try await AgentTasksGS.list(agentID: agentID)
            items[agentID] = list
            counts[agentID] = c
            loaded.insert(agentID)
            error[agentID] = nil
        } catch {
            // Un fallo de red no borra lo que ya había: se queda la foto anterior.
            self.error[agentID] = error.localizedDescription
            loaded.insert(agentID)
        }
    }

    /// Palomear (o despalomear) una nota. Optimista: si gs dice que no, se regresa.
    func toggle(_ item: AgentTaskItem, agentID: String) async {
        guard item.isCheckable else { return }
        let done = item.status != .done
        if DemoData.encendido {
            items[agentID] = items[agentID]?.map { $0.id == item.id ? $0.with(status: done ? .done : .upcoming) : $0 }
            return
        }
        overrides[item.id] = done ? .done : .upcoming
        do {
            try await AgentTasksGS.setDone(agentID: agentID, itemID: item.id, done: done)
            await refresh(agentID)
        } catch {
            self.error[agentID] = error.localizedDescription
        }
        overrides[item.id] = nil
    }

    private static func demoItems() -> [AgentTaskItem] {
        let now = Date()
        func item(_ id: String, _ src: AgentTaskItem.Source, _ title: String, _ st: AgentTaskItem.Status,
                  _ detail: String? = nil, _ progress: (Int, Int)? = nil, due: TimeInterval? = nil,
                  session: String? = nil) -> AgentTaskItem {
            AgentTaskItem(id: id, source: src, title: title, status: st, detail: detail, progress: progress,
                          dueAt: due.map { now.addingTimeInterval($0) }, updatedAt: now,
                          doneAt: st == .done ? now : nil, sessionID: session, url: nil)
        }
        return [
            item("ask:1", .askHuman, "Reservar hotel en Tokio", .needsYou, "¿Shinjuku o Ginza?", session: "demo"),
            item("sub:1", .subagent, "Comparar cotizaciones de imprenta", .working, "leyendo 3 de 4", (3, 4), session: "demo"),
            item("sched:1", .scheduled, "Resumen de ventas de la semana", .upcoming, due: 4 * 3600),
            item("note:1", .note, "Llamar a Brenda por la factura", .upcoming, due: 26 * 3600),
            item("note:2", .note, "Mandar catálogo a Oswaldo", .done),
            item("video:1", .background, "Montaje del video del taller", .done, session: "demo"),
            item("approval:1", .approval, "Publicar la landing", .failed, "se canceló el permiso"),
            item("note:3", .note, "Revisar ortografía del contrato", .done),
        ]
    }

    /// Cada cuánto preguntar: 10 s si algo se mueve o te espera, 60 s si no.
    func pollInterval(_ agentID: String) -> Duration {
        counts(for: agentID).isActive ? .seconds(10) : .seconds(60)
    }

    /// El bucle de refresco mientras alguien mire (la cabecera del hilo o la hoja).
    func poll(_ agentID: String) async {
        while !Task.isCancelled {
            await refresh(agentID)
            try? await Task.sleep(for: pollInterval(agentID))
        }
    }
}
