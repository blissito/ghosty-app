import Foundation

/// El turno en vuelo. `elapsed` viene como texto formateado porque el prototipo no
/// corre reloj: en el cliente real sale de la marca de inicio del turno.
struct TurnActivity: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var detail: String
    var step: Int
    var totalSteps: Int
    var elapsed: String

    var progress: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(step) / Double(totalSteps)
    }
}

/// Una fila de la bitácora: lo que el agente hizo y a qué hora.
struct LogEntry: Identifiable, Equatable, Sendable {
    enum Icon: String, Sendable { case document, web, calendar, code, cart, branch }

    let id: String
    var icon: Icon
    var title: String
    var detail: String
    var time: String
    /// Turnos que cerraron sin nada que reportar se atenúan en vez de esconderse:
    /// esconderlos haría creer que el agente no corrió.
    var muted: Bool = false
}
