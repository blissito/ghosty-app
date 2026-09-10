import Foundation
import Observation

enum EstadoHilos: Equatable { case sinPedir, cargando, listo, fallo(String) }

/// Todo lo VIVO de un agente: su socket, su hilo, su turno y su conversación.
///
/// ⚠️ Antes esto era estado suelto del store —un `acp`, un `turnoEnVuelo`, un
/// `currentTurn`— y por eso cambiar de agente **mataba el trabajo del otro**:
/// `seleccionar` cerraba el socket y el siguiente `send` cancelaba la tarea que
/// seguía viva. Un agente por canal es lo que hace que dejar a uno trabajando e irte
/// con otro sea literalmente cierto, y no una promesa de la interfaz.
@Observable
@MainActor
final class Canal {
    let cuenta: AgentAccount

    init(cuenta: AgentAccount) { self.cuenta = cuenta }

    /// La conversación abierta de ESTE agente.
    var mensajes: [Message] = []
    /// El turno en curso, si lo hay. Es también la respuesta a "¿está trabajando?".
    var turno: TurnActivity?
    var hilosRemotos: [ACPClient.Session] = []
    var estadoHilos: EstadoHilos = .sinPedir
    var infoDeLaCaja: String?
    var hiloAbierto: String?
    /// El permiso que espera ESTE agente. Vive aquí porque uno puede pedir permiso
    /// mientras miras a otro, y perderlo dejaría su turno detenido para siempre.
    var permisoACP: ACPClient.Permiso?
    var permisoPendiente: PermissionRequest?
    var sesionID: String?
    var modo = "auto"

    // Fontanería del turno.
    var acp: ACPClient?
    var creandoHilo: Task<String, Error>?
    var enVuelo: Task<Void, Never>?
    var prompt = ""
    var uso = (entrada: 0, salida: 0)
    var inicio: Date?
    var cronometro: Task<Void, Never>?

    var trabajando: Bool { turno != nil }

    /// Cuánto lleva el turno, para poder decirlo en la lista de la flota.
    var transcurrido: String { turno?.elapsed ?? "" }

    func soltar() {
        enVuelo?.cancel(); enVuelo = nil
        cronometro?.cancel(); cronometro = nil
        creandoHilo = nil
        turno = nil
        let cliente = acp
        acp = nil
        Task { await cliente?.cerrar() }
    }
}
