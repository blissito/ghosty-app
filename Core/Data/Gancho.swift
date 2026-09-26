import Foundation

/// Los ganchos de desarrollo por variable de entorno (`GHOSTY_DEMO`, `GHOSTY_PROBE`,
/// `GHOSTY_TOKEN`… ver CLAUDE.md). Son lo que permite verificar la app en el simulador
/// sin poder tocar la pantalla.
///
/// ⚠️ En Release NO existen: esto devuelve `nil` siempre. Antes cada gancho decidía por su
/// cuenta si iba detrás de `#if DEBUG`, y la mitad no iba: `GHOSTY_DEMO` (que salta el
/// login) y `GHOSTY_PROBE` (que manda un mensaje al arrancar) viajaban compilados en la
/// build de la tienda. Un solo punto de entrada es lo que hace imposible olvidarse.
enum Gancho {
    static func valor(_ nombre: String) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment[nombre]
        #else
        return nil
        #endif
    }

    static func encendido(_ nombre: String) -> Bool { valor(nombre) == "1" }
}
