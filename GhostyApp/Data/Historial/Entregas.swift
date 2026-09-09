import Foundation
import Observation

/// Algo que el agente ENTREGÓ: un archivo suyo o un artefacto que escribió.
///
/// Llega por la notificación `ghosty/artifact` del relé, en el mismo socket del turno,
/// cuando el agente usa `entregar_archivo` o `crear_artefacto`. Sin eso, lo que escribe
/// se queda en el disco de su máquina y no lo ve nadie — que es exactamente lo que
/// pasaba hasta ahora en el teléfono.
///
/// ⚠️ Se guarda AQUÍ porque la entrega es un empujón, no un estado consultable: el relé
/// la manda una vez, en vivo, y no hay endpoint que la vuelva a dar. Un `session/load`
/// devuelve la llamada a la herramienta, no lo entregado. Si no se persiste en el
/// teléfono, cerrar la app la pierde.
struct Entrega: Identifiable, Codable, Equatable, Sendable {
    /// Qué se recibió. El relé manda `tipo` y, para un artefacto, `subtipo`.
    enum Forma: String, Codable, Sendable {
        case archivo    // un fichero del disco del agente, en base64
        case doc        // prosa en Markdown
        case sheet      // tabla en CSV
        case artifact   // HTML autocontenido
    }

    let id: String
    var agentID: String
    var forma: Forma
    var titulo: String
    var recibida: Date
    /// El texto del artefacto, o `nil` si lo entregado fue un archivo.
    var contenido: String?
    /// El archivo, ya decodificado. `nil` para un artefacto.
    var datos: Data?

    var etiqueta: String {
        switch forma {
        case .archivo:  "Archivo"
        case .doc:      "Documento"
        case .sheet:    "Tabla"
        case .artifact: "Página"
        }
    }

    var icono: String {
        switch forma {
        case .archivo:  "paperclip"
        case .doc:      "doc.text"
        case .sheet:    "tablecells"
        case .artifact: "safari"
        }
    }

    /// Lo que ocupa, para poder decirlo sin abrirlo.
    var peso: String? {
        let n = datos?.count ?? contenido?.utf8.count
        guard let n, n > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

/// Guarda las entregas en disco, igual que la bitácora de turnos y por la misma razón:
/// no son secreto, y así sobreviven a que alguien borre la credencial.
@Observable
@MainActor
final class EntregasStore {
    private(set) var entregas: [Entrega] = []
    /// ⚠️ Más bajo que el de los turnos a propósito: aquí cada fila lleva el CONTENIDO,
    /// no un puñado de contadores. Cincuenta artefactos de medio mega se leen enteros en
    /// cada arranque.
    private let tope = 50

    private var archivo: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "entregas.json")
    }

    init() { cargar() }

    func registrar(_ e: Entrega) {
        entregas.insert(e, at: 0)
        if entregas.count > tope { entregas = Array(entregas.prefix(tope)) }
        guardar()
    }

    func de(_ agentID: String?) -> [Entrega] {
        guard let agentID else { return entregas }
        return entregas.filter { $0.agentID == agentID }
    }

    func limpiar() {
        entregas = []
        try? FileManager.default.removeItem(at: archivo)
    }

    // MARK: - Disco

    private func cargar() {
        guard let d = try? Data(contentsOf: archivo),
              let l = try? JSONDecoder().decode([Entrega].self, from: d) else { return }
        entregas = l
    }

    private func guardar() {
        guard let d = try? JSONEncoder().encode(entregas) else { return }
        try? d.write(to: archivo, options: .atomic)
    }
}
