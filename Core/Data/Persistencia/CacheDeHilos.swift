import Foundation
import Observation
import GRDB

/// Las conversaciones, guardadas en este teléfono.
///
/// ⚠️ **Qué se guarda y qué no, y por qué.** Todo lo del hilo se le pide hoy a la caja:
/// abrir el historial cuesta despertarla (segundos) más `session/list`, y abrir un hilo
/// cuesta un `session/load` entero. Nada de eso sobrevivía a cerrar la app.
///
/// Se guardan DOS cosas por agente:
/// - **La lista de hilos**, para pintar el historial al instante.
/// - **El hilo abierto**, para que la app te devuelva donde la dejaste.
///
/// Y NO se guardan los demás hilos, que es donde se satura el teléfono sin comprar nada:
/// el replay es la verdad —un hilo puede haber avanzado desde otro cliente— y bajarlo es
/// justo lo que hay que hacer cuando lo abres.
///
/// Desde sync v2 vive en la base local (`LocalDB`): cada hilo se escribe solo y guarda con
/// qué copia de gs coincide.
@Observable
@MainActor
final class CacheDeHilos {
    /// El mismo número que la bitácora de turnos. Un hilo más largo se recorta por el
    /// principio: lo que importa al volver es el final.
    nonisolated private static let tope = 200
    /// Cuántas conversaciones por agente se guardan. Son las que retomas, no un archivo:
    /// el archivo es la caja. 20, como WhatsApp: abrir cualquiera de las recientes pinta
    /// al instante (lo que precarga `LiveAgentStore.precargarChats`).
    nonisolated static let topeDeHilos = 20

    // MARK: - Lo que había antes (sólo para migrarlo una vez)

    private struct Disco: Codable {
        var version = 2
        var lista: [String: [SesionGuardada]] = [:]
        var abiertos: [String: [String: [MensajeGuardado]]] = [:]
        var sospechosos: [String] = []
    }

    private struct DiscoV1: Codable {
        struct Guardado: Codable { var sesionID: String; var mensajes: [MensajeGuardado] }
        var lista: [String: [SesionGuardada]] = [:]
        var abierto: [String: Guardado] = [:]
    }

