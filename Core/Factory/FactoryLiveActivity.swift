#if !GHOSTY_EXTENSION
import ActivityKit
import Foundation

/// Prende, actualiza y apaga la Live Activity de un pedido desde la pantalla del pedido. Mientras
/// la app está viva la pinta ella en cada poleo; dormida, la mantiene gs por push con el token que
/// se le registra aquí (`…/factory/runs/:id/live-activity`). Se prende sola al abrir un pedido
/// en el que alguien trabaja, como Uber o los pedidos de comida: sin preguntar, y la persona la
/// apaga en Ajustes si no la quiere.
@MainActor
enum FactoryLiveActivity {
    /// Los tokens que ya se mandaron a gs (uno por actividad) y quién los está mirando.
    private static var watching: Set<String> = []

    static func sync(slug: String, run: FactoryRunDetail, live: FactoryLive?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let current = Activity<FactoryActivityAttributes>.activities.first { $0.attributes.slug == slug && $0.attributes.runId == run.id }
        let state = state(run, live)
        // Esperando la preview cuenta como trabajo: la plataforma la reintenta sola (20-oct).
        let working = run.stage.working || !run.running.isEmpty || run.escalationKind == .platform
        if let current {
            Task {
                if working {
                    await current.update(.init(state: state, staleDate: .now.addingTimeInterval(300)))
                } else {
                    // Te espera algo: se queda en la pantalla bloqueada 4 h; terminado, 15 min.
                    let stay: TimeInterval = state.needsYou ? 4 * 3600 : 15 * 60
                    await current.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(stay)))
                }
            }
            if working { watch(current, slug: slug, id: run.id) }
            return
        }
        guard working else { return }
        do {
            let a = try Activity.request(
                attributes: FactoryActivityAttributes(slug: slug, runId: run.id, title: run.title),
                content: .init(state: state, staleDate: .now.addingTimeInterval(300)),
                // El modo demo no habla con gs: la actividad se ve, pero no se registra.
                pushType: DemoData.encendido ? nil : .token)
            watch(a, slug: slug, id: run.id)
        } catch {
            EasyBitsClient.diag("[fabrica] live activity: \(error.localizedDescription)")
        }
    }

    /// Manda el token de push a gs en cuanto iOS lo da (y si cambia).
    private static func watch(_ a: Activity<FactoryActivityAttributes>, slug: String, id: Int) {
        guard !DemoData.encendido, !watching.contains(a.id) else { return }
        watching.insert(a.id)
        Task {
            for await data in a.pushTokenUpdates {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                try? await FactoryAPI.registerLiveActivity(slug, id, token: hex, environment: Avisos.entorno)
            }
        }
    }

    /// El mismo estado que arma gs (`activityState` en `factory-live-activity.server.ts`).
    static func state(_ run: FactoryRunDetail, _ live: FactoryLive?) -> FactoryActivityAttributes.ContentState {
        let stage = run.stage
        // Con varios roles a la vez manda el que arrancó al último: es el que se mueve.
        let r = live?.running.max(by: { $0.since < $1.since })
            ?? run.running.first.map { FactoryLive.Role(role: $0.role, since: $0.since, now: nil, steps: [], stalled: nil) }
        // gs decide si te toca: una escalada de plataforma no (20-oct). Su motivo es el titular.
        let needsYou = run.serverNeedsYou ?? (stage.needsYou && run.escalationKind != .platform)
        let reason = stage == .escalated ? run.escalation?.reason : nil
        let headline = stage == .escalated && run.escalationKind == .platform ? "Esperando la preview"
            : needsYou ? reason ?? FactoryFormat.headline(stage)
            : r.map { FactoryFormat.working($0.role) } ?? FactoryFormat.headline(stage)
        return .init(
            stage: run.status,
            headline: headline,
            now: needsYou ? nil : r?.now,
            stepsDone: r?.steps.filter { $0.status != "running" }.count ?? 0,
            stalled: needsYou ? nil : r?.stalled?.human,
            needsYou: needsYou,
            since: needsYou ? nil : r.flatMap { FactoryAPI.date($0.since)?.timeIntervalSince1970 })
    }
}
#endif
