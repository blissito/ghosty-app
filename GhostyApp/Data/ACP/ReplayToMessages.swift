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
        // ⚠️ Un array y no un diccionario: el ORDEN es parte del dato —lo que hizo
        // primero— y con un diccionario había que llevar una lista paralela para
        // recuperarlo. Además el `ok` que se guardaba ahí NUNCA se usaba al cerrar, así
        // que un hilo recargado perdía qué había fallado.
        var herramientas: [Herramienta] = []

        enum Quien { case usuario, agente }

        func cerrar() {
            defer { texto = ""; herramientas = [] }
            let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)

            switch quien {
            case .usuario:
                // ⚠️ El replay devuelve el prompt TAL CUAL se envió, fontanería incluida:
                // el bloque de adjuntos, los `curl` y una URL firmada de varias líneas. Sin
                // esto, reabrir un hilo con una nota de voz enseñaba un muro de texto con
                // credenciales dentro donde antes había un reproductor.
                let visible = BloqueDeAdjuntos.limpiarParaMostrar(limpio)
                guard !visible.isEmpty else { return }
                mensajes.append(Message(id: "u\(mensajes.count)", kind: .user(visible)))

            case .agente:
                let tools: ToolRun? = herramientas.isEmpty ? nil : ToolRun(herramientas: herramientas)
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

            case .tool(let h):
                // Una herramienta pertenece al turno del agente aunque llegue antes
                // de que él escriba una palabra.
                if quien != .agente { cerrar(); quien = .agente }
                if let k = herramientas.firstIndex(where: { $0.id == h.id }) {
                    var v = h
                    if v.titulo == "herramienta" { v.titulo = herramientas[k].titulo }
                    if v.salida == nil { v.salida = herramientas[k].salida }
                    herramientas[k] = v
                } else {
                    herramientas.append(h)
                }

            case .usage:
                // El gasto no se pinta en el hilo: vive en el panel de actividad.
                break

            case .entrega:
                // ⚠️ El replay de un hilo NO trae entregas: el relé las empuja en vivo y
                // no las guarda. Lo entregado se recupera del almacén del teléfono, no de
                // aquí. Esta rama existe para que el compilador avise si eso cambia.
                break
            }
        }
        cerrar()
        return mensajes
    }
}
