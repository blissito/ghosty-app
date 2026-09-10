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
    ///
    /// El objeto es el `agentID` y el `userInfo` lleva `sesion` cuando se sabe: con varias
    /// conversaciones por agente, abrir «el agente» ya no dice a cuál ir.
    static let alTocar = Notification.Name("ghosty.avisoTocado")

    private static var pedido = false
    private static let delegado = Delegado()

    /// Se pide la PRIMERA vez que dejas a un agente trabajando y te vas con otro, no al
    /// arrancar: ahí no hay contexto y el permiso se rechaza.
    static func pedirPermisoSiHaceFalta() {
        guard !pedido else { return }
        pedido = true
        UNUserNotificationCenter.current().delegate = delegado
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            guard ok else { return }
            // ⚠️ El registro para PUSH va aquí y no antes: pedirlo sin permiso concedido
            // no sirve de nada. Y es lo único que hace que un aviso llegue con la app
            // CERRADA — los locales de este archivo sólo existen mientras la app vive.
            Task { @MainActor in
                #if canImport(UIKit)
                UIApplication.shared.registerForRemoteNotifications()
                #endif
            }
        }
    }

    /// Al arrancar: si ya diste permiso, volver a registrarse.
    ///
    /// ⚠️ Hace falta en CADA arranque, no sólo la vez que concedes el permiso. El token de
    /// APNs cambia al reinstalar o al restaurar el teléfono, y un token viejo es un aviso
    /// que se pierde en silencio: el servidor cree que avisó y tú no ves nada. Y sin
    /// `registerForRemoteNotifications` iOS **no entrega** ningún push, ni siquiera el
    /// silencioso — que es justo lo que hace que no se pueda probar sin darse cuenta.
    static func registrarSiYaHayPermiso() {
        #if canImport(UIKit)
        // Gancho de desarrollo: en el simulador no se puede tocar el diálogo del permiso.
        if ProcessInfo.processInfo.environment["GHOSTY_PUSH"] == "1" {
            UNUserNotificationCenter.current().delegate = delegado
            UIApplication.shared.registerForRemoteNotifications()
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { ajustes in
            guard ajustes.authorizationStatus == .authorized else { return }
            Task { @MainActor in
                pedido = true
                UNUserNotificationCenter.current().delegate = delegado
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        #endif
    }

    /// El teléfono ya tiene su ficha en el servidor.
    private static var tokenEnviado: String?

    /// Lo que Apple nos dio, camino de gs.
    ///
    /// ⚠️ Se reenvía al arrancar y al cambiar de cuenta, no una sola vez: el token cambia
    /// al reinstalar o restaurar el teléfono, y un token viejo es un aviso que se pierde
    /// en silencio — el servidor cree que avisó y tú no ves nada.
    static func registrar(token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard hex != tokenEnviado else { return }
        tokenEnviado = hex
        EasyBitsClient.diag("[push] token \(hex.prefix(12))… (\(entorno))")
        Task { await GhostyAPI.registrarDispositivo(token: hex, entorno: entorno) }
    }

    /// ⚠️ Lo decide el BUILD, no una preferencia. **TestFlight usa producción** aunque sea
    /// beta, y equivocarse aquí no da error: simplemente no llega nada.
    static var entorno: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// Los dos sonidos de la casa. Son archivos propios y no tonos del sistema porque los
    /// del sistema son de "te ha llegado un mensaje", y aquí lo que pasa es otra cosa:
    /// algo que llevaba rato trabajando terminó.
    ///
    /// - `burbuja`: terminó un turno. Un pop corto que sube de tono al apagarse.
    /// - `gota`: te necesita. Dos golpes, para que se distinga del anterior sin mirar —
    ///   que es el punto: uno puede esperar, el otro tiene el trabajo detenido.
    enum Sonido: String {
        case burbuja, gota
    }

    /// ⚠️ El id se guarda. `AudioServicesCreateSystemSoundID` en cada aviso filtra memoria
    /// y, con varias conversaciones terminando seguidas, mete un retraso audible entre el
    /// hecho y su sonido.
    private static var sonidos: [Sonido: SystemSoundID] = [:]

    static func sonar(_ cual: Sonido) {
        let id: SystemSoundID
        if let ya = sonidos[cual] {
            id = ya
        } else {
            guard let url = Bundle.main.url(forResource: cual.rawValue, withExtension: "caf") else {
                // No se calla: quedarse sin sonido sin enterarse es el fallo mudo de siempre.
                EasyBitsClient.diag("[avisos] ⚠️ falta \(cual.rawValue).caf en el bundle")
                return
            }
            var nuevo: SystemSoundID = 0
            AudioServicesCreateSystemSoundID(url as CFURL, &nuevo)
            sonidos[cual] = nuevo
            id = nuevo
        }
        AudioServicesPlaySystemSound(id)
    }

    /// El sonido de "ya acabó".
    ///
    /// ⚠️ Suena SÓLO cuando no estabas mirando esa conversación: un sonido por cada turno
    /// que ves terminar delante de ti se vuelve ruido en dos minutos.
    static func sonarFin() {
        sonar(.burbuja)
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func avisar(titulo: String, cuerpo: String, agentID: String,
                       sonido: Sonido = .burbuja) {
        let c = UNMutableNotificationContent()
        c.title = titulo
        c.body = cuerpo
        // El mismo sonido que suena con la app delante: que el aviso suene distinto según
        // por dónde llegue enseña a no fiarse de lo que se oye.
        c.sound = UNNotificationSound(named: UNNotificationSoundName("\(sonido.rawValue).caf"))
        c.userInfo = ["agentID": agentID]
        // Agrupa por conversación, igual que hará el push del servidor: con tres
        // conversaciones a la vez, sin esto son tres avisos sueltos sin relación.
        c.threadIdentifier = agentID
        // Sin disparador: se entrega ya.
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// ¿Está la app en el fondo? Decide si el aviso hace falta cuando el agente que
    /// termina SÍ es el que estás mirando.
    /// ¿Puede el servidor avisar por su cuenta? Si sí, los avisos locales sobran cuando la
    /// app no está delante — verías dos por el mismo hecho, y un aviso duplicado enseña a
    /// ignorar los avisos.
    static var hayPush: Bool { tokenEnviado != nil }

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
            let info = respuesta.notification.request.content.userInfo
            // `agentID` lo pone el aviso local; `agentId` el push del servidor. Se aceptan
            // los dos en vez de obligar a nadie a cambiar de nombre.
            guard let id = (info["agentID"] as? String) ?? (info["agentId"] as? String)
            else { return }
            let sesion = (info["sesion"] as? String) ?? (info["sessionId"] as? String)
            await MainActor.run {
                NotificationCenter.default.post(name: Avisos.alTocar, object: id,
                                                userInfo: sesion.map { ["sesion": $0] })
            }
        }
    }
}
