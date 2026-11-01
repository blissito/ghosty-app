import Foundation

/// Lo que la app comparte con su extensión «Enviar a Ghosty» (hoja de compartir).
///
/// Son dos procesos con sandbox distinto: lo único que ven los dos es el contenedor del
/// App Group (archivos y `UserDefaults`) y el grupo del llavero (la sesión, ver
/// `Keychain`). Todo lo que la extensión necesita de la app pasa por aquí.
enum GrupoDeApp {
    static let id = "group.com.fixtergeek.ghostyapp"

    /// `nil` si el entitlement no está (build sin firmar): la extensión lo dice en vez de
    /// fallar a medias.
    static var contenedor: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }

    // MARK: - Consentimiento de IA

    /// ⚠️ El consentimiento vive en los `UserDefaults` de la app (`@AppStorage`, y los UI
    /// tests lo fijan por argumento en ese dominio), así que la app lo COPIA al grupo. La
    /// extensión sólo lo lee: si no lo ve, manda a abrir la app.
    static func espejarConsentimiento() {
        defaults?.set(UserDefaults.standard.bool(forKey: AIConsentSheet.key), forKey: AIConsentSheet.key)
    }

    static var hayConsentimiento: Bool { defaults?.bool(forKey: AIConsentSheet.key) == true }
}

/// Las rutas `com.fixtergeek.ghostyapp://…` que abren la app en un sitio concreto.
///
/// - `…://conversacion?agente=<id>&sesion=<id>`: esa conversación.
/// - `…://compartido?id=<paquete>`: un compositor nuevo con lo que se compartió.
/// - `…://pedido?espacio=<slug>&id=<n>`: un pedido de la Fábrica (Live Activity y avisos de Teams).
/// - `…://factory-thread?space=<slug>&room=<room>&thread=<n>`: un hilo de la Fábrica que todavía
///   no es pedido (la conversación con @plan).
///
/// Los nombres de host y de parámetros son formato de cable: la Live Activity y gs
/// (`app/lib/push/factory-link.ts`) los escriben, así que no se renombran.
///
/// ⚠️ `…://cb` (login) y `…://conector` los consume `ASWebAuthenticationSession`; no
/// pasan por aquí y aquí se ignoran.
enum GhostyLink: Equatable {
    case conversation(agent: String, session: String)
    case shared(id: String)
    case factoryRun(space: String, id: Int)
    case factoryThread(space: String, room: String, thread: Int)

    init?(url: URL) {
        guard url.scheme == Session.redirectScheme,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let q = { (n: String) in c.queryItems?.first { $0.name == n }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        switch url.host {
        case "conversacion":
            guard let a = q("agente"), let s = q("sesion") else { return nil }
            self = .conversation(agent: a, session: s)
        case "compartido":
            guard let id = q("id") else { return nil }
            self = .shared(id: id)
        case "pedido":
            guard let space = q("espacio"), let id = q("id").flatMap(Int.init) else { return nil }
            self = .factoryRun(space: space, id: id)
        case "factory-thread":
            guard let space = q("space"), let room = q("room"), let thread = q("thread").flatMap(Int.init) else { return nil }
            self = .factoryThread(space: space, room: room, thread: thread)
        default:
            return nil
        }
    }

    /// El `link` de un push (gs lo manda como texto en el payload).
    init?(string: String?) {
        guard let string, let url = URL(string: string) else { return nil }
        self.init(url: url)
    }

    var url: URL {
        var c = URLComponents()
        c.scheme = Session.redirectScheme
        switch self {
        case .conversation(let a, let s):
            c.host = "conversacion"
            c.queryItems = [URLQueryItem(name: "agente", value: a), URLQueryItem(name: "sesion", value: s)]
        case .shared(let id):
            c.host = "compartido"
            c.queryItems = [URLQueryItem(name: "id", value: id)]
        case .factoryRun(let space, let id):
            c.host = "pedido"
            c.queryItems = [URLQueryItem(name: "espacio", value: space), URLQueryItem(name: "id", value: String(id))]
        case .factoryThread(let space, let room, let thread):
            c.host = "factory-thread"
            c.queryItems = [URLQueryItem(name: "space", value: space), URLQueryItem(name: "room", value: room),
                            URLQueryItem(name: "thread", value: String(thread))]
        }
        return c.url!
    }

    /// A qué espacio de la Fábrica lleva, si lleva a uno.
    var factorySpace: String? {
        switch self {
        case .factoryRun(let space, _), .factoryThread(let space, _, _): space
        default: nil
        }
    }
}

/// Lo que la extensión deja en el contenedor del grupo para que la app lo abra en el
/// compositor («Abrir en Ghosty» sin mandar).
///
/// Un paquete es una carpeta `compartido/<id>/` con `paquete.json` y los archivos. La app
/// lo lee UNA vez y lo borra; los que nadie abrió se tiran a las 24 h.
enum BuzonCompartido {
    struct Paquete: Codable, Equatable {
        struct Archivo: Codable, Equatable {
            var nombre: String
            var mime: String
            /// Nombre del archivo dentro de la carpeta del paquete.
            var archivo: String
        }
        var id: String
        var agente: String?
        var texto: String
        var archivos: [Archivo]
    }

    /// Lo que la app necesita para llenar el compositor.
    struct Recibido: Equatable {
        var id: String
        var agente: String?
        var texto: String
        var adjuntos: [Adjunto]
    }

    private static var raiz: URL? { GrupoDeApp.contenedor?.appendingPathComponent("compartido", isDirectory: true) }

    /// Guarda lo compartido y devuelve el id del paquete.
    static func guardar(agente: String?, texto: String, adjuntos: [Adjunto]) throws -> String {
        guard let raiz else { throw GhostyAPI.Fallo.mensaje("Falta el grupo de la app.") }
        purgar()
        let id = UUID().uuidString.lowercased()
        let dir = raiz.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var archivos: [Paquete.Archivo] = []
        for (i, a) in adjuntos.enumerated() {
            let nombre = "\(i)-\(BloqueDeAdjuntos.saneado(a.nombre))"
            try a.datos.write(to: dir.appendingPathComponent(nombre), options: .atomic)
            archivos.append(.init(nombre: a.nombre, mime: a.mime, archivo: nombre))
        }
        let p = Paquete(id: id, agente: agente, texto: texto, archivos: archivos)
        try JSONEncoder().encode(p).write(to: dir.appendingPathComponent("paquete.json"), options: .atomic)
        return id
    }

    /// Lee el paquete y lo BORRA: abrir dos veces el mismo enlace no duplica adjuntos.
    static func tomar(_ id: String) -> Recibido? {
        guard let raiz, !id.contains("/"), !id.contains("..") else { return nil }
        let dir = raiz.appendingPathComponent(id, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("paquete.json")),
              let p = try? JSONDecoder().decode(Paquete.self, from: d) else { return nil }
        let adjuntos = p.archivos.compactMap { a -> Adjunto? in
            guard let datos = try? Data(contentsOf: dir.appendingPathComponent(a.archivo)) else { return nil }
            return Adjunto(nombre: a.nombre, mime: a.mime, datos: datos)
        }
        return Recibido(id: p.id, agente: p.agente, texto: p.texto, adjuntos: adjuntos)
    }

    /// Tira los paquetes de más de un día que nadie abrió.
    static func purgar() {
        guard let raiz,
              let hijos = try? FileManager.default.contentsOfDirectory(
                at: raiz, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let limite = Date().addingTimeInterval(-86_400)
        for h in hijos {
            let f = (try? h.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if f < limite { try? FileManager.default.removeItem(at: h) }
        }
    }
}
