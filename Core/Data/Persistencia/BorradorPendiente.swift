import Foundation

/// El mensaje que se mandó y todavía no tenía conversación en el servidor.
///
/// ⚠️ Un mensaje en una conversación NUEVA no está en ningún caché: `guardarHilos` sólo
/// guarda hilos con `sesionID`, y hasta que `session/new` contesta no lo hay. Si la app
/// muere en ese hueco (medido el 2026-09-16: gs reiniciándose y la app cerrada a media
/// espera), el texto desaparecía sin rastro. Aquí se apunta al mandar y se borra en cuanto
/// la conversación existe; si al arrancar sigue aquí, vuelve al compositor.
enum BorradorPendiente {
    private static let clave = "ghosty.borradorPendiente"

    static func anotar(_ texto: String, de agente: String) {
        var d = UserDefaults.standard.dictionary(forKey: clave) ?? [:]
        d[agente] = texto
        UserDefaults.standard.set(d, forKey: clave)
    }

    static func olvidar(de agente: String) {
        var d = UserDefaults.standard.dictionary(forKey: clave) ?? [:]
        guard d[agente] != nil else { return }
        d[agente] = nil
        UserDefaults.standard.set(d, forKey: clave)
    }

    /// Lo devuelve y lo borra: es de un solo uso.
    static func recoger(de agente: String) -> String? {
        var d = UserDefaults.standard.dictionary(forKey: clave) ?? [:]
        guard let t = d[agente] as? String else { return nil }
        d[agente] = nil
        UserDefaults.standard.set(d, forKey: clave)
        return t
    }
}
