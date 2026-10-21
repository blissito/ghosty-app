import Foundation
import GRDB

/// Un 👍/👎 sobre una respuesta del agente. La clave es el TURNO (`turnId`): es lo único que
/// gs y el teléfono llaman igual, se recargue el hilo como se recargue.
struct Feedback: Equatable, Sendable {
    var agentID: String
    var sessionID: String
    var turnID: String
    /// 1 = 👍, -1 = 👎, 0 = voto quitado (sólo vive mientras gs no lo sabe).
    var rating: Int
    var comment: String?
    /// ¿Ya lo guardó gs? Lo no enviado se reintenta.
    var sent: Bool
    /// Cuándo se votó: si cambió mientras viajaba, la respuesta de gs ya no lo marca enviado.
    var at: Date
}

/// La tabla `feedback` de `LocalDB`. Pocas filas (una por respuesta votada): se lee entera al
/// arrancar y se escribe fila por fila.
enum FeedbackLedger {
    static func all() -> [Feedback] {
        (try? LocalDB.queue?.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM feedback").map { r in
                Feedback(agentID: r["agentId"], sessionID: r["sessionId"], turnID: r["turnId"],
                         rating: r["rating"], comment: r["comment"], sent: r["sent"],
                         at: Date(timeIntervalSince1970: r["at"]))
            }
        }) ?? []
    }

    static func save(_ f: Feedback) {
        LocalDB.queue?.asyncWrite({ db in
            try db.execute(sql: """
                INSERT INTO feedback (turnId, agentId, sessionId, rating, comment, sent, at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(turnId) DO UPDATE SET
                  agentId = excluded.agentId, sessionId = excluded.sessionId, rating = excluded.rating,
                  comment = excluded.comment, sent = excluded.sent, at = excluded.at
                """, arguments: [f.turnID, f.agentID, f.sessionID, f.rating, f.comment, f.sent,
                                 f.at.timeIntervalSince1970])
        }, completion: logFailure)
    }

    static func remove(_ turnID: String) {
        LocalDB.queue?.asyncWrite({ db in
            try db.execute(sql: "DELETE FROM feedback WHERE turnId = ?", arguments: [turnID])
        }, completion: logFailure)
    }

    nonisolated private static let logFailure: @Sendable (Database, Result<Void, Error>) -> Void = { _, result in
        if case .failure(let e) = result { EasyBitsClient.diag("[db] feedback: \(e)") }
    }
}
