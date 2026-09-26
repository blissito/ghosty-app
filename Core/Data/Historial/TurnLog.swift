import Foundation
import Observation

/// Un turno que ya cerró, con lo que la app sí puede medir.
///
/// ⚠️ Esto registra **lo que pasó por este teléfono**, no todo lo que hizo el agente.
/// La caja `ghosty-lite` no expone el API de administración —su passthrough contesta
/// 502 «agent /message 404» en `/admin/…/activity`—, así que un turno que alguien
/// lanzó desde otro cliente no aparece aquí. Es una bitácora honesta, no completa.
struct TurnRecord: Identifiable, Codable, Equatable {
    let id: String
    var agentID: String
    var agentName: String
    var prompt: String
    var startedAt: Date
    var seconds: Int
    var inputTokens: Int
    var outputTokens: Int
    /// Cómo terminó: normal, detenido a mano, o cortado.
    var outcome: Outcome
    var replyChars: Int

    enum Outcome: String, Codable {
        case done, stopped, failed
    }

    var elapsedText: String {
        seconds >= 60 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "\(seconds)s"
    }

    var totalTokens: Int { inputTokens + outputTokens }
}

/// Guarda la bitácora en disco. No va al llavero: no es un secreto, y así sobrevive
/// a que alguien borre la credencial.
///
/// `@Observable` porque si no, un turno que termina con la hoja abierta no repinta
/// nada: la lista se queda como estaba y parece que no se registró.
@Observable
@MainActor
final class TurnLogStore {
    private(set) var records: [TurnRecord] = []
    private let tope = 200          // más que eso no se lee nunca y engorda el arranque

    private var archivo: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "turnos.json")
    }

    init() { cargar() }

    func registrar(_ r: TurnRecord) {
        records.insert(r, at: 0)
        if records.count > tope { records = Array(records.prefix(tope)) }
        guardar()
    }

    func limpiar() {
        records = []
        try? FileManager.default.removeItem(at: archivo)
    }

    /// Los de hoy, que es lo que la pestaña de actividad enseña primero.
    func deHoy(agentID: String? = nil) -> [TurnRecord] {
        let cal = Calendar.current
        return records.filter {
            cal.isDateInToday($0.startedAt) && (agentID == nil || $0.agentID == agentID)
        }
    }

    func resumen(agentID: String? = nil) -> (turnos: Int, tokens: Int, segundos: Int) {
        let hoy = deHoy(agentID: agentID)
        return (hoy.count,
                hoy.reduce(0) { $0 + $1.totalTokens },
                hoy.reduce(0) { $0 + $1.seconds })
    }

    // MARK: - Disco

    private func cargar() {
        guard let d = try? Data(contentsOf: archivo),
              let l = try? JSONDecoder().decode([TurnRecord].self, from: d) else { return }
        records = l
    }

    private func guardar() {
        guard let d = try? JSONEncoder().encode(records) else { return }
        try? d.write(to: archivo, options: .atomic)
    }
}
