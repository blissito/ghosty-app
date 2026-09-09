import Foundation

/// El cliente de ghosty.studio con la sesión de la persona.
///
/// Es lo que sustituye a teclear un token y un id de agente: el servidor sabe qué
/// agentes tiene esta cuenta y devuelve con qué conectarse a cada uno.
enum GhostyAPI {

    struct Flota {
        var correo: String?
        var agentes: [AgentAccount]
        /// Hay un agente ACP sin token de conexión: existe pero no se le puede hablar.
        var faltanTokens: Bool
        /// Por qué no se enroló uno, cuando la cuenta venía vacía.
        var motivoSinAgente: String?
    }

    enum Fallo: LocalizedError {
        case servidor(Int)
        /// Lo que dijo el servidor, para enseñarlo tal cual.
        case mensaje(String)
        var errorDescription: String? {
            switch self {
            case .servidor(let c): "El servidor contestó \(c)."
            case .mensaje(let m):  m
            }
        }
    }

    /// Un archivo de la cuenta, ya en el almacenamiento de gs.
    struct ArchivoRemoto {
        var id: String
        var nombre: String
        var mime: String
        var bytes: Int
        /// ⚠️ FIRMADA y caduca a las 6 h. No se guarda como si fuera permanente: para un
        /// archivo viejo hay que volver a pedirla con `urlDe(id:)`.
        var url: String
    }

    /// Cuánto lleva usado la cuenta. El tope viene del SERVIDOR a propósito: un número
    /// dentro de un binario tarda días en poder corregirse.
    struct Almacenamiento {
        var usados: Int
        var tope: Int
        var tier: String

        var fraccion: Double { tope > 0 ? min(1, Double(usados) / Double(tope)) : 0 }
        var texto: String {
            let f = ByteCountFormatter()
            f.countStyle = .file
            return "\(f.string(fromByteCount: Int64(usados))) de \(f.string(fromByteCount: Int64(tope)))"
        }
    }

