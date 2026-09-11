import Foundation

/// Cómo habla la app con un agente, sin decir POR DÓNDE.
///
/// ⚠️ Existe por una razón concreta y medida: con el WebSocket directo a la caja, **el
/// turno es del teléfono**, y el teléfono se apaga. Comprobado contra la caja real el
/// 2026-09-10 —mandar, cortar el socket a los 3 s, esperar 25 y pedir el hilo: cero
/// caracteres del agente— porque la caída del socket del cliente cierra también el que va
/// hacia el motor, y eso cancela el turno a media ejecución. Un turno ES su socket.
///
/// Contra gs el turno vive en el servidor y sobrevive a que te vayas. Este protocolo es lo
/// que permite tener los dos caminos a la vez y cambiar de uno a otro sin reescribir el
/// store — y volver atrás si el nuevo falla, que es la parte que suele faltar.
protocol TransporteDeAgente: Actor {
    /// Deja el transporte listo. Devuelve cómo se identifica el agente ("nombre versión").
    @discardableResult
    func conectar() async throws -> String

    func sesiones() async throws -> [ACPClient.Session]

    /// El hilo. `nil` si esa conversación tiene un turno vivo y no se puede pisar.
    func cargar(_ id: String, cwd: String) async throws -> [ACPClient.Replay]?

    func nuevaSesion(cwd: String) async throws -> (id: String, modos: ACPClient.Modos?)

    func fijarModo(_ modo: String, sessionID: String) async throws

    /// Un turno, con sus eventos conforme llegan.
    nonisolated func prompt(sessionID: String, texto: String,
                            adjuntos: [Adjunto]) -> AsyncThrowingStream<ACPClient.Replay, Error>

    /// Engancharse a una conversación que ya está trabajando, sin mandar nada.
    ///
    /// ⚠️ Es la mitad que hace útil que el turno sea del servidor. Sin esto, volver a la
    /// app con un turno en marcha enseña tu mensaje y ninguna respuesta: el trabajo sigue
    /// allá y aquí no lo mira nadie. Devuelve `nil` si el transporte no sabe hacerlo —el
    /// WebSocket no puede: allí el turno murió con el socket—.
    nonisolated func seguir(sessionID: String) -> AsyncThrowingStream<ACPClient.Replay, Error>?

    /// Cuántas conversaciones hay por delante cuando el turno tiene que esperar ranura.
    func alHacerCola(_ handler: @escaping @Sendable (Int) -> Void)

    func cancelar(_ sessionID: String) async

    func borrarSesion(_ id: String) async throws

    /// Contesta a un permiso. El id es el que trajo el `Permiso`.
    func responderPermiso(_ id: String, opcion: String) async throws

    func alPedirPermiso(_ handler: @escaping @Sendable (ACPClient.Permiso) -> Void)

    /// Ese permiso ya no espera a nadie: alguien decidió, o se acabó el plazo.
    ///
    /// ⚠️ Hace falta porque quien decide puede no ser este teléfono —el mismo agente se
    /// atiende desde la web— y una tarjeta que sigue pidiendo permiso por algo ya resuelto
    /// es una pantalla que miente y que además no se puede quitar.
    func alResolverPermiso(_ handler: @escaping @Sendable (String) -> Void)

    /// Aviso de que este transporte ya no sirve y hay que pedir otro.
    func alPerderse(_ handler: @escaping @Sendable () -> Void)

    /// Cuántos turnos hay corriendo. Se consulta antes de tirar un transporte a la basura.
    var turnosVivos: Int { get }

    func cerrar()
}
