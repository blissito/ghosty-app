import Foundation
import Observation

/// Los pedidos de la fábrica de todos tus espacios. Compartido por la entrada de Perfil (que sólo
/// aparece si hay algo que ver) y por la pantalla de la fábrica.
@MainActor @Observable
final class FactoryStore {
    static let shared = FactoryStore()

    /// Los espacios con la fábrica a la mano: primero los que tienen pedidos (en el orden de gs) y
    /// luego los vacíos, que enseñan «Conecta tu primer repo».
    private(set) var spaces: [FactorySpace] = []
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var error: String?
    /// Un pedido que alguien pidió abrir desde fuera (Actividad): la pestaña lo empuja y lo limpia.
    var pendingRoute: FactoryRoute?
    private var loadedAt: Date?

    /// Un pedido mandado desde este teléfono que todavía no es run: @plan lo está leyendo, propuso un
    /// sprint, dejó ideas o preguntó algo. Vive aquí (no en gs) porque es «lo que YO pedí»; se va solo
    /// cuando nace su run o a los 3 días.
    struct PendingThread: Codable, Hashable, Identifiable {
        let slug: String
        let room: String
        let threadId: Int
        let text: String
        let at: Date
        var id: Int { threadId }
    }
    private(set) var pendingThreads: [PendingThread] = FactoryStore.loadPending()
    /// En qué quedó cada pedido pendiente (lo último que se leyó de su hilo).
    private(set) var threadState: [Int: FactoryThread] = [:]
    /// Los sprints de cada espacio (borradores y activos, más los terminados recientes).
    private(set) var sprints: [String: [FactorySprintRow]] = [:]

    private static let pendingKey = "fabrica.pendientes"
    @ObservationIgnored private var demoSeeded = false

    private static func loadPending() -> [PendingThread] {
        guard let d = UserDefaults.standard.data(forKey: pendingKey),
              let all = try? JSONDecoder().decode([PendingThread].self, from: d) else { return [] }
        return all.filter { Date().timeIntervalSince($0.at) < 3 * 86400 }
    }

    private func savePending() {
        // La demo no deja rastro: cada arranque empieza con sus cuatro pedidos.
        if DemoData.encendido { return }
        if let d = try? JSONEncoder().encode(pendingThreads) { UserDefaults.standard.set(d, forKey: Self.pendingKey) }
    }

    func addPending(slug: String, room: String, threadId: Int, text: String) {
        guard !pendingThreads.contains(where: { $0.threadId == threadId }) else { return }
        pendingThreads.insert(PendingThread(slug: slug, room: room, threadId: threadId, text: text, at: Date()), at: 0)
        savePending()
    }

    /// Lo que se leyó de un hilo: si ya nació su run, deja de estar pendiente.
    func noteThread(_ t: FactoryThread, id: Int) {
        threadState[id] = t
        if t.run != nil, let i = pendingThreads.firstIndex(where: { $0.threadId == id }) {
            pendingThreads.remove(at: i)
            savePending()
        }
    }

    /// Un sprint recién leído o cambiado (aprobado, un ticket fuera): la fila de la lista y la
    /// tarjeta del hilo dicen lo mismo que la pantalla del sprint, sin esperar al siguiente sondeo.
    /// Sin esto, aprobar dejaba la fila en «Propuesto · te toca revisarlo».
    func noteSprint(_ s: FactorySprint, slug: String) {
        if var rows = sprints[slug], let i = rows.firstIndex(where: { $0.id == s.id }) {
            let r = rows[i]
            rows[i] = FactorySprintRow(id: r.id, title: s.title, status: s.status, repo: s.repo, room: r.room, threadId: r.threadId,
                                       total: s.included.count, merged: s.merged, updatedAt: Int(Date().timeIntervalSince1970))
            sprints[slug] = rows
        }
        for (id, t) in threadState where t.sprint?.id == s.id {
            threadState[id] = FactoryThread(channel: t.channel, root: t.root, messages: t.messages, run: t.run, sprint: s, working: t.working)
        }
    }

    func pending(_ slug: String) -> [PendingThread] { pendingThreads.filter { $0.slug == slug } }

    /// Sprints y pedidos pendientes de un espacio: la lista los repregunta junto con los runs.
    func refreshExtras(_ slug: String) async {
        if DemoData.encendido {
            sprints[slug] = Self.demoSprints
            for p in pending(slug) { if let t = Self.demoThread(p.threadId) { threadState[p.threadId] = t } }
            return
        }
        if let rows = try? await FactoryAPI.sprints(slug) { sprints[slug] = rows }
        for p in pending(slug).prefix(6) {
            if let t = try? await FactoryAPI.thread(slug, room: p.room, id: p.threadId) { noteThread(t, id: p.threadId) }
        }
    }

