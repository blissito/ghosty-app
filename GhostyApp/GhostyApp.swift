import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct GhostyApp: App {
    #if os(iOS)
    /// ⚠️ Hace falta un delegado, aunque el resto de la app sea SwiftUI puro: el token de
    /// push llega por `didRegisterForRemoteNotifications…` y no hay equivalente en el
    /// mundo de `App`. Es lo único que vive aquí.
    @UIApplicationDelegateAdaptor(Delegado.self) private var delegado
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                #if os(macOS)
                // Ventana del tamaño de un teléfono para poder juzgar el diseño
                // sin simulador — útil mientras no hay Xcode, y para iterar rápido.
                .frame(width: 390, height: 844)
                #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}

#if os(iOS)
final class Delegado: NSObject, UIApplicationDelegate {
    func application(_ app: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { @MainActor in Avisos.registrar(token: token) }
    }

    func application(_ app: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No se calla: sin token no hay aviso con la app cerrada, y quedarse sin saberlo
        // es exactamente el fallo mudo que este repo persigue.
        EasyBitsClient.diag("[push] ⚠️ no me pude registrar: \(error.localizedDescription)")
    }
}
#endif
