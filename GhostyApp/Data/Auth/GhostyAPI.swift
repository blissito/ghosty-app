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
        var errorDescription: String? {
            switch self {
            case .servidor(let c): "El servidor contestó \(c)."
            }
        }
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
