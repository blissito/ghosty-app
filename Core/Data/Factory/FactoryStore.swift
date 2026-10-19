import Foundation
import Observation

/// Los pedidos de la fábrica de todos tus espacios. Compartido por la entrada de Perfil (que sólo
/// aparece si hay algo que ver) y por la pantalla de la fábrica.
@MainActor @Observable
final class FactoryStore {
    static let shared = FactoryStore()

    /// Sólo los espacios con al menos un pedido, en el orden de gs (por slug).
    private(set) var spaces: [FactorySpace] = []
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var error: String?
    private var loadedAt: Date?

    /// La entrada «Fábrica» se enseña sólo si algún espacio tuyo tiene pedidos.
    var available: Bool { spaces.contains { !$0.runs.isEmpty } }

    /// Pedidos que esperan a una persona en todos los espacios: el número de la entrada.
    var needsYouCount: Int { spaces.reduce(0) { $0 + $1.runs.filter(\.stage.needsYou).count } }

    /// Alguien está trabajando en algún pedido: la pantalla repregunta cada 10 s.
    var anyWorking: Bool { spaces.contains { $0.runs.contains(where: \.stage.working) } }

    /// `force: false` no repite si lo último tiene menos de 30 s (Perfil se abre a menudo).
    func refresh(force: Bool = true) async {
        if DemoData.encendido {
            spaces = Self.demo
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
                        guard let runs = try? await FactoryAPI.runs(s.slug).filter({ !Self.hidden(s.slug, $0.id) }),
                              !runs.isEmpty else { return (i, nil) }
                        return (i, FactorySpace(slug: s.slug, role: s.role, runs: runs))
                    }
                }
                var out: [(Int, FactorySpace)] = []
                for await (i, s) in group { if let s { out.append((i, s)) } }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
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
        let running = r.stage.working ? [FactoryRunDetail.Running(role: r.stage == .building ? "build" : r.stage == .checking ? "check" : "plan", since: iso(3))] : []
        return FactoryRunDetail(id: r.id, title: r.title, status: r.status, kind: r.kind, room: r.room, thread: r.thread,
                                repo: r.repo, branch: r.branch, pr: r.pr, preview: nil, previewState: nil,
                                planVersion: r.planVersion, loops: r.loops, updatedAt: r.updatedAt, plan: plan,
                                plans: plan.map { [.init(version: $0.version, decision: $0.decision, title: r.title)] } ?? [],
                                events: events, running: running)
    }
}
