import Foundation

/// El plan personal y cuánto lleva (`GET /api/v2/me/usage`). Los montos de gs son pesos de
/// COSTO: la app sólo enseña porcentajes y fechas, igual que /c/uso.
struct PersonalUsage: Decodable, Equatable, Sendable {
    struct Plan: Decodable, Equatable, Sendable {
        let key: String
        let name: String
        /// «low» | «high». nil = gs viejo: se deduce del plan.
        var imageQuality: String? = nil
    }
    struct Window: Decodable, Equatable, Sendable {
        /// nil = el plan no tiene tope en esta ventana (Gratis sólo tiene semana).
        let pct: Double?
        let resetsAt: Date
    }

    let plan: Plan
    let week: Window
    let month: Window
    /// ¿El plan personal cubre a ESTE agente? false = es de un workspace o compartido.
    let applies: Bool?
    let imagesWeek: Int?
    /// Cuántas más alcanzan con lo que queda (salen del mismo presupuesto que el chat).
    let imagesLeft: Int?
    /// Conteo semanal de imágenes (early adopters, ajustes). nil = sólo el presupuesto.
    var imagesCap: Int? = nil
    /// Cuántas quedarían si todas fueran HD (sólo si el plan deja pedir HD).
    var imagesLeftHd: Int? = nil
    /// Agente de workspace (y eres miembro): la barra del espacio, la misma de Teams.
    let workspace: WorkspaceUsage?
    /// El agente corre con la llave PROPIA del dueño: no gasta del plan.
    var ownKey: OwnKey? = nil
    /// Llave propia de OpenAI: las imágenes no gastan del plan ni se cuentan.
    var ownImageKey: Bool? = nil
    /// Cuántas de las imágenes de la semana salieron en HD.
    var imagesWeekHd: Int? = nil
    /// Acceso anticipado: el tope de chat no le aplica (el de imágenes sí).
    var exempt: Bool? = nil
    /// false = su modelo no está en el plan y el turno se va a frenar.
    var modelAllowedInPlan: Bool? = nil
    /// Sin plan y sin recargas.
    var exhausted: Bool? = nil

    struct OwnKey: Decodable, Equatable, Sendable {
        let provider: String
        /// Sin límite no es sin medir: lo que lleva esta semana con su llave.
        var turnsWeek: Int? = nil
        var tokensWeek: Int? = nil
        /// Turnos por día (lunes = 0) para la gráfica de la semana.
        var dailyTurns: [Int]? = nil
    }

    struct WorkspaceUsage: Decodable, Equatable, Sendable {
        let name: String
        let pct: Double
        let resetsAt: Date
    }

    static func decode(_ data: Data) -> PersonalUsage? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: s))
        }
        return try? d.decode(PersonalUsage.self, from: data)
    }
}
