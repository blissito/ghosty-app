import Foundation

/// Convierte el replay de `session/load` en los mensajes que la pantalla ya sabe
/// pintar.
///
/// ⚠️ Los `*_chunk` llegan **partidos**: un turno del agente puede venir en decenas
/// de trozos. Hay que pegarlos hasta que cambie el hablante, o el hilo sale como
/// cientos de burbujas de una letra.
enum ReplayToMessages {

    static func convertir(_ replay: [ACPClient.Replay]) -> [Message] {
        var mensajes: [Message] = []

        // El turno que se está armando
        var quien: Quien?
        var texto = ""
        var herramientas: [String: (titulo: String, ok: Bool?)] = [:]
        var ordenHerramientas: [String] = []

        enum Quien { case usuario, agente }

        func cerrar() {
            defer { texto = ""; herramientas = [:]; ordenHerramientas = [] }
            let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)

            switch quien {
            case .usuario:
                guard !limpio.isEmpty else { return }
                mensajes.append(Message(id: "u\(mensajes.count)", kind: .user(limpio)))

            case .agente:
                let corridas = ordenHerramientas.compactMap { herramientas[$0] }
                let tools: ToolRun? = corridas.isEmpty ? nil : ToolRun(
                    count: corridas.count,
                    // Los títulos vienen como "shell · cat /opt/goose/skills/…":
                    // se queda la primera parte, que es la que se entiende de un vistazo.
                    summary: corridas
                        .map { $0.titulo.components(separatedBy: " · ").first ?? $0.titulo }
                        .reduce(into: [String]()) { acc, t in if !acc.contains(t) { acc.append(t) } }
                        .joined(separator: " · ")
                )
                guard !limpio.isEmpty || tools != nil else { return }
                mensajes.append(Message(
                    id: "a\(mensajes.count)",
                    kind: .agent(text: limpio.isEmpty ? "_Trabajó sin escribir nada._" : limpio,
                                 tools: tools, trailing: nil)))

            case nil:
                return
            }
        }

        for evento in replay {
            switch evento {
            case .user(let t):
                if quien != .usuario { cerrar(); quien = .usuario }
                texto += t

            case .agent(let t):
                if quien != .agente { cerrar(); quien = .agente }
                texto += t

            case .thought:
                // El razonamiento del agente no va al hilo: es ruido para quien lee,
                // y en la caja son párrafos enteros por turno.
                break

            case .toolCall(let id, let titulo):
                // Una herramienta pertenece al turno del agente aunque llegue antes
                // de que él escriba una palabra.
                if quien != .agente { cerrar(); quien = .agente }
                if herramientas[id] == nil { ordenHerramientas.append(id) }
                herramientas[id] = (titulo, nil)

            case .toolDone(let id, let ok):
                if let previa = herramientas[id] {
                    herramientas[id] = (previa.titulo, ok)
                }

            case .usage:
                // El gasto no se pinta en el hilo: vive en el panel de actividad.
                break
            }
        }
        cerrar()
        return mensajes
    }
}
