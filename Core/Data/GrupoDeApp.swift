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
///
/// ⚠️ `…://cb` (login) y `…://conector` los consume `ASWebAuthenticationSession`; no
/// pasan por aquí y aquí se ignoran.
enum EnlaceDeGhosty: Equatable {
    case conversacion(agente: String, sesion: String)
    case compartido(id: String)

    init?(url: URL) {
        guard url.scheme == Session.redirectScheme,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let q = { (n: String) in c.queryItems?.first { $0.name == n }?.value }
        switch url.host {
        case "conversacion":
            guard let a = q("agente"), let s = q("sesion"), !a.isEmpty, !s.isEmpty else { return nil }
            self = .conversacion(agente: a, sesion: s)
        case "compartido":
            guard let id = q("id"), !id.isEmpty else { return nil }
            self = .compartido(id: id)
        default:
            return nil
        }
    }

    var url: URL {
        var c = URLComponents()
        c.scheme = Session.redirectScheme
        switch self {
        case .conversacion(let a, let s):
            c.host = "conversacion"
            c.queryItems = [URLQueryItem(name: "agente", value: a), URLQueryItem(name: "sesion", value: s)]
        case .compartido(let id):
            c.host = "compartido"
            c.queryItems = [URLQueryItem(name: "id", value: id)]
        }
        return c.url!
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
