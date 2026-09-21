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
    /// Uno para toda la app: `Hilo.titulo` lo consulta y el store lo escribe.
    static let compartido = TitleStore()

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

    /// ⚠️ La clave lleva el AGENTE. El id de sesión lo pone la CAJA (`20260916_1`) y se
    /// repite entre agentes —y en el mismo agente si su caja se recrea—: con la clave a
    /// secas, una conversación nueva heredaba el título de otra.
    private static func clave(_ agentID: String, _ sessionID: String) -> String { "\(agentID)/\(sessionID)" }

    func titulo(_ agentID: String, _ sessionID: String) -> String? {
        guard let t = titulos[Self.clave(agentID, sessionID)], !Self.esFontaneria(t) else { return nil }
        return t
    }

    /// Un título que gs bautizó con el bloque de contexto delante («[CONVERSACIÓN PREVIA
    /// DE ESTE MISMO HILO…»). gs ya no los produce, pero los que quedaron guardados aquí
    /// y en su tabla no dicen nada: se tratan como sin título.
    static func esFontaneria(_ t: String) -> Bool {
        t.hasPrefix("[CONVERSACIÓN PREVIA") || t.hasPrefix("[ADJUNTOS DE ESTE MENSAJE")
    }

    /// Sólo el primero manda: el título de un hilo es de lo que se habló al abrirlo,
    /// no del último mensaje.
    /// Lo que dice el SERVIDOR pisa lo local: desde el 2026-09-19 gs bautiza cada hilo al
    /// cerrar su primer turno, y ése es el título que ven las demás superficies.
    func anotar(_ agentID: String, _ sessionID: String, titulo: String) {
        let k = Self.clave(agentID, sessionID)
        guard !titulo.isEmpty, !Self.esFontaneria(titulo), titulos[k] != titulo else { return }
        titulos[k] = titulo
        guardar()
    }

    func anotarSiFalta(_ agentID: String, _ sessionID: String, desde texto: String) {
        let k = Self.clave(agentID, sessionID)
        guard titulos[k] == nil else { return }
        let limpio = texto
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !limpio.isEmpty else { return }
        titulos[k] = String(limpio.prefix(60))
        guardar()
    }

    func olvidar(_ agentID: String, _ sessionID: String) {
        titulos[Self.clave(agentID, sessionID)] = nil
        guardar()
    }

    private func guardar() {
        guard let d = try? JSONEncoder().encode(titulos) else { return }
        try? d.write(to: archivo, options: .atomic)
    }
}
