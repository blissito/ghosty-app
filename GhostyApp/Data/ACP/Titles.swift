import Foundation
import Observation

/// Los títulos de los hilos, guardados en el teléfono.
///
/// ⚠️ **La caja no los nombra**: `session/list` devuelve `title: "New Chat"` con
/// `userSetName: false` para todos, y **`session/set_title` no existe** en el
/// protocolo (contesta `-32601 Method not found`). Así que el título se deriva del
/// primer mensaje del hilo y se guarda aquí.
@Observable
@MainActor
final class TitleStore {
    private var titulos: [String: String] = [:]

    private var archivo: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "titulos.json")
    }

    init() {
        if let d = try? Data(contentsOf: archivo),
           let m = try? JSONDecoder().decode([String: String].self, from: d) {
            titulos = m
        }
    }

    func titulo(_ sessionID: String) -> String? { titulos[sessionID] }

    /// Sólo el primero manda: el título de un hilo es de lo que se habló al abrirlo,
    /// no del último mensaje.
    func anotarSiFalta(_ sessionID: String, desde texto: String) {
        guard titulos[sessionID] == nil else { return }
        let limpio = texto
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !limpio.isEmpty else { return }
        titulos[sessionID] = String(limpio.prefix(60))
        guardar()
    }

    func olvidar(_ sessionID: String) {
        titulos[sessionID] = nil
        guardar()
    }

    private func guardar() {
        guard let d = try? JSONEncoder().encode(titulos) else { return }
        try? d.write(to: archivo, options: .atomic)
    }
}
