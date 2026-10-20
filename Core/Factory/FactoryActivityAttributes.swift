import ActivityKit
import Foundation

/// La Live Activity de un pedido de la Fábrica: «@build está construyendo…» en la pantalla
/// bloqueada y la Dynamic Island. La compila también la extensión `FabricaActividad` (sólo este
/// archivo, no `Core/` entero): es el contrato entre la app, el widget y gs.
///
/// ⚠️ `ContentState` lo arma gs (`factory-live-activity.server.ts`, `FactoryActivityState`) y llega
/// por push: mismos nombres y tipos. Un campo NO opcional que gs no mande tira la actualización sin
/// error; por eso todo lo que puede faltar es opcional, y las fechas van en segundos Unix (el
/// decodificador de ActivityKit las leería desde 2001).
struct FactoryActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stage: String
        var headline: String
        var now: String?
        var stepsDone: Int
        var stalled: String?
        var needsYou: Bool
        /// Segundos Unix desde que arrancó el turno del rol: el reloj de la isla.
        var since: Double?

        var sinceDate: Date? { since.map { Date(timeIntervalSince1970: $0) } }
    }

    let slug: String
    let runId: Int
    let title: String
}
