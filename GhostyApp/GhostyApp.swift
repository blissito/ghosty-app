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
                     didFinishLaunchingWithOptions opciones: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in Avisos.registrarSiYaHayPermiso() }
        // El POST de un turno termina aunque apagues el teléfono justo al mandar (ver ClienteGS).
        BackgroundTime.onBegin = { name in
            var id: UIBackgroundTaskIdentifier = .invalid
            id = UIApplication.shared.beginBackgroundTask(withName: name) {
                // Se acabó el préstamo: se devuelve, o iOS mata la app.
                UIApplication.shared.endBackgroundTask(id)
            }
            return id.rawValue
        }
        BackgroundTime.onEnd = { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: $0)) }
        // La ✕ para borrar de un toque el texto de los campos de las alertas (renombrar
        // conversación): el `TextField` de un `.alert` no deja configurarla desde SwiftUI.
        UITextField.appearance(whenContainedInInstancesOf: [UIAlertController.self]).clearButtonMode = .whileEditing
        #if DEBUG
        VoiceBench.runIfRequested()
        #endif
        return true
    }

    func application(_ app: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { @MainActor in Avisos.registrar(token: token) }
    }

    /// Nos despertaron en el fondo: recoger lo que el agente terminó.
    ///
    /// ⚠️ El `completionHandler` se llama SIEMPRE y **una sola vez**. Si no, iOS mata la
    /// app y —peor, porque no se ve— le recorta el presupuesto de despertares futuros: los
    /// siguientes avisos dejan de llegar y no hay ningún error que lo diga.
    ///
    /// ⚠️ Y con presupuesto propio de 20 s, por debajo de los ~30 que da el sistema: la
    /// recogida habla con la caja y puede tardar lo que quiera.
    func application(_ app: UIApplication,
                     didReceiveRemoteNotification info: [AnyHashable: Any],
                     fetchCompletionHandler listo: @escaping (UIBackgroundFetchResult) -> Void) {
        // ⚠️ Se registra la LLEGADA, no sólo el resultado. El simulador no entrega push
        // silenciosos —el visible sí— así que la única forma de saber si el servidor los
        // está mandando bien es mirar este renglón en el teléfono, por cable.
        EasyBitsClient.diag("[push] silencioso: \(info.keys.map(String.init(describing:)).sorted().joined(separator: ","))")
        let agente = (info["agentId"] ?? info["agentID"]) as? String
        let sesion = (info["sessionId"] ?? info["sesion"]) as? String
        guard let agente, let sesion else { listo(.noData); return }

        let contestado = Contestador(listo)
        Task { @MainActor in
            // El reloj corre aparte: si la caja no contesta, se responde igual.
            let reloj = Task {
                try? await Task.sleep(for: .seconds(20))
                contestado.una(.failed)
            }
            let hubo = await LiveAgentStore.compartido.recogerYa(agente: agente, sesion: sesion)
            reloj.cancel()
            EasyBitsClient.diag("[push] despertado por \(sesion): \(hubo ? "algo nuevo" : "nada")")
            contestado.una(hubo ? .newData : .noData)
        }
    }

    /// Deja pasar la PRIMERA respuesta y descarta las demás. Llamar dos veces al
    /// `completionHandler` de iOS es un fallo del sistema, no un aviso.
    private final class Contestador: @unchecked Sendable {
        private let candado = NSLock()
        private var quedan: ((UIBackgroundFetchResult) -> Void)?
        init(_ handler: @escaping (UIBackgroundFetchResult) -> Void) { quedan = handler }
        func una(_ r: UIBackgroundFetchResult) {
            candado.lock()
            let h = quedan; quedan = nil
            candado.unlock()
            h?(r)
        }
    }

    func application(_ app: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No se calla: sin token no hay aviso con la app cerrada, y quedarse sin saberlo
        // es exactamente el fallo mudo que este repo persigue.
        EasyBitsClient.diag("[push] ⚠️ no me pude registrar: \(error.localizedDescription)")
    }
}
#endif
