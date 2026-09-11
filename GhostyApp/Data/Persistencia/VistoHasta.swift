import Foundation

/// Hasta cuándo VISTE cada conversación. Es lo que, comparado con `ultimoTurno.endedAt`
/// del servidor, decide si la lista dice «contestó» (sin ver) o nada.
///
/// Vive aparte de `hilos.json` a propósito: es un mapa pequeño que cambia al tocar una
/// fila, y el caché de hilos se re-serializa entero — no hay que pagar eso por un toque.
enum VistoHasta {
    private static let clave = "ghosty.vistoHasta"

    static func de(_ sesion: String) -> Date? {
        (UserDefaults.standard.dictionary(forKey: clave)?[sesion] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static func marcar(_ sesion: String, _ fecha: Date = Date()) {
        var d = UserDefaults.standard.dictionary(forKey: clave) ?? [:]
        d[sesion] = fecha.timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: clave)
    }
}
