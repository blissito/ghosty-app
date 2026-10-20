import AuthenticationServices
import UIKit

/// Abre una página en la hoja del navegador del sistema (`ASWebAuthenticationSession`) y espera a
/// que vuelva por `…://` o a que la persona la cierre. Para los flujos que no son el login: darle
/// acceso a la GitHub App desde la Fábrica. Devuelve la URL de vuelta, o nil si cerró la hoja.
@MainActor
final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var current: WebAuth?
    private var session: ASWebAuthenticationSession?

    static func open(_ url: URL) async -> URL? {
        let w = WebAuth()
        current = w
        defer { current = nil }
        return await withCheckedContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: Session.redirectScheme) { back, _ in
                cont.resume(returning: back)
            }
            s.presentationContextProvider = w
            w.session = s
            s.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if GHOSTY_EXTENSION
            ASPresentationAnchor()
            #else
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
            #endif
        }
    }
}
