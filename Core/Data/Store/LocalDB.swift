import Foundation
import GRDB

/// La base local de conversaciones (SQLite vía GRDB).
///
/// ⚠️ Sustituye a `hilos.json`, que se reescribía ENTERO en cada guardado (todas las
/// conversaciones de todos los agentes) y no sabía nada del servidor. Aquí cada hilo se
/// escribe solo, y guarda con qué copia de gs coincide (`epoch`, `lastSeq`): es lo que
/// deja pedir sólo lo nuevo (`messages?after=`) en vez de bajar la cola entera.
///
/// Vive en el App Group para que la extensión de avisos pueda escribir el mensaje que
/// llega con el push (fase 7 de sync v2, `docs/claude/sync-v2.md` en gs).
enum LocalDB {
    /// La cola de la base. Lecturas síncronas; escrituras en orden (`asyncWrite`), y una
    /// lectura espera a las escrituras pendientes porque comparten la misma cola.
    static let queue: DatabaseQueue? = open()

    static var fileURL: URL {
        let dir = GrupoDeApp.contenedor
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "conversations.sqlite")
    }

    private static func open() -> DatabaseQueue? {
        do {
            var config = Configuration()
            config.label = "conversations"
            let q = try DatabaseQueue(path: fileURL.path, configuration: config)
            try migrator.migrate(q)
            return q
        } catch {
            // Sin base la app sigue (pinta lo que traiga la red), sólo pierde el arranque al
            // instante. Un archivo dañado se aparta y se empieza limpio la próxima vez.
            EasyBitsClient.diag("[db] no pude abrir la base: \(error)")
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            // La lista de conversaciones de cada agente, tal cual la dio gs.
            try db.create(table: "agentList") { t in
                t.primaryKey("agentId", .text)
                t.column("payload", .blob).notNull()
            }
            // Un hilo guardado y con qué copia del servidor coincide.
            try db.create(table: "thread") { t in
                t.column("agentId", .text).notNull()
                t.column("sessionId", .text).notNull()
                t.column("epoch", .text)
                t.column("lastSeq", .integer)
                t.column("oldestSeq", .integer)
                t.column("hasMoreBefore", .boolean).notNull().defaults(to: false)
                t.column("suspicious", .boolean).notNull().defaults(to: false)
                t.column("touchedAt", .double).notNull()
                t.primaryKey(["agentId", "sessionId"])
            }
            try db.create(table: "message") { t in
                t.column("agentId", .text).notNull()
                t.column("sessionId", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("id", .text).notNull()
                t.column("seq", .integer)
                t.column("payload", .blob).notNull()
                t.primaryKey(["agentId", "sessionId", "position"])
            }
            try db.create(index: "message_seq", on: "message", columns: ["agentId", "sessionId", "seq"])
            // Cursores de sincronización (`/me/sync?since=`).
            try db.create(table: "syncState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        return m
    }
}

/// Lo que se sabe de la copia de gs con la que coincide un hilo guardado.
struct ThreadMeta: Equatable, Sendable {
    var epoch: String?
    var lastSeq: Int?
    var oldestSeq: Int?
    var hasMoreBefore: Bool
}
