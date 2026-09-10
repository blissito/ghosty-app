import Foundation

/// La sesión con ghosty.studio: un access token corto y un refresh largo, los dos en el
/// llavero de ESTE teléfono.
///
/// ⚠️ Ni `ACPClient` ni `EasyBitsClient` saben lo que es un token que caduca: los dos
/// ponen `Authorization: Bearer <string>` y ninguno reintenta ante un 401. Por eso el
/// refresco se pide ANTES de usar el token, nunca como reintento: un WebSocket que se
/// cae a media conversación por token vencido no se arregla repitiendo la petición.
enum Session {

    /// Lo que la app es ante el servidor. Público a propósito: no lleva secreto — eso es
    /// justo lo que significa "cliente público" en OAuth2, y lo que protege el canje es
    /// PKCE.
    static let clientID = "ghosty-app-ios"
    static let base = URL(string: "https://www.ghosty.studio")!
    /// ⚠️ Scheme propio, y NO el Universal Link, aunque el https:// suene más seguro.
    ///
    /// El `.https(host:path:)` de ASWebAuthenticationSession se probó en un teléfono real
    /// y NO cerró la hoja: cargaba la página del callback y ahí se quedaba, con Cancelar
    /// como única salida. Todo lo demás estaba correcto y comprobado —entitlements en el
    /// binario, AASA en el CDN de Apple, perfil de distribución—, así que no es
    /// configuración: es que ese camino no resulta fiable.
    ///
    /// El scheme propio es lo que la RFC 8252 §7.1 recomienda para apps nativas, y lo
    /// que hacen los SDK de Google. El riesgo conocido —que otra app registre el mismo
    /// scheme y se quede con el código— lo cubre **PKCE**: sin el `code_verifier`, que
    /// nunca sale de este proceso, un código robado no se puede canjear.
    static let redirectScheme = "com.fixtergeek.ghostyapp"
    static let redirectURI = "com.fixtergeek.ghostyapp://cb"

    // MARK: - Estado

    private struct Guardada: Codable {
        var access: String
        var refresh: String
        /// Cuándo deja de servir el access, en segundos desde 1970.
        var expira: Double
    }

    private static var cache: Guardada?

    private static func leer() -> Guardada? {
        if let c = cache { return c }
        guard let json = Keychain.leer(.sesion), let d = json.data(using: .utf8),
              let g = try? JSONDecoder().decode(Guardada.self, from: d) else { return nil }
        cache = g
        return g
    }

    private static func escribir(_ g: Guardada?) {
        cache = g
        guard let g, let d = try? JSONEncoder().encode(g),
              let json = String(data: d, encoding: .utf8) else {
            Keychain.borrar(.sesion); return
        }
        Keychain.escribir(.sesion, json)
    }

    static var haySesion: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["GHOSTY_TOKEN"]?.isEmpty == false { return true }
        #endif
        return leer() != nil
    }

    static func guardar(access: String, refresh: String, duraSegundos: Int) {
        escribir(Guardada(access: access, refresh: refresh,
                          expira: Date().timeIntervalSince1970 + Double(duraSegundos)))
    }

    // MARK: - Uso

    enum Fallo: LocalizedError {
        case sinSesion
        case caducada

        var errorDescription: String? {
            switch self {
            case .sinSesion: "No has iniciado sesión."
            case .caducada:  "Tu sesión expiró. Vuelve a entrar."
            }
        }
    }

    /// Un access token que sirve AHORA. Refresca si le queda poco.
    ///
    /// El margen de 60 s no es paranoia: sin él, un token que vence en dos segundos pasa
    /// la comprobación y caduca a mitad del viaje, y el fallo aparece como un error de
    /// red cualquiera.
    static func accessToken() async throws -> String {
        // ⚠️ Gancho de DESARROLLO, sólo en Debug. El simulador no puede pasar por el login
        // —hay que teclear credenciales de una persona— y sin sesión no se puede verificar
        // NADA de lo que habla con el servidor. Con `GHOSTY_TOKEN` se le presta uno de
        // corta vida y la app se comporta igual que con sesión de verdad.
        //
        // No se guarda en el llavero a propósito: vive en el proceso y se va con él.
        #if DEBUG
        if let prestado = ProcessInfo.processInfo.environment["GHOSTY_TOKEN"], !prestado.isEmpty {
            return prestado
        }
        #endif
        guard let g = leer() else { throw Fallo.sinSesion }
        if Date().timeIntervalSince1970 < g.expira - 60 { return g.access }
        return try await refrescar(g.refresh)
    }

    private static func refrescar(_ refresh: String) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("oauth2/token"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formulario([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refresh,
        ])

        let (datos, resp) = try await URLSession.shared.data(for: req)
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0

        // ⚠️ 400 `invalid_grant` significa que este refresh ya no sirve — vencido,
        // revocado, o reusado (y ahí el servidor mató la familia entera a propósito).
        // Es DEFINITIVO: se borra la sesión y se pide entrar otra vez. Reintentar sería
        // un bucle, y guardarla sería una sesión zombi que nunca se recupera.
        if codigo == 400 || codigo == 401 {
            cerrar()
            throw Fallo.caducada
        }
        guard codigo == 200,
              let j = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let access = j["access_token"] as? String,
              let nuevoRefresh = j["refresh_token"] as? String
        else {
            // Un 500 o un corte de red NO invalidan la sesión: se sube el error y se
            // vuelve a intentar más tarde con el mismo refresh.
            throw URLError(.badServerResponse)
        }

        let dura = (j["expires_in"] as? Int) ?? 3600
        guardar(access: access, refresh: nuevoRefresh, duraSegundos: dura)
        return access
    }

    /// Cerrar sesión: se le avisa al servidor y se borra el llavero.
    ///
    /// El aviso importa —revocar deja el token muerto en el servidor, no sólo borrado de
    /// este teléfono— pero es best-effort: sin red, cerrar sesión tiene que funcionar
    /// igual. Lo que no puede pasar es quedarse dentro por no haber podido avisar.
    static func cerrarSesion() async {
        let refresh = leer()?.refresh
        cerrar()
        guard let refresh else { return }
        var req = URLRequest(url: base.appendingPathComponent("oauth2/revoke"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formulario(["client_id": clientID, "token": refresh])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Borra sólo lo local.
    static func cerrar() {
        escribir(nil)
        Credentials.olvidarTodo()
    }

    static func formulario(_ campos: [String: String]) -> Data {
        var c = URLComponents()
        c.queryItems = campos.map { URLQueryItem(name: $0.key, value: $0.value) }
        // `+` en un query es un espacio; en un cuerpo de formulario tiene que ir
        // escapado o un token con `+` llega partido. Los tokens van en base64url, que
        // no lo usa, pero eso es suerte y no una garantía.
        return (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8) ?? Data()
    }
}