    private var legacyFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appending(path: "hilos.json")
    }

    private let db = LocalDB.queue
    nonisolated(unsafe) private static let encoder = JSONEncoder()
    nonisolated(unsafe) private static let decoder = JSONDecoder()

    init() {
        migrateLegacyFile()
    }

    /// ⚠️ Una sola vez: `hilos.json` pasa a la base y se borra. Las conversaciones del
    /// formato v1 (que podían estar cruzadas) entran marcadas como sospechosas.
    private func migrateLegacyFile() {
        guard let db, let d = try? Data(contentsOf: legacyFile) else { return }
        var disco = Disco()
        if let leido = try? Self.decoder.decode(Disco.self, from: d), leido.version == 2 {
            disco = leido
        } else if let viejo = try? Self.decoder.decode(DiscoV1.self, from: d) {
            disco.lista = viejo.lista
            for (agente, g) in viejo.abierto {
                disco.abiertos[agente] = [g.sesionID: g.mensajes]
                disco.sospechosos.append(g.sesionID)
            }
        }
        do {
            try db.write { db in
                for (agent, list) in disco.lista {
                    try Self.writeList(db, agent, list)
                }
                for (agent, threads) in disco.abiertos {
                    for (sid, messages) in threads {
                        try Self.writeThread(db, agent, sid, messages,
                                             suspicious: disco.sospechosos.contains(sid))
                    }
                }
            }
            try FileManager.default.removeItem(at: legacyFile)
            EasyBitsClient.diag("[db] migré hilos.json: \(disco.abiertos.values.map(\.count).reduce(0, +)) conversaciones")
        } catch {
            EasyBitsClient.diag("[db] no pude migrar hilos.json: \(error)")
        }
    }

    // MARK: - La lista

    func lista(_ agentID: String) -> [ACPClient.Session] {
        let data = try? db?.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM agentList WHERE agentId = ?", arguments: [agentID])
        }
        guard let data, let list = try? Self.decoder.decode([SesionGuardada].self, from: data) else { return [] }
        return list.map(\.sesion)
    }

    func guardarLista(_ hilos: [ACPClient.Session], de agentID: String) {
        let list = hilos.map(SesionGuardada.init)
        db?.asyncWrite({ db in try Self.writeList(db, agentID, list) }, completion: Self.logFailure)
    }

    // MARK: - Los hilos guardados

    /// Todas las conversaciones guardadas de un agente.
    func abiertos(_ agentID: String) -> [(sesionID: String, mensajes: [Message], sospechoso: Bool)] {
        (try? db?.read { db -> [(sesionID: String, mensajes: [Message], sospechoso: Bool)] in
            let rows = try Row.fetchAll(db, sql: "SELECT sessionId, suspicious FROM thread WHERE agentId = ?",
                                        arguments: [agentID])
            return try rows.map { r in
                let sid: String = r["sessionId"]
                return (sid, try Self.readMessages(db, agentID, sid), r["suspicious"])
            }
        }) ?? []
    }

    /// Olvida UNA conversación. Es lo que hace que cerrarla sea de verdad.
    func olvidarAbierta(_ sesion: String, de agentID: String) {
        db?.asyncWrite({ db in try Self.deleteThread(db, agentID, sesion) }, completion: Self.logFailure)
    }

    func abierto(_ agentID: String, sesion: String) -> [Message]? {
        try? db?.read { db -> [Message]? in
            guard try Bool.fetchOne(db, sql: "SELECT 1 FROM thread WHERE agentId = ? AND sessionId = ?",
                                    arguments: [agentID, sesion]) != nil else { return nil }
            return try Self.readMessages(db, agentID, sesion)
        }
    }

    /// ⚠️ FUNDE con lo que ya había en vez de reemplazarlo: una conversación vacía en
    /// memoria por un tropiezo no se lleva su copia del disco. Sólo se recorta lo que sobra
    /// del tope, por lo menos reciente.
    func guardarAbiertos(_ hilos: [(sesionID: String, mensajes: [Message])], de agentID: String) {
        let batch = hilos.suffix(Self.topeDeHilos).compactMap { h -> (String, [MensajeGuardado])? in
            let saved = h.mensajes.compactMap(MensajeGuardado.init)
            return saved.isEmpty ? nil : (h.sesionID, saved)
        }
        guard !batch.isEmpty else { return }
        db?.asyncWrite({ db in
            for (sid, messages) in batch { try Self.writeThread(db, agentID, sid, messages, suspicious: false) }
            try Self.trim(db, agentID)
        }, completion: Self.logFailure)
    }

    /// Guarda UNA conversación bajada en segundo plano. Si no cabe, no desplaza a ninguna.
    func guardarUno(_ agentID: String, sesion: String, mensajes: [Message]) {
        let saved = mensajes.compactMap(MensajeGuardado.init)
        guard !saved.isEmpty else { return }
        db?.asyncWrite({ db in
            let exists = try Bool.fetchOne(db, sql: "SELECT 1 FROM thread WHERE agentId = ? AND sessionId = ?",
                                           arguments: [agentID, sesion]) != nil
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread WHERE agentId = ?",
                                         arguments: [agentID]) ?? 0
            guard exists || count < Self.topeDeHilos else { return }
            // ⚠️ Fría: lo precargado no cuenta como usado, o desalojaría el hilo que sí abriste.
            try Self.writeThread(db, agentID, sesion, saved, suspicious: false, touch: false)
        }, completion: Self.logFailure)
    }

    // MARK: - Con qué copia de gs coincide (sync v2)

    func meta(_ agentID: String, session: String) -> ThreadMeta? {
        try? db?.read { db -> ThreadMeta? in
            guard let r = try Row.fetchOne(db, sql: """
                SELECT epoch, lastSeq, oldestSeq, hasMoreBefore FROM thread WHERE agentId = ? AND sessionId = ?
                """, arguments: [agentID, session]) else { return nil }
            return ThreadMeta(epoch: r["epoch"], lastSeq: r["lastSeq"], oldestSeq: r["oldestSeq"],
                              hasMoreBefore: r["hasMoreBefore"])
        }
    }

    func saveMeta(_ meta: ThreadMeta, _ agentID: String, session: String) {
        db?.asyncWrite({ db in
            try db.execute(sql: """
                INSERT INTO thread (agentId, sessionId, epoch, lastSeq, oldestSeq, hasMoreBefore, touchedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(agentId, sessionId) DO UPDATE SET
                  epoch = excluded.epoch, lastSeq = excluded.lastSeq,
                  oldestSeq = excluded.oldestSeq, hasMoreBefore = excluded.hasMoreBefore
                """, arguments: [agentID, session, meta.epoch, meta.lastSeq, meta.oldestSeq,
                                 meta.hasMoreBefore, Date().timeIntervalSince1970])
        }, completion: Self.logFailure)
    }

    func syncCursor(_ key: String) -> String? {
        try? db?.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [key])
        }
    }

    func setSyncCursor(_ value: String, for key: String) {
        db?.asyncWrite({ db in
            try db.execute(sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES (?, ?)", arguments: [key, value])
        }, completion: Self.logFailure)
    }

    // MARK: - Olvidar

    func olvidar(_ agentID: String) {
        db?.asyncWrite({ db in
            try db.execute(sql: "DELETE FROM agentList WHERE agentId = ?", arguments: [agentID])
            try db.execute(sql: "DELETE FROM message WHERE agentId = ?", arguments: [agentID])
            try db.execute(sql: "DELETE FROM thread WHERE agentId = ?", arguments: [agentID])
        }, completion: Self.logFailure)
    }

    func limpiar() {
        db?.asyncWrite({ db in
            for table in ["agentList", "message", "thread", "syncState"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }, completion: Self.logFailure)
    }

    // MARK: - SQL

    nonisolated private static func writeList(_ db: Database, _ agent: String, _ list: [SesionGuardada]) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO agentList (agentId, payload) VALUES (?, ?)",
                       arguments: [agent, try encoder.encode(list)])
    }

    /// Reescribe los mensajes de UN hilo (no los de todos) y conserva su `epoch`/`lastSeq`.
    nonisolated private static func writeThread(_ db: Database, _ agent: String, _ sid: String,
                                    _ messages: [MensajeGuardado], suspicious: Bool, touch: Bool = true) throws {
        let kept = Array(messages.suffix(tope))
        // `touchedAt` = cuándo la USASTE (abrir, escribir). Es lo que decide qué se desaloja.
        try db.execute(sql: touch ? """
            INSERT INTO thread (agentId, sessionId, suspicious, touchedAt) VALUES (?, ?, ?, ?)
            ON CONFLICT(agentId, sessionId) DO UPDATE SET suspicious = excluded.suspicious, touchedAt = excluded.touchedAt
            """ : """
            INSERT INTO thread (agentId, sessionId, suspicious, touchedAt) VALUES (?, ?, ?, 0)
            ON CONFLICT(agentId, sessionId) DO UPDATE SET suspicious = excluded.suspicious
            """, arguments: touch ? [agent, sid, suspicious, Date().timeIntervalSince1970] : [agent, sid, suspicious])
        try db.execute(sql: "DELETE FROM message WHERE agentId = ? AND sessionId = ?", arguments: [agent, sid])
        for (i, m) in kept.enumerated() {
            try db.execute(sql: "INSERT INTO message (agentId, sessionId, position, id, seq, payload) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [agent, sid, i, m.id, m.seq, try encoder.encode(m)])
        }
        // Lo recortado por el principio ya no está aquí: lo de antes hay que pedirlo.
        if messages.count > kept.count, let first = kept.first(where: { $0.seq != nil })?.seq {
            try db.execute(sql: "UPDATE thread SET oldestSeq = ?, hasMoreBefore = 1 WHERE agentId = ? AND sessionId = ?",
                           arguments: [first, agent, sid])
        }
    }

    nonisolated private static func readMessages(_ db: Database, _ agent: String, _ sid: String) throws -> [Message] {
        try Data.fetchAll(db, sql: "SELECT payload FROM message WHERE agentId = ? AND sessionId = ? ORDER BY position",
                          arguments: [agent, sid])
            .compactMap { try? decoder.decode(MensajeGuardado.self, from: $0).mensaje }
    }

    nonisolated private static func deleteThread(_ db: Database, _ agent: String, _ sid: String) throws {
        try db.execute(sql: "DELETE FROM message WHERE agentId = ? AND sessionId = ?", arguments: [agent, sid])
        try db.execute(sql: "DELETE FROM thread WHERE agentId = ? AND sessionId = ?", arguments: [agent, sid])
    }

    /// Sólo se quedan las `topeDeHilos` más recientes de cada agente.
    nonisolated private static func trim(_ db: Database, _ agent: String) throws {
        let extra = try String.fetchAll(db, sql: """
            SELECT sessionId FROM thread WHERE agentId = ? ORDER BY touchedAt DESC LIMIT -1 OFFSET ?
            """, arguments: [agent, topeDeHilos])
        for sid in extra { try deleteThread(db, agent, sid) }
    }

    nonisolated private static let logFailure: @Sendable (Database, Result<Void, Error>) -> Void = { _, result in
        if case .failure(let e) = result { EasyBitsClient.diag("[db] no pude escribir: \(e)") }
    }
}
