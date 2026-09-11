import Foundation

/// Los tipos con los que la app habla de un agente, sin decir por dónde.
///
/// ⚠️ Vivían dentro de `ACPClient`, que era el cliente del WebSocket a la caja. Al quitar
/// ese transporte había que elegir entre arrastrar un actor de setecientas líneas por unos
/// structs, o mudarlos. Se mudaron. El nombre `ACPClient` se conserva como espacio de
/// nombres porque aparece en veinte sitios y renombrarlo no arregla nada.
enum ACPClient {
    struct Session: Identifiable, Sendable, Equatable {
        let id: String            // sessionId
        var title: String
        var cwd: String
        var updatedAt: Date?
        var messageCount: Int?
    }

    /// Modo de la sesión. `session/new` los devuelve: `auto` aprueba las herramientas
    /// solo; `approve` hace que el agente PIDA permiso, que es lo que enciende la
    /// tarjeta de permisos.
    struct Modos: Sendable, Equatable {
        var actual: String
        var disponibles: [(id: String, nombre: String, descripcion: String)]

        static func == (a: Modos, b: Modos) -> Bool {
            a.actual == b.actual && a.disponibles.map(\.id) == b.disponibles.map(\.id)
        }
    }

    /// Una petición de permiso del agente AL cliente. Hay que contestarla o el turno
    /// se queda esperando.
    struct Permiso: Sendable, Identifiable {
        /// ⚠️ TEXTO, no el entero JSON-RPC que era antes. Por el socket el id es el de la
        /// petición y sirve para responderla; contra gs es un id del servidor. Que el
        /// modelo hable en texto es lo que permite tener los dos transportes sin que la
        /// pantalla de permisos sepa por dónde llegó. `ACPClient` guarda su propio mapa
        /// para volver al entero cuando toca contestar.
        let id: String
        let sessionID: String
        let titulo: String
        let herramienta: String
        /// Las opciones que ofrece el agente, con su `optionId` real.
        var opciones: [(id: String, nombre: String, tipo: String)]
    }

    /// Lo que trae el replay de `session/load`. Los `*_chunk` llegan **partidos**, así
    /// que hay que pegarlos por turno antes de mostrarlos.
    enum Replay: Sendable {
        /// De QUÉ turno es lo que sigue. Lo pone gs en cada `chunk`/`done`; es lo que
        /// deja colgar el texto de la MISMA burbuja aunque se llegue por enganche.
        case turno(String)
        case user(String)
        case agent(String)
        case thought(String)
        /// Una herramienta que empieza o que cambia. Llega varias veces por la misma:
        /// ACP manda `tool_call` al crearla y `tool_call_update` cada vez que avanza.
        case tool(Herramienta)
        /// El agente entregó algo: un archivo suyo o un artefacto que escribió.
        case entrega(Entrega)
        /// Lo que costó el turno. Llega UNA vez, al cerrar.
        ///
        /// ⚠️ Sale de la RESPUESTA de `session/prompt`, no de una notificación: el agente
        /// manda `usage_update` mientras trabaja, pero el número bueno —el acumulado del
        /// turno— viene con el `stopReason`. Antes esa respuesta se descartaba con un
        /// `_ =`, así que el panel de actividad decía **0 tokens** para siempre por más
        /// turnos que se hicieran.
        case usage(input: Int, output: Int)
    }

    enum Fallo: LocalizedError {
        case noConectado
        case timeout(String)
        case remoto(String)
        case handshake(String)

        var errorDescription: String? {
            switch self {
            case .noConectado:      return "No hay conexión con tu agente."
            case .timeout(let m):   return "Tu agente no contestó a \(m)."
            case .remoto(let m):    return m
            case .handshake(let m): return "No pude abrir la sesión: \(m)"
            }
        }
    }


