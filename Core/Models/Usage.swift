import Foundation

/// El plan personal y cuánto lleva (`GET /api/v2/me/usage`). Los montos de gs son pesos de
/// COSTO: la app sólo enseña porcentajes y fechas, igual que /c/uso.
struct PersonalUsage: Decodable, Equatable, Sendable {
    struct Plan: Decodable, Equatable, Sendable {
        let key: String
        let name: String
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
