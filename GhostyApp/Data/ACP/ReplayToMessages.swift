import Foundation

/// Convierte el replay de `session/load` en los mensajes que la pantalla ya sabe
/// pintar.
///
/// ⚠️ Los `*_chunk` llegan **partidos**: un turno del agente puede venir en decenas
/// de trozos. Hay que pegarlos hasta que cambie el hablante, o el hilo sale como
/// cientos de burbujas de una letra.
enum ReplayToMessages {

    /// `archivos` es el índice `nombre → archivo de la cuenta` de esta sesión. Es lo que
    /// devuelve a la vida un adjunto: el replay de ACP trae SÓLO texto, así que sin él una
    /// nota de voz vuelve como una línea muerta con el nombre del archivo.
    static func convertir(_ replay: [ACPClient.Replay],
                          archivos: [String: GhostyAPI.ArchivoDeSesion] = [:]) -> [Message] {
        var mensajes: [Message] = []
        /// Las tarjetas de `eb-file` que salieron del texto, con dónde van.
        var entregasDelReplay: [(Int, Entrega)] = []

        // El turno que se está armando
        var quien: Quien?
        var texto = ""
        // ⚠️ Un array y no un diccionario: el ORDEN es parte del dato —lo que hizo
        // primero— y con un diccionario había que llevar una lista paralela para
        // recuperarlo. Además el `ok` que se guardaba ahí NUNCA se usaba al cerrar, así
        // que un hilo recargado perdía qué había fallado.
        var herramientas: [Herramienta] = []
        // Igual que en vivo: lo que el agente escribe DESPUÉS de llamar una herramienta
        // es otro párrafo, no la continuación de la frase anterior.
        var separarTrasHerramienta = false

        enum Quien { case usuario, agente }

        func cerrar() {
            defer { texto = ""; herramientas = []; separarTrasHerramienta = false }
            let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)

            switch quien {
            case .usuario:
                // Un mensaje de la plataforma («⏰ Turno programado … (causa)») es una línea
                // de sistema, no una burbuja de la persona.
                if limpio.hasPrefix("⏰ ") {
                    mensajes.append(Message(id: "s\(mensajes.count)", kind: .sistema(ClienteGS.causaDeSistema(limpio))))
                    return
                }
                // ⚠️ El replay devuelve el prompt TAL CUAL se envió, fontanería incluida:
                // el bloque de adjuntos, los `curl` y una URL firmada de varias líneas. Sin
                // esto, reabrir un hilo con una nota de voz enseñaba un muro de texto con
                // credenciales dentro donde antes había un reproductor.
                let (visible, nombres) = BloqueDeAdjuntos.limpiarParaMostrar(limpio)
                // Se reconstruyen SIN bytes: `remoto` lleva el id con el que bajarlos, y la
                // duración y la onda vienen del `meta` que se guardó al subir. Con eso
                // `esVoz` vuelve a ser cierto y la burbuja pinta el reproductor sin que haya
                // que tocar una línea de su reparto.
                //
                // ⚠️ Un archivo sin `meta` (los de antes de que se guardara) NO se convierte
                // en nota de voz: se queda como fila de archivo. Inventarle una onda plana
                // sería pintar un widget que miente sobre lo que se grabó.
                let recuperados: [Adjunto] = nombres.compactMap { nombre in
                    guard let f = archivos[nombre] else { return nil }
                    var a = Adjunto(nombre: f.nombre, mime: f.mime, datos: Data(),
                                    segundos: f.segundos, onda: f.onda)
                    a.remoto = GhostyAPI.ArchivoRemoto(id: f.id, nombre: f.nombre, mime: f.mime,
                                                       bytes: f.bytes, url: "")
                    return a
                }
                // Los que no se pudieron recuperar se siguen NOMBRANDO: que se mandó un
                // archivo es información de la persona, y callarlo deja el mensaje cojo.
                let huerfanos = nombres.filter { archivos[$0] == nil }
                let pie = huerfanos.isEmpty ? "" : "Adjunto: " + huerfanos.joined(separator: ", ")
                let texto = [visible, pie].filter { !$0.isEmpty }.joined(separator: "\n")

                guard !texto.isEmpty || !recuperados.isEmpty else { return }
                mensajes.append(Message(id: "u\(mensajes.count)",
                                        kind: .user(texto, adjuntos: recuperados)))

            case .agente:
                let tools: ToolRun? = herramientas.isEmpty ? nil : ToolRun(herramientas: herramientas)
                // ⚠️ También al recargar, o un hilo viejo seguiría enseñando el JSON del
                // `eb-file` que en vivo ya sale como tarjeta. Aquí no se registra la
                // entrega —eso lo hizo el turno en su día—: sólo se saca del texto y se
                // pinta, que es lo que hace que el hilo se vea igual que cuando pasó.
                var limpio = limpio
                for hallado in BloqueEbFile.buscar(limpio, agentID: "", sesionID: nil).reversed() {
                    limpio.removeSubrange(hallado.rango)
                    entregasDelReplay.append((mensajes.count, hallado.entrega))
                }
                guard !limpio.isEmpty || tools != nil || !entregasDelReplay.isEmpty else { return }
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
                if separarTrasHerramienta, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    separarTrasHerramienta = false
                    while texto.hasSuffix("\n") { texto.removeLast() }
                    if !texto.isEmpty { texto += "\n\n" }
                }
                texto += t

            case .turno, .cerrado:
                // Frontera de mensaje/turno: cierra la burbuja aunque el rol se repita
                // (dos mensajes seguidos de la persona son dos burbujas).
                cerrar(); quien = nil

            case .thought:
                // El razonamiento del agente no va al hilo: es ruido para quien lee,
                // y en la caja son párrafos enteros por turno.
                break

            case .tool(let h):
                // Una herramienta pertenece al turno del agente aunque llegue antes
                // de que él escriba una palabra.
                if quien != .agente { cerrar(); quien = .agente }
                if !texto.isEmpty { separarTrasHerramienta = true }
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
        // Las tarjetas se cosen al final, de atrás hacia delante para no mover índices.
        for (donde, e) in entregasDelReplay.reversed() {
            let id = "entrega-\(e.id)"
            guard !mensajes.contains(where: { $0.id == id }) else { continue }
            let sitio = min(donde + 1, mensajes.count)
            mensajes.insert(Message(id: id, kind: .entrega(e)), at: sitio)
        }
        // Lo que el agente ENTREGÓ y gs guardó en los archivos de la cuenta. Es lo que
        // hace que una tarjeta vuelva en otro teléfono o tras reinstalar: el replay de la
        // caja no trae entregas. El replay tampoco trae fechas, así que van al final, en
        // el orden en que se guardaron; el mismo id que en vivo (`f-<fileId>`) evita la
        // doble tarjeta cuando el teléfono ya la tenía.
        let delServidor = archivos.values.filter { $0.origen == "agente" }
            .sorted { ($0.creado ?? .distantPast) < ($1.creado ?? .distantPast) }
        for f in delServidor {
            let id = "entrega-f-\(f.id)"
            guard !mensajes.contains(where: { $0.id == id }) else { continue }
            var e = Entrega.fromAccountFile(f)
            // El agente de la fila no viaja aquí: el hilo ya es de un agente concreto.
            e.agentID = ""
            mensajes.append(Message(id: id, kind: .entrega(e)))
        }
        return mensajes
    }
}