    /// Traduce un `tool_call` / `tool_call_update` a una herramienta.
    ///
    /// ⚠️ `content` de una herramienta es un **ARRAY**, no un objeto. Ahí estaba el fallo:
    /// el resto del cliente lo lee como `content.text` —que es la forma de los chunks de
    /// mensaje— y por eso el resultado no aparecía nunca. No es que no llegara: es que se
    /// leía mal.
    nonisolated static func herramienta(_ u: [String: Any], id: String) -> Herramienta {
        let estado: Herramienta.Estado
        switch u["status"] as? String {
        case "completed": estado = .hecha
        case "failed":    estado = .fallida
        default:          estado = .corriendo   // `pending` e `in_progress`
        }

        // El primer archivo que toca, para poder decir SOBRE QUÉ trabaja.
        let donde = (u["locations"] as? [[String: Any]])?
            .compactMap { $0["path"] as? String }.first
            .map { ($0 as NSString).lastPathComponent }

        return Herramienta(
            id: id,
            titulo: (u["title"] as? String) ?? "herramienta",
            clase: .init(u["kind"] as? String),
            estado: estado,
            salida: Self.salidaDe(u["content"]),
            donde: donde)
    }

    /// Un hash que vale lo mismo en todos los arranques.
    ///
    /// ⚠️ **`hashValue` de Swift NO sirve para esto**: lleva una semilla aleatoria por
    /// proceso, así que la misma entrega tenía un id distinto en cada lanzamiento. Con eso
    /// la deduplicación no dedupe nada y la tarjeta se repite en el hilo al reabrir la app.
    /// FNV-1a, que es determinista y basta para distinguir entregas.
    private nonisolated static func huellaEstable(_ texto: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in texto.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 36)
    }

    /// El texto legible de lo que devolvió una herramienta, si lo hay.
    private nonisolated static func salidaDe(_ crudo: Any?) -> String? {
        guard let partes = crudo as? [[String: Any]] else { return nil }
        var trozos: [String] = []
        for p in partes {
            // `content` envuelve un bloque; `diff` y `terminal` traen lo suyo.
            if let c = p["content"] as? [String: Any], let t = c["text"] as? String { trozos.append(t) }
            else if let t = p["text"] as? String { trozos.append(t) }
            else if let d = p["newText"] as? String { trozos.append(d) }
        }
        let junto = trozos.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return junto.isEmpty ? nil : junto
    }

    /// Traduce el payload de `ghosty/artifact` a una entrega.
    ///
    /// El relé manda dos formas (ver `mcp.ts` de la plantilla):
    ///   • `{tipo:"archivo", nombre, contenidoBase64}`
    ///   • `{tipo:"artefacto", subtipo:"doc"|"sheet"|"artifact", titulo, contenido}`
    ///
    /// ⚠️ Un `subtipo` que no reconozcamos NO se descarta: entra como página. Tirar una
    /// entrega porque el nombre de su forma es nuevo la haría desaparecer sin dejar
    /// rastro, y el agente ya le dijo al usuario que se la entregó.
    nonisolated static func entregaDesde(_ p: [String: Any], agentID: String) -> Entrega? {
        // ⚠️ El id es DETERMINISTA, no un `UUID()` nuevo. La entrega del relé no trae
        // `sessionId`, así que con varios turnos vivos se reparte a todos los flujos, y
        // cada uno la registraba: la misma entrega tres veces en Artefactos, y en disco.
        // Con un id derivado de su contenido, registrarla dos veces es la misma fila.
        let huella = [p["tipo"] as? String, p["subtipo"] as? String, p["nombre"] as? String,
                      p["titulo"] as? String,
                      (p["contenido"] as? String).map { String($0.prefix(200)) },
                      (p["contenidoBase64"] as? String).map { String($0.prefix(200)) }]
            .compactMap { $0 }.joined(separator: "|")
        let id = "e" + Self.huellaEstable(huella)
        switch p["tipo"] as? String {
        case "archivo":
            let nombre = (p["nombre"] as? String) ?? "Archivo"
            let datos = (p["contenidoBase64"] as? String).flatMap { Data(base64Encoded: $0) }
            return Entrega(id: id, agentID: agentID, forma: .archivo, titulo: nombre,
                           recibida: Date(), contenido: nil, datos: datos)
        case "artefacto":
            let forma: Entrega.Forma
            switch p["subtipo"] as? String {
            case "doc":   forma = .doc
            case "sheet": forma = .sheet
            default:      forma = .artifact
            }
            return Entrega(id: id, agentID: agentID, forma: forma,
                           titulo: (p["titulo"] as? String) ?? "Sin título",
                           recibida: Date(),
                           contenido: (p["contenido"] as? String) ?? "", datos: nil)
        default:
            return nil
        }
    }


}
