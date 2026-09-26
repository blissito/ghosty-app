import Foundation

/// Las tres respuestas posibles. El caso de en medio es el que evita la ceguera de
/// banner: sin él la gente aprueba todo con tal de avanzar.
enum PermissionDecision: String, Sendable {
    case allowOnce
    case allowForTask
    case deny
}

/// Un `session/request_permission` de ACP, ya traducido a lo que la pantalla necesita.
struct PermissionRequest: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case email, purchase, push, publish }

    let id: String
    var kind: Kind
    var agentName: String
    var question: String
    var detail: String
    var attachment: Attachment?

    struct Attachment: Equatable, Sendable {
        var filename: String
        var meta: String
    }
}

/// Una decisión ya tomada, para el historial de la hoja.
struct PermissionRecord: Identifiable, Equatable, Sendable {
    let id: String
    var icon: LogEntry.Icon
    var title: String
    var detail: String
    var outcome: String
}
