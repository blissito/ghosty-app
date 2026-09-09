import AuthenticationServices
import CryptoKit
import Foundation

/// El login: abre la página de ghosty.studio en la hoja del sistema y canjea el código.
///
/// La app NUNCA ve a Google ni a Apple. Todo ocurre dentro de esa hoja, contra nuestro
/// propio servidor, y lo único que vuelve aquí es un authorization code.
@MainActor
final class LoginFlow: NSObject {

    enum Fallo: LocalizedError {
        case cancelado
        case sinCodigo(String)
        case canjeFallido(String)

        var errorDescription: String? {
            switch self {
            case .cancelado: nil            // cancelar no es un error que enseñar
            case .sinCodigo(let d): d
            case .canjeFallido(let d): d
            }
        }
    }

    private var sesionWeb: ASWebAuthenticationSession?

    /// Entra. `proveedor` es el id que dio el servidor (`google`, `apple`, …); vacío =
    /// sin preferencia, y la web ofrece todas las vías.
    ///
    /// Es un String y no un enum a propósito: un proveedor nuevo tiene que poder llegar
    /// desde el servidor sin que la app se recompile.
    func entrar(con proveedor: String = "") async throws {
        let verifier = Self.nuevoVerifier()
        let challenge = Self.challenge(de: verifier)
        let state = UUID().uuidString

        var c = URLComponents(url: Session.base.appendingPathComponent("oauth2/authorize"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: Session.clientID),
            .init(name: "redirect_uri", value: Session.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "profile agents:read agents:write"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        if !proveedor.isEmpty {
            c.queryItems?.append(.init(name: "proveedor", value: proveedor))
        }

        let devuelta = try await abrirHoja(c.url!)

        guard let items = URLComponents(url: devuelta, resolvingAgainstBaseURL: false)?.queryItems
        else { throw Fallo.sinCodigo("La respuesta del servidor no se entendió.") }
        let valor = { (n: String) in items.first { $0.name == n }?.value }

        if let error = valor("error") {
            throw error == "access_denied" ? Fallo.cancelado : Fallo.sinCodigo(mensaje(de: error))
        }
        // El `state` ata esta respuesta a ESTA petición. Sin comprobarlo, una respuesta
        // inyectada desde fuera cerraría el login con un código ajeno.
        guard valor("state") == state else {
            throw Fallo.sinCodigo("La respuesta no corresponde a este intento.")
        }
        guard let code = valor("code") else {
            throw Fallo.sinCodigo("El servidor no devolvió el código de acceso.")
        }

        try await canjear(code: code, verifier: verifier)
    }

    // MARK: - La hoja del sistema

    private func abrirHoja(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let manejar: (URL?, Error?) -> Void = { devuelta, error in
                if let devuelta {
                    cont.resume(returning: devuelta)
                } else if let e = error as? ASWebAuthenticationSessionError,
                          e.code == .canceledLogin {
                    cont.resume(throwing: Fallo.cancelado)
                } else {
                    cont.resume(throwing: error ?? Fallo.cancelado)
                }
            }

            // ⚠️ `callbackURLScheme:` NO intercepta un https://: sólo reconoce schemes
            // propios. Con él, la hoja se quedaría cargando la página del callback y el
            // login no terminaría nunca. Para un Universal Link hace falta este
            // inicializador con `.https(host:path:)`, que llegó en iOS 17.4 — y por eso
            // el proyecto pide 17.4 y no 17.0.
            let s = ASWebAuthenticationSession(
                url: url,
                callback: .https(host: "www.ghosty.studio", path: "/app/cb"),
                completionHandler: manejar,
            )
            s.presentationContextProvider = self
            // ⚠️ `false` a propósito: reusa la sesión de Safari, así que quien ya esté
            // firmado en Google en este teléfono entra con UN TAP. En `true` habría que
            // teclear la contraseña de Google cada vez y los passkeys no se verían.
            s.prefersEphemeralWebBrowserSession = false
            self.sesionWeb = s
            s.start()
        }
    }

    // MARK: - Canje

    private func canjear(code: String, verifier: String) async throws {
        var req = URLRequest(url: Session.base.appendingPathComponent("oauth2/token"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Session.formulario([
            "grant_type": "authorization_code",
            "client_id": Session.clientID,
            "code": code,
            "redirect_uri": Session.redirectURI,
            "code_verifier": verifier,
        ])

        let (datos, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let access = j["access_token"] as? String,
              let refresh = j["refresh_token"] as? String
        else { throw Fallo.canjeFallido("No se pudo completar el acceso. Intenta otra vez.") }

        Session.guardar(access: access, refresh: refresh,
                        duraSegundos: (j["expires_in"] as? Int) ?? 3600)
    }

    // MARK: - PKCE

    /// El verifier es el secreto de ESTE intento: sólo vive en memoria y nunca sale del
    /// teléfono. Lo que viaja es su hash.
    private static func nuevoVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }

    private static func challenge(de verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    private func mensaje(de error: String) -> String {
        switch error {
        case "invalid_scope": "Esta versión de la app pide permisos que el servidor no reconoce."
        case "invalid_request": "La petición de acceso no era válida."
        default: "No se pudo entrar (\(error))."
        }
    }
}

extension LoginFlow: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // La ventana activa. Con escenas múltiples (iPad, que hoy no soportamos) habría
        // que elegir la del login; con una sola, la primera ES la del login.
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

extension Data {
    /// base64url sin relleno, que es lo que PKCE exige (RFC 7636 §4.2). Un base64
    /// normal lleva `+`, `/` y `=`, y los tres se rompen dentro de una URL.
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
