import Foundation

/// La marca ` ```gs_connect <id>``` ` que gs agrega a la respuesta cuando el agente ofrece
/// conectar una cuenta (`connector_offer`). Se quita del texto y se pinta como tarjeta.
///
/// ⚠️ Misma expresión que gs (`app/lib/texto-del-turno.ts` → `extraerConexiones`): si cambia
/// allá, cambia aquí.
enum ConnectOffers {
    private static let fence = try! NSRegularExpression(
        pattern: "(^|\\n)```gs_connect[ \\t]+([a-z0-9-]{2,40})[ \\t]*\\n?```[ \\t]*(?=\\n|$)")

    /// Los ids en orden (sin repetir) y el texto ya sin las marcas.
    static func extract(_ text: String) -> (ids: [String], rest: String) {
        guard text.contains("```gs_connect") else { return ([], text) }
        let ns = text as NSString
        let matches = fence.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var ids: [String] = []
        for m in matches {
            let id = ns.substring(with: m.range(at: 2))
            if !ids.contains(id) { ids.append(id) }
        }
        // Al revés, para no mover los rangos de las que faltan.
        var rest = text
        for m in matches.reversed() {
            let lead = ns.substring(with: m.range(at: 1))
            rest = (rest as NSString).replacingCharacters(in: m.range, with: lead)
        }
        return (ids, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
