import Foundation

/// Por dónde viajan los turnos.
///
/// ⚠️ Vive fuera del store, y `nonisolated`, porque lo pregunta también quien lee la flota
/// —el token y el host de la caja sólo hacen falta con el WebSocket— y eso pasa antes de
/// que exista ningún canal.
enum Transporte {
    private static let llave = "ghosty.transporte.gs"

    /// ¿Los turnos son del servidor?
    ///
    /// La variable de entorno manda sobre la preferencia: es lo que deja probar las dos
    /// rutas en el simulador sin tocar lo que alguien haya elegido en su teléfono.
    static var porGS: Bool {
        if let env = ProcessInfo.processInfo.environment["GHOSTY_TRANSPORTE"] { return env == "gs" }
        // ⚠️ ENCENDIDO por defecto, y el interruptor sirve para APAGARLO. Con el
        // transporte viejo, bloquear el teléfono a media respuesta pierde el turno
        // siempre —está medido: cero caracteres— y eso es lo contrario de lo que esta app
        // promete. Dejarlo apagado por prudencia era dejar el fallo puesto.
        guard UserDefaults.standard.object(forKey: llave) != nil else { return true }
        return UserDefaults.standard.bool(forKey: llave)
    }

    /// El interruptor de Ajustes. Está para poder VOLVER al camino de siempre sin
    /// reinstalar nada si algo sale mal — que es lo que hace que encenderlo por defecto no
    /// sea una apuesta.
    static var elegido: Bool {
        get { porGS }
        set { UserDefaults.standard.set(newValue, forKey: llave) }
    }
}
