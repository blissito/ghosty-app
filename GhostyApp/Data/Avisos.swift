import Foundation
import AudioToolbox
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Los avisos del teléfono cuando un agente termina o pide permiso y no lo estás mirando.
///
/// ⚠️ Esto NO necesita entitlement, capability ni `aps-environment`: eso es sólo para el
/// push remoto, que viene del servidor. Una notificación **local** la programa la propia
/// app y basta con que la persona la autorice.
///
/// ⚠️ Y lo que NO hace, dicho aquí para no prometerlo en la interfaz: con la app **cerrada**
/// iOS suspende el WebSocket, así que no hay turno vivo del que avisar. Esto cubre "la app
/// está abierta, o recién mandada al fondo", que es el caso de todos los días. Avisar con
/// la app cerrada necesita push desde el servidor.
@MainActor
enum Avisos {
    /// A quién hay que abrir cuando se toca un aviso. `RootView` lo escucha.
    static let alTocar = Notification.Name("ghosty.avisoTocado")

    private static var pedido = false
    private static let delegado = Delegado()

    /// Se pide la PRIMERA vez que dejas a un agente trabajando y te vas con otro, no al
    /// arrancar: ahí no hay contexto y el permiso se rechaza.
    static func pedirPermisoSiHaceFalta() {
        guard !pedido else { return }
        pedido = true
        UNUserNotificationCenter.current().delegate = delegado
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// El sonido de "ya acabó".
    ///
    /// ⚠️ Suena SÓLO cuando no estabas mirando esa conversación: un sonido por cada turno
    /// que ves terminar delante de ti se vuelve ruido en dos minutos. Es un sonido del
    /// sistema y no un archivo propio a propósito — encaja con el resto del teléfono y no
    /// añade un asset que mantener.
    static func sonarFin() {
        AudioServicesPlaySystemSound(1057)
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func avisar(titulo: String, cuerpo: String, agentID: String) {
        let c = UNMutableNotificationContent()
        c.title = titulo
        c.body = cuerpo
        c.sound = .default
        c.userInfo = ["agentID": agentID]
        // Sin disparador: se entrega ya.
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// ¿Está la app en el fondo? Decide si el aviso hace falta cuando el agente que
    /// termina SÍ es el que estás mirando.
    static var enElFondo: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState != .active
        #else
        false
        #endif
    }

    private final class Delegado: NSObject, UNUserNotificationCenterDelegate {
        /// Con la app delante también se enseña: si estás en el hilo de otro agente, el
        /// banner es justo la forma de enterarte sin cambiar de pantalla.
        func userNotificationCenter(_ c: UNUserNotificationCenter,
                                    willPresent n: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

        func userNotificationCenter(_ c: UNUserNotificationCenter,
                                    didReceive respuesta: UNNotificationResponse) async {
            guard let id = respuesta.notification.request.content.userInfo["agentID"] as? String
            else { return }
            await MainActor.run {
                NotificationCenter.default.post(name: Avisos.alTocar, object: id)
            }
        }
    }
}
