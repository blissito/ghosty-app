import Foundation

/// Lo que el agente entregó. La respuesta no siempre es texto, así que un artefacto
/// tiene forma propia y vive fuera del hilo.
struct Artifact: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case document, board, page, sheet, mail }

    let id: String
    var kind: Kind
    var title: String
    var area: String

    var kindLabel: String {
        switch kind {
        case .document: return "Documento"
        case .board:    return "Tablero"
        case .page:     return "Página"
        case .sheet:    return "Hoja"
        case .mail:     return "Borrador"
        }
    }
}
