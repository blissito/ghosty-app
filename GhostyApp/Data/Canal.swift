import Foundation
import Observation

enum EstadoHilos: Equatable { case sinPedir, cargando, listo, fallo(String) }

/// UNA conversación viva: sus mensajes, su turno y su permiso.
///
/// ⚠️ Esto existía por AGENTE y estaba mal. Con un solo hilo por agente, abrir otra
/// conversación mientras una contestaba pisaba `mensajes` y `sesionID`, y el turno que
/// seguía corriendo escribía su respuesta **dentro del hilo recién abierto**: dos
/// conversaciones cosidas en pantalla. Y no se podía pedirle dos cosas a la vez al mismo
/// agente, que era justo lo que se buscaba.
///
/// El socket sigue siendo uno por agente (ver `Canal`): son hilos de una misma caja, no
/// cajas distintas. Lo que los separa es el `sessionId`, que el protocolo ya mandaba.
@Observable
@MainActor
final class Hilo {
    /// Identidad LOCAL y estable. Existe desde antes que la de la caja: un hilo nuevo
    /// tiene mensajes en pantalla mientras `session/new` está en vuelo, y sin esto no
    /// habría a qué colgarlos.
    let clave = UUID().uuidString
    /// La de la caja. `nil` = todavía no se ha creado allá.
    var sesionID: String?

    var mensajes: [Message] = []
    var turno: TurnActivity?
    var permisoACP: ACPClient.Permiso?
    var permisoPendiente: PermissionRequest?
    var modo = "auto"

    var enVuelo: Task<Void, Never>?
    var cronometro: Task<Void, Never>?
    var creando: Task<String, Error>?
    /// En qué conexión se rehidrató esta sesión por última vez.
    ///
    /// ⚠️ La caja **no conserva la sesión entre conexiones**: al reconectar, mandarle un
    /// turno con el `sessionId` viejo le llega a una sesión que para ella empieza en
    /// blanco, y el agente contesta "no tengo contexto previo, esta conversación empieza
    /// con tu mensaje". Hay que hacerle `session/load` una vez por socket.
    var cargadaEn: ObjectIdentifier?
    var prompt = ""
    /// ¿Se cayó el último envío ANTES de llegar al agente? Vive en el HILO: con dos
    /// envíos a la vez, un fallo global le devolvía los adjuntos a la conversación
    /// equivocada — o le borraba los suyos a la que sí salió.
    var envioFallo = false
    /// Viene de un caché anterior al ruteo por hilo y **puede estar cruzado**. Se pinta
    /// igual (no le quitamos nada a nadie sin red) pero se recarga en cuanto se pueda.
    var sospechoso = false
    var uso = (entrada: 0, salida: 0)
    var inicio: Date?

    var trabajando: Bool { turno != nil }
    var transcurrido: String { turno?.elapsed ?? "" }

    /// De qué va, para poder nombrarlo en una lista.
    var titulo: String {
        if !prompt.isEmpty { return String(prompt.prefix(40)) }
        for m in mensajes { if case .user(let t, _) = m.kind, !t.isEmpty { return String(t.prefix(40)) } }
        return "Conversación nueva"
    }

    func soltar() {
        enVuelo?.cancel(); enVuelo = nil
        cronometro?.cancel(); cronometro = nil
        creando = nil
        turno = nil
    }
}

/// Un AGENTE conectado: su socket y las conversaciones que tienes abiertas con él.
///
/// El socket es uno solo a propósito. Uno por hilo multiplicaría las conexiones a la
/// caja por cada conversación abierta y hay un límite; el protocolo ya sabe repartir por
/// `sessionId`, así que no hace falta.
@Observable
@MainActor
final class Canal {
    let cuenta: AgentAccount

    init(cuenta: AgentAccount) { self.cuenta = cuenta }

    /// Las conversaciones abiertas, la más reciente al final.
    var hilos: [Hilo] = []
    /// Cuál se está mirando (su `clave`).
    var activa: String?

    var hilosRemotos: [ACPClient.Session] = []
    var estadoHilos: EstadoHilos = .sinPedir
    var infoDeLaCaja: String?
    /// ¿Se está despertando la caja ahora mismo? Sin esto la app se siente colgada:
    /// levantar una caja dormida tarda segundos y no había nada que lo dijera.
    var despertando = false

    var acp: ACPClient?
    /// La apertura de socket en vuelo, COMPARTIDA. Sin esto, dos conversaciones
    /// arrancando a la vez abrían dos sockets contra la misma caja.
    var abriendoSocket: Task<ACPClient, Error>?
    /// Cronómetro heredado; el de verdad vive en cada `Hilo`.
    var cronometro: Task<Void, Never>?

    /// La conversación que se mira.
    ///
    /// ⚠️ Si `activa` apunta a una que ya no está, **cae en la última en vez de en nada**.
    /// Devolver `nil` parecía más honesto y era peor: quien preguntaba acababa abriendo
    /// una conversación NUEVA, así que salir a otra pestaña y volver te dejaba con el hilo
    /// en blanco en lugar del que habías cargado.
    var hilo: Hilo? {
        if let activa, let h = hilos.first(where: { $0.clave == activa }) { return h }
        return hilos.last
    }

    /// Cuántas conversaciones se guardan en memoria. Abiertas cuestan poco, pero no
    /// tiene sentido arrastrar veinte: se cierra la más vieja que no esté trabajando ni
    /// esperándote.
    private static let topeAbiertas = 8

    func podar() {
        guard hilos.count > Self.topeAbiertas else { return }
        while hilos.count > Self.topeAbiertas,
              let sobra = hilos.first(where: {
                  !$0.trabajando && $0.permisoPendiente == nil && $0.clave != activa
              }) {
            cerrar(sobra)
        }
    }

    func hilo(sesion: String) -> Hilo? { hilos.first { $0.sesionID == sesion } }

    /// Uno nuevo, vacío, y pasa a ser el que se mira.
    @discardableResult
    func abrir(_ sesionID: String? = nil) -> Hilo {
        if let sesionID, let ya = hilo(sesion: sesionID) { activa = ya.clave; return ya }
        let h = Hilo()
        h.sesionID = sesionID
        hilos.append(h)
        activa = h.clave
        return h
    }

    func cerrar(_ h: Hilo) {
        h.soltar()
        hilos.removeAll { $0.clave == h.clave }
        if activa == h.clave { activa = hilos.last?.clave }
    }

    /// Los que están contestando ahora mismo.
    var enCurso: [Hilo] { hilos.filter(\.trabajando) }
    var trabajando: Bool { !enCurso.isEmpty }
    /// Los que te están esperando a ti.
    var esperandoPermiso: [Hilo] { hilos.filter { $0.permisoPendiente != nil } }

    func soltar() {
        for h in hilos { h.soltar() }
        hilos = []
        activa = nil
        let cliente = acp
        acp = nil
        Task { await cliente?.cerrar() }
    }
}