    /// La entrada «Fábrica» se enseña sólo si algún espacio tuyo tiene pedidos.
    var available: Bool { spaces.contains { !$0.runs.isEmpty } }

    /// Pedidos que esperan a una persona en todos los espacios: el número de la entrada.
    var needsYouCount: Int { spaces.reduce(0) { $0 + $1.runs.filter(\.stage.needsYou).count } }

    /// Alguien está trabajando en algún pedido: la pantalla repregunta cada 10 s.
    var anyWorking: Bool { spaces.contains { $0.runs.contains(where: \.stage.working) } || !pendingThreads.isEmpty }

    /// El aviso de Teams «contestó» trae la liga del hilo (`<espacio>.teams.ghosty.studio/c/<room>?thread=N`).
    /// Si es de un espacio con fábrica, se abre aquí, en la vista del pedido, no en Safari.
    func route(teamsLink url: URL) -> FactoryRoute? {
        guard let host = url.host, host.hasSuffix(".teams.ghosty.studio"),
              let slug = host.split(separator: ".").first.map(String.init), spaces.contains(where: { $0.slug == slug }) else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 3, parts[1] == "c",
              let thread = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "thread" })?.value,
              let id = Int(thread) else { return nil }
        // El hilo de un pedido que ya es run abre el run; si no, la conversación con @plan.
        if let run = spaces.first(where: { $0.slug == slug })?.runs.first(where: { $0.thread == id }) {
            return FactoryRoute(slug: slug, id: run.id)
        }
        return FactoryRoute(slug: slug, target: .thread(room: parts[2], id: id))
    }

    /// `force: false` no repite si lo último tiene menos de 30 s (Perfil se abre a menudo).
    func refresh(force: Bool = true) async {
        if DemoData.encendido {
            spaces = Self.demo
            if !demoSeeded { pendingThreads = Self.demoPending; demoSeeded = true }
            loaded = true
            return
        }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 30 { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let mine = try await FactoryAPI.spaces()
            // Cada espacio por su lado: uno sin Teams (o caído) no tumba a los demás.
            let found = await withTaskGroup(of: (Int, FactorySpace?).self) { group in
                for (i, s) in mine.enumerated() {
                    group.addTask {
                        // Un espacio sin Teams (o caído) no sale; uno sin pedidos sí: ahí se conecta el primer repo.
                        guard let runs = try? await FactoryAPI.runs(s.slug).filter({ !Self.hidden(s.slug, $0.id) })
                        else { return (i, nil) }
                        return (i, FactorySpace(slug: s.slug, role: s.role, runs: runs))
                    }
                }
                var out: [(Int, FactorySpace)] = []
                for await (i, s) in group { if let s { out.append((i, s)) } }
                return out.sorted { ($0.1.runs.isEmpty ? 1 : 0, $0.0) < ($1.1.runs.isEmpty ? 1 : 0, $1.0) }.map(\.1)
            }
            spaces = found
            error = nil
            loadedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// Refresca un solo espacio (la lista abierta y su sondeo de 10 s).
    func refresh(space slug: String) async {
        if DemoData.encendido { return }
        guard let runs = try? await FactoryAPI.runs(slug).filter({ !Self.hidden(slug, $0.id) }),
              let i = spaces.firstIndex(where: { $0.slug == slug }) else { return }
        spaces[i].runs = runs
    }

    /// Gancho de desarrollo `GHOSTY_FABRICA_OCULTAR=business/114,…`: esos pedidos no salen en la
    /// lista (para grabar una toma limpia sin un pedido ajeno a la historia). En Release no existe.
    nonisolated static func hidden(_ slug: String, _ id: Int) -> Bool {
        guard let v = Gancho.valor("GHOSTY_FABRICA_OCULTAR") else { return false }
        return v.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "\(slug)/\(id)" }
    }

    /// Lo que se sabe de un pedido ya, sin red (para pintar el detalle al instante).
    func cached(_ slug: String, _ id: Int) -> FactoryRun? {
        spaces.first { $0.slug == slug }?.runs.first { $0.id == id }
    }

    // MARK: - Demo (`GHOSTY_DEMO=1`): sin red, para el recorrido de UI

    static let demoDetailMarkdown = """
    # Recordatorio por WhatsApp un día antes de la cita

    **Listo cuando:** cada cita confirmada recibe un WhatsApp 24 h antes con botón para confirmar o reagendar.

    ## Criterios de aceptación
    - El aviso sale una sola vez por cita, a la hora del negocio.
    - «Reagendar» abre la agenda con la cita ya elegida.
    - Una prueba cubre el caso de la cita cancelada (no se avisa).

    ## Pasos
    1. Barrido cada 15 min en `app/jobs/reminders.ts`.
    2. Plantilla aprobada de WhatsApp con dos botones.
    3. Pruebas del barrido con reloj falso.
    """

    private static func iso(_ minutesAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutesAgo * 60))
    }

    static var demo: [FactorySpace] {
        func run(_ id: Int, _ title: String, _ status: String, repo: String, pr: Int?, ago: Double,
                 min: Double?, usd: Double?, plan: Int = 1, kind: String = "sprint") -> FactoryRun {
            FactoryRun(id: id, title: title, status: status, kind: kind, room: "agenda", thread: 900 + id, repo: repo,
                       branch: nil, pr: pr.map { "https://github.com/demo/\(repo.split(separator: "/").last ?? "")/pull/\($0)" },
                       preview: nil, previewState: nil, planVersion: plan, loops: 0,
                       createdAt: iso(ago + (min ?? 10)), updatedAt: iso(ago), durationMin: min, usd: usd)
        }
        return [FactorySpace(slug: "demo", role: "OWNER", runs: [
            run(42, "Recordatorio por WhatsApp un día antes de la cita", "plan_review", repo: "demo/agenda", pr: nil, ago: 4, min: 6, usd: 0.41, plan: 2),
            run(41, "Bump the minor-and-patch group with 12 updates", "escalated", repo: "demo/agenda", pr: 88, ago: 25, min: 31, usd: 1.12, plan: 0, kind: "dependabot"),
            run(40, "Exportar la agenda del mes a Excel", "building", repo: "demo/agenda", pr: nil, ago: 1, min: 14, usd: 0.95),
            run(39, "Página de precios con el plan anual", "pr_review", repo: "demo/sitio", pr: 87, ago: 50, min: 42, usd: 2.30),
            run(38, "La lista de clientes busca por teléfono", "done", repo: "demo/agenda", pr: 86, ago: 180, min: 37, usd: 2.05),
            run(37, "Correo de bienvenida con el logo del negocio", "done", repo: "demo/sitio", pr: 85, ago: 600, min: 28, usd: 1.60),
        ])]
    }

    /// Los repos que «ve» la App en la demo: `demo/agenda` ya está en #agenda y `demo/inventario`
    /// contesta el 409 (la App no lo ve), para probar «Dar acceso en GitHub».
    static let demoHiddenRepo = "inventario"
    static var demoRepos: FactoryRepos {
        func repo(_ name: String, _ priv: Bool, _ lang: String?, _ ago: Double, _ rooms: [String] = [], _ desc: String? = nil) -> FactoryRepos.Repo {
            .init(repo: "demo/\(name)", private: priv, description: desc, language: lang, pushedAt: iso(ago), rooms: rooms)
        }
        return FactoryRepos(factoryInstalled: true, connected: true, installed: true, installUrl: nil, detail: nil, repos: [
            repo("agenda", true, "TypeScript", 30, ["agenda"], "Citas y recordatorios"),
            repo("tienda", false, "TypeScript", 95, [], "La tienda en línea"),
            repo("sitio", false, "Astro", 400, ["sitio"]),
            repo(demoHiddenRepo, true, "Python", 2900),
            repo("facturas", true, "Go", 9000, [], "Timbrado CFDI"),
            repo("landing-2024", false, "HTML", 200_000),
        ])
    }
    static let demoRooms: [FactoryRooms.Room] = [
        .init(slug: "agenda", name: "agenda", private: false, repos: ["demo/agenda"], factory: true),
        .init(slug: "sitio", name: "sitio", private: false, repos: ["demo/sitio"], factory: true),
        .init(slug: "general", name: "general", private: false, repos: [], factory: false),
    ]

    /// La recomendación de la demo para el pedido escalado (#41).
    static let demoAdvice = FactoryAdvice(
        decision: "fix",
        why: "Los dos errores caben en la subida: son ajustes de tipos y de lint que pide la versión nueva, no un cambio de plan.",
        buildNote: [
            .init(point: "En `app/routes/dash.tsx:636`, convertir la etiqueta con `String(label)`.", cites: "typecheck: `labelFormatter` ahora recibe `ReactNode`"),
            .init(point: "En `scripts/verify.mjs:24`, dar cuerpo con llaves al callback.", cites: "biome: `useIterableCallbackReturn`"),
        ],
        checkScope: "Sólo esos dos arreglos y que el CI quede verde.",
        confidence: "high",
        note: "1. En `app/routes/dash.tsx:636`, convertir la etiqueta con `String(label)`.\n2. En `scripts/verify.mjs:24`, dar cuerpo con llaves al callback.")

    /// @build a media vuelta en el #40: cinco pasos hechos, uno abierto y un atasco vigente.
    static func demoLive(_ id: Int) -> FactoryLive? {
        guard demo.first?.runs.first(where: { $0.id == id })?.stage == .building else { return nil }
        let steps: [FactoryLive.Step] = [
            .init(id: "1", title: "Repasé mi guía", kind: "guide", detail: "factory build", status: "ok", secs: 2),
            .init(id: "2", title: "Leí", kind: "read", detail: "app/routes/agenda.tsx", status: "ok", secs: 1),
            .init(id: "3", title: "Busqué", kind: "search", detail: "exportMonth", status: "ok", secs: 1),
            .init(id: "4", title: "Corregí", kind: "edit", detail: "app/lib/export.ts", status: "ok", secs: 3),
            .init(id: "5", title: "Corrí un comando", kind: "execute", detail: "npm test -- export", status: "failed", secs: 41),
            .init(id: "6", title: "Corriendo un comando", kind: "execute", detail: "npm install", status: "running", secs: 372),
        ]
        return FactoryLive(running: [.init(role: "build", since: iso(3), now: "Corriendo un comando · npm install", steps: steps,
                                           stalled: .init(human: "lleva 6 min en `npm install` sin terminar.", rule: "long_command", since: iso(6)))])
    }

    static func demoDetail(_ id: Int) -> FactoryRunDetail? {
        guard let r = demo.first?.runs.first(where: { $0.id == id }) else { return nil }
        let plan = r.stage == .escalated ? nil : FactoryRunDetail.Plan(version: r.planVersion, decision: r.stage == .planReview ? nil : "approve", markdown: demoDetailMarkdown)
        var events: [FactoryRunDetail.Event] = [
            .init(at: iso(4), actor: "plan", type: "plan_submitted", data: nil),
        ]
        if r.stage == .escalated {
            events = [.init(at: iso(25), actor: "check", type: "check_blocked",
                            data: .object(["findings": .string("CI rojo por la subida: falla typecheck.\n- `app/routes/dash.tsx:636` — `labelFormatter` ahora recibe `ReactNode`. Arreglo: `String(label)`.\n- `scripts/verify.mjs:24` — biome marca `useIterableCallbackReturn`. Arreglo: cuerpo con llaves.\nLo que hace falta: meter esos dos arreglos en la rama del PR.")])),
                      .init(at: iso(56), actor: "dependabot", type: "adopted", data: nil)]
        }
        if r.stage == .building {
            // Otra vuelta tras escalar: la firma con nota y alcance, y un atasco que ya se avisó.
            let note = "1. Mover `exportMonth` a `app/lib/export.ts`.\n2. Probar el mes vacío."
            events = [.init(at: iso(2), actor: nil, type: "stuck_notified", data: .object(["role": .string("build")])),
                      .init(at: iso(2), actor: nil, type: "stuck",
                            data: .object(["role": .string("build"), "human": .string("lleva 6 min en `npm install` sin terminar.")])),
                      .init(at: iso(9), actor: "Brenda", type: "note", data: .object(["text": .string(note)])),
                      .init(at: iso(9), actor: "Brenda", type: "approve",
                            data: .object(["note": .string(note), "checkScope": .string("Sólo esos dos puntos.")])),
                      .init(at: iso(20), actor: "check", type: "check_fail", data: nil)] + events
        }
        let running = r.stage.working ? [FactoryRunDetail.Running(role: r.stage == .building ? "build" : r.stage == .checking ? "check" : "plan", since: iso(3))] : []
        return FactoryRunDetail(id: r.id, title: r.title, status: r.status, kind: r.kind, room: r.room, thread: r.thread,
                                repo: r.repo, branch: r.branch, pr: r.pr, preview: nil, previewState: nil,
                                planVersion: r.planVersion, loops: r.loops, updatedAt: r.updatedAt, plan: plan,
                                plans: plan.map { [.init(version: $0.version, decision: $0.decision, title: r.title)] } ?? [],
                                events: events, running: running)
    }
}