    /// Sube un archivo al almacenamiento de la CUENTA.
    ///
    /// ⚠️ Ya no va a la caja del agente. Un adjunto vivía sólo en `/data/work/adjuntos/`, y
    /// el janitor recicla esa caja a las 72 h dormida y la repone vacía: el archivo
    /// desaparecía sin que nada lo dijera. Aquí cuelga de la cuenta y sobrevive.
    static func subir(_ adjunto: Adjunto, sesion: String?) async throws -> ArchivoRemoto {
        var c = URLComponents(url: Session.base.appendingPathComponent("api/v2/me/files"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "nombre", value: adjunto.nombre)]
            + (sesion.map { [URLQueryItem(name: "sesion", value: $0)] } ?? [])

        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.assumesHTTP3Capable = false
        req.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue(adjunto.mime, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180

        let (datos, resp) = try await URLSession.shared.upload(for: req, from: adjunto.datos)
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = try? JSONSerialization.jsonObject(with: datos) as? [String: Any]
        guard codigo == 200, let j, let id = j["id"] as? String, let url = j["url"] as? String else {
            // El mensaje del servidor se enseña TAL CUAL: sabe si fue el tamaño, el tope de
            // la conversación o el almacenamiento lleno, y la app no.
            throw Fallo.mensaje((j?["error"] as? String) ?? "No pude subir «\(adjunto.nombre)».")
        }
        return ArchivoRemoto(id: id,
                             nombre: (j["name"] as? String) ?? adjunto.nombre,
                             mime: (j["mime"] as? String) ?? adjunto.mime,
                             bytes: (j["size"] as? Int) ?? adjunto.datos.count,
                             url: url)
    }

    /// Las apps que el agente puede usar en tu nombre.
    ///
    /// ⚠️ Devuelve `nil` —no una lista vacía— cuando el servidor todavía no tiene el
    /// endpoint. La diferencia es la pantalla entera: vacía significa "no has conectado
    /// nada", y `nil` significa "esto no existe todavía", que es cuando NO hay que enseñar
    /// la entrada. Una pantalla que se abre para explicar por qué está vacía es justo lo
    /// que quitamos de esta app hace unas horas.
    static func conectores() async -> [Conector]? {
        var req = URLRequest(url: Session.base.appendingPathComponent("api/v2/me/connectors"))
        req.assumesHTTP3Capable = false
        guard let token = try? await Session.accessToken() else { return nil }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (datos, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let lista = j["connectors"] as? [[String: Any]]
        else { return nil }

        let iso = ISO8601DateFormatter()
        return lista.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            return Conector(id: id,
                            nombre: (c["nombre"] as? String) ?? (c["name"] as? String) ?? id,
                            conectado: (c["conectado"] as? Bool) ?? (c["connected"] as? Bool) ?? false,
                            desde: (c["desde"] as? String).flatMap { iso.date(from: $0) })
        }
    }

    /// Dónde mandar el navegador para conectar uno.
    static func urlDeConexion(_ id: String) async -> URL? {
        var req = URLRequest(url: Session.base.appendingPathComponent("api/v2/me/connectors/\(id)/start"))
        req.httpMethod = "POST"
        req.assumesHTTP3Capable = false
        guard let token = try? await Session.accessToken() else { return nil }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (datos, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let s = j["url"] as? String
        else { return nil }
        return URL(string: s)
    }

    @discardableResult
    static func desconectar(_ id: String) async -> Bool {
        var req = URLRequest(url: Session.base.appendingPathComponent("api/v2/me/connectors/\(id)"))
        req.httpMethod = "DELETE"
        req.assumesHTTP3Capable = false
        guard let token = try? await Session.accessToken() else { return false }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Transcribe un audio con el whisper de la flota.
    ///
    /// ⚠️ Bytes CRUDOS, no base64. El endpoint de partner que ya existía usa base64 porque
    /// su firma HMAC se calcula sobre el cuerpo como texto y un binario no sobrevive ese
    /// viaje; con bearer esa restricción no aplica.
    ///
    /// ⚠️ Timeout generoso a propósito: la caja de whisper vive HIBERNADA y la despierta el
    /// proxy, así que la primera transcripción tras un rato tarda unos segundos. Darla por
    /// fallida ahí sería tirar la nota justo en el caso más común —la primera del día—.
    ///
    /// Devuelve `nil` si no se pudo: es best-effort, el audio viaja igual y el turno lo dice.
    static func transcribir(_ audio: Data, mime: String, lang: String = "es") async -> String? {
        var c = URLComponents(url: Session.base.appendingPathComponent("api/v2/me/stt"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "lang", value: lang)]
        guard let url = c.url, let token = try? await Session.accessToken() else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.assumesHTTP3Capable = false
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 150

        guard let (datos, resp) = try? await URLSession.shared.upload(for: req, from: audio),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let texto = j["text"] as? String
        else {
            print("[voz] no se pudo transcribir")
            return nil
        }
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        return limpio.isEmpty ? nil : limpio
    }

    /// Una firma nueva para un archivo que ya está subido.
    static func urlDe(_ id: String) async throws -> String {
        var req = URLRequest(url: Session.base.appendingPathComponent("api/v2/me/files/\(id)"))
        req.assumesHTTP3Capable = false
        req.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        let (datos, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let url = j["url"] as? String
        else { throw Fallo.mensaje("Ese archivo ya no está.") }
        return url
    }

    /// Cuánto almacenamiento lleva usado la cuenta.
    static func almacenamiento() async throws -> Almacenamiento? {
        var req = URLRequest(url: Session.base.appendingPathComponent("api/v2/me/files"))
        req.assumesHTTP3Capable = false
        req.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        let (datos, _) = try await URLSession.shared.data(for: req)
        guard let j = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let s = j["storage"] as? [String: Any] else { return nil }
        return Almacenamiento(usados: (s["usedBytes"] as? Int) ?? 0,
                              tope: (s["limitBytes"] as? Int) ?? 0,
                              tier: (s["tier"] as? String) ?? "")
    }

    /// Los agentes de la cuenta. Si está vacía, el servidor le provisiona el primero.
    static func flota() async throws -> Flota {
        var req = URLRequest(url: Session.base.appendingPathComponent("api/v2/me/agents"))
        req.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        // Igual que en EasyBitsClient: HTTP/3 mata las respuestas largas en silencio.
        req.assumesHTTP3Capable = false

        let (datos, resp) = try await URLSession.shared.data(for: req)
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // Un 401 aquí significa que el token murió entre el refresco y esta petición
        // (revocado desde otro sitio, por ejemplo). Se cierra la sesión para que la app
        // vuelva al login en vez de quedarse en un error que no se arregla solo.
        if codigo == 401 { Session.cerrar(); throw Session.Fallo.caducada }
        guard codigo == 200 else { throw Fallo.servidor(codigo) }

        guard let j = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let lista = j["agentes"] as? [[String: Any]]
        else { throw URLError(.cannotParseResponse) }

        var cuentas: [AgentAccount] = []
        var faltan = false

        for a in lista {
            guard let id = a["id"] as? String else { continue }
            let nombre = (a["nombre"] as? String) ?? "Ghosty"
            guard let cx = a["conexion"] as? [String: Any], let tipo = cx["tipo"] as? String,
                  let token = cx["token"] as? String
            else {
                // Sin material de conexión no se puede conversar con él. Se cuenta para
                // poder decirlo, y no se mete a la lista: un agente en pantalla que no
                // contesta es peor que uno que no aparece.
                if a["necesitaToken"] != nil { faltan = true }
                continue
            }
            cuentas.append(AgentAccount(
                id: id,
                token: token,
                name: nombre,
                // El host lo manda el servidor: cablearlo aquí ataría la app a UN
                // dominio de cajas, y ya hay dos fierros.
                host: tipo == "acp" ? cx["host"] as? String : nil
            ))
        }

        let enrol = j["enrolamiento"] as? [String: Any]
        let creado = (enrol?["creado"] as? Bool) ?? false
        var motivo: String?
        if !creado, cuentas.isEmpty {
            switch enrol?["motivo"] as? String {
            case "sin-cupo": motivo = "Ahora mismo no podemos crear tu agente. Inténtalo en un rato."
            case "error":    motivo = "No pudimos crear tu agente. Inténtalo de nuevo."
            default:         motivo = nil   // "ya-tenia" con lista vacía: ver `faltan`
            }
        }

        let usuario = j["usuario"] as? [String: Any]
        return Flota(correo: usuario?["email"] as? String,
                     agentes: cuentas, faltanTokens: faltan, motivoSinAgente: motivo)
    }
}
