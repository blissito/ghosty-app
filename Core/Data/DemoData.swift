import Foundation
import UIKit

/// La app llena de datos falsos, **sin red y sin sesión**.
///
/// ⚠️ Esto existe por una razón concreta y vergonzosa: se enviaron cinco builds seguidas
/// con fallos de interacción —filas que no responden al toque, un botón que no hacía nada,
/// una conversación duplicada— porque lo único que se verificaba era que el compilador
/// estuviera contento. Sin sesión la app se queda en el login, así que no había forma de
/// abrirla en el simulador y tocarla.
///
/// ⚠️ Y llena el store REAL, no un mock. Lo que hay que probar es `Canal`, `Hilo`, la
/// fachada y el caché, que es justo donde han estado los fallos; un store de mentira
/// probaría otro código.
///
/// Se enciende con `GHOSTY_DEMO=1` (en el simulador: `SIMCTL_CHILD_GHOSTY_DEMO=1`).
enum DemoData {
    static var encendido: Bool {
        Gancho.valor("GHOSTY_DEMO") == "1"
    }

    static let cuentas: [AgentAccount] = [
        AgentAccount(id: "demo-1", token: "gat_demo1", name: "Ghosty", host: nil, motor: "ghosty-lite", space: .personal, model: "DeepSeek Flash"),
        // De un workspace: es lo que hace que la lista enseñe secciones en el recorrido.
        AgentAccount(id: "demo-2", token: "gat_demo2", name: "Nube", host: nil, motor: "goose",
                     space: AgentSpace(kind: .workspace, id: "ws-demo", name: "business", combo: "teams")),
    ]

    /// Un PNG de 8×8 de verdad, para que la burbuja tenga una imagen que pintar.
    static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP4z8CAFWEXHbQSACj/P8Fu7N9hAAAAAElFTkSuQmCC")!

    /// La conversación larga: sirve para el scroll y para el botón de ir abajo.
    static func larga() -> [Message] {
        var m: [Message] = []
        for i in 1...12 {
            m.append(Message(id: "du\(i)", kind: .user("Pregunta número \(i) sobre el informe")))
            m.append(Message(id: "da\(i)", kind: .agent(
                text: "Respuesta \(i). Esto es un párrafo con **markdown**, suficientemente "
                    + "largo como para que el hilo tenga que desplazarse y se pueda ver si el "
                    + "botón de bajar aparece cuando toca."
                    // La última lleva citas, para que la barra de fuentes se vea en las
                    // capturas: sin un mensaje con enlaces no había nada que verificar.
                    + (i == 12 ? " Según [Causo](https://causo.io/informe) y "
                               + "[Enginy](https://enginy.com/precios)." : ""),
                tools: nil, trailing: nil)))
        }
        return m
    }

    /// Una imagen GRANDE de verdad, en disco, para comprobar que la burbuja la acota.
    /// Sin red: el simulador no siempre la tiene y una prueba que depende de internet no
    /// prueba nada.
    /// Un segundo de tono a 440 Hz en WAV, para que la nota de voz de la demo suene de
    /// verdad al tocar play.
    static func audioDemo() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "voz-demo.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            let sr = 8000, n = sr * 4
            var pcm = [Int16](repeating: 0, count: n)
            for i in 0..<n { pcm[i] = Int16(sin(Double(i) * 2 * .pi * 440 / Double(sr)) * 8000) }
            var d = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVE".utf8))
            d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
            d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
            pcm.withUnsafeBytes { d.append(contentsOf: $0) }
            try? d.write(to: url)
        }
        return url
    }

    static func imagenGrande() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "grande.png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let tamano = CGSize(width: 2000, height: 1200)
            let img = UIGraphicsImageRenderer(size: tamano).image { ctx in
                UIColor.systemTeal.setFill()
                ctx.fill(CGRect(origin: .zero, size: tamano))
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 100, y: 100, width: 400, height: 400))
            }
            try? img.pngData()?.write(to: url)
        }
        return url
    }

    /// Las entregas de la demo, para que Artefactos tenga qué enseñar y qué filtrar.
    static func conFotoEntregas() -> [Entrega] {
        let mp3 = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A]
                       + [UInt8](repeating: 0, count: 200))
        return [
            Entrega(id: "demo-entrega", agentID: "demo-1", sesionID: "s-foto", forma: .archivo,
                    titulo: "recorte.png", recibida: Date(), contenido: nil, datos: png),
            Entrega(id: "demo-audio", agentID: "demo-1", sesionID: "s-foto", forma: .archivo,
                    titulo: "SFX cómic 08", recibida: Date(), contenido: nil, datos: mp3),
            Entrega(id: "demo-doc", agentID: "demo-1", sesionID: "s-foto", forma: .doc,
                    titulo: "Resumen del trimestre", recibida: Date(),
                    contenido: "# Resumen", datos: nil),
        ]
    }

    /// La conversación con una foto mandada y una entrega recibida.
    static func conFoto() -> [Message] {
        var foto = Adjunto(nombre: "bukowski.png", mime: "image/png", datos: png)
        foto.remoto = GhostyAPI.ArchivoRemoto(id: "demo-file", nombre: "bukowski.png",
                                              mime: "image/png", bytes: png.count, url: "")
        // Un MP3 mínimo pero REAL: empieza por `ID3`, que es justo el caso que se
        // guardaba como `.txt` y salía como un muro de basura en el visor del sistema.
        let mp3 = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A]
                       + [UInt8](repeating: 0, count: 200))
        let sonido = Entrega(id: "demo-audio", agentID: "demo-1", sesionID: "s-foto",
                             forma: .archivo, titulo: "SFX cómic 08", recibida: Date(),
                             contenido: nil, datos: mp3)
        let doc = Entrega(id: "demo-doc", agentID: "demo-1", sesionID: "s-foto",
                          forma: .doc, titulo: "Resumen del trimestre", recibida: Date(),
                          contenido: "# Resumen\n\nTres cosas.", datos: nil)
        let entrega = Entrega(id: "demo-entrega", agentID: "demo-1", sesionID: "s-foto",
                              forma: .archivo, titulo: "recorte.png", recibida: Date(),
                              contenido: nil, datos: png)
        // El texto pasa por el MISMO puente que en vivo, o la demo probaría otra cosa.
        let crudo = "Ya está, recortada. Te la entrego.\n\n"
            // La nota de voz TAL CUAL la imprime `voice.speak` del SDK: sólo URL, sin bytes.
            // Va ANTES del archivo a propósito: ése es el orden que se saltaba el parser.
            + "```eb-audio\n{\"url\":\"\(audioDemo().absoluteString)\",\"waveform\":\"\",\"durationMs\":4000,\"mime\":\"audio/wav\"}\n```\n\n"
            + "```eb-file\n{\"url\":\"\(imagenGrande().absoluteString)\","
            + "\"name\":\"cotizacion.png\",\"size\":48213}\n```\n\n"
            + "1. **Gatito naranja** ![gatito](\(imagenGrande().absoluteString))\n"
        var visible = crudo
        var deEbFile: [Message] = []
        for h in BloqueEbFile.buscar(crudo, agentID: "demo-1", sesionID: "s-foto").reversed() {
            visible.removeSubrange(h.rango)
            deEbFile.append(Message(id: "entrega-\(h.entrega.id)", kind: .entrega(h.entrega)))
        }

        return [
            Message(id: "df1", kind: .user("solo me interesa la foto", adjuntos: [foto])),
            Message(id: "df2", kind: .agent(text: visible, tools: nil, trailing: nil)),
        ] + deEbFile + [
            Message(id: "entrega-demo-entrega", kind: .entrega(entrega)),
            Message(id: "entrega-demo-audio", kind: .entrega(sonido)),
            Message(id: "entrega-demo-doc", kind: .entrega(doc)),
        ]
    }

    static let sesiones: [ACPClient.Session] = [
        ACPClient.Session(id: "s-larga", title: "El informe", cwd: "/data/work",
                          updatedAt: Date(), messageCount: 24),
        ACPClient.Session(id: "s-vieja", title: "Cotización de marzo", cwd: "/data/work",
                          updatedAt: Date().addingTimeInterval(-86_400), messageCount: 6),
    ]

    /// Lo que el agente hace desde OTRO lado: la Mac o la web. gs lo reporta en la lista
    /// y esta app no lo está oyendo — es justo el estado que la lista no sabía pintar.
    ///
    /// Va aparte de `sesiones` a propósito: ésa la comparten los dos canales y meterle
    /// turnos vivos cambiaría capturas que ya son contrato.
    static var sesionesRemotas: [ACPClient.Session] {
        func turno(_ id: String, _ estado: String, inicio: TimeInterval, fin: TimeInterval? = nil)
            -> ACPClient.UltimoTurno {
            ACPClient.UltimoTurno(turnId: id, estado: estado, error: nil,
                                  terminado: fin.map { Date().addingTimeInterval($0) },
                                  iniciado: Date().addingTimeInterval(inicio))
        }
        return [
            // Corriendo de verdad: enciende «Trabajando en otra conversación…».
            ACPClient.Session(id: "s-remota", title: "Migración de la base", cwd: "/data/work",
                              updatedAt: Date(), messageCount: 3,
                              ultimoTurno: turno("tr1", "running", inicio: -90)),
            // Zombi: el servidor lleva tres horas diciendo «running». La caducidad tiene
            // que apagarlo, o la lista miente toda la tarde.
            ACPClient.Session(id: "s-zombi", title: "Turno mudo", cwd: "/data/work",
                              updatedAt: Date().addingTimeInterval(-10_800), messageCount: 2,
                              ultimoTurno: turno("tr2", "running", inicio: -10_800)),
            // Pidió permiso desde otro lado: está DETENIDA esperándote y la lista tiene
            // que decirlo sin que abras el hilo.
            ACPClient.Session(id: "s-permiso-fuera", title: "Publicar el recorte",
                              cwd: "/data/work", updatedAt: Date(), messageCount: 4,
                              ultimoTurno: turno("tr4", "running", inicio: -240),
                              permisoPendiente: "Publicar en el sitio"),
            // Contestó desde otro lado y nunca la abriste aquí: enciende el punto.
            ACPClient.Session(id: "s-contesto-fuera", title: "Cotización de abril",
                              cwd: "/data/work", updatedAt: Date().addingTimeInterval(-300),
                              messageCount: 8,
                              ultimoTurno: turno("tr3", "done", inicio: -600, fin: -300)),
        ]
    }
}

extension LiveAgentStore {
    /// Monta la demo. Cubre a propósito lo que se ha roto: varias conversaciones del mismo
    /// agente, una con turno vivo, un permiso esperando, una guardada que TAMBIÉN está
    /// abierta (para ver que no salga dos veces) y un hilo largo.
    func cargarDemo() {
        correo = "demo@ghosty.studio"
        ponerCuentasDeDemo(DemoData.cuentas)

        let tonos: [AgentTone] = [.lila, .azul]
        agents = DemoData.cuentas.enumerated().map { i, c in
            Agent(id: c.id, name: c.name, tone: tonos[i % tonos.count],
                  status: .idle(since: "listo"), engine: c.motor ?? "Ghosty Studio", space: c.space, model: c.model)
        }
        selectedAgentID = DemoData.cuentas[0].id

        // Agente 1: tres conversaciones.
        let uno = Canal(cuenta: DemoData.cuentas[0])
        let larga = uno.abrir("s-larga"); larga.mensajes = DemoData.larga()
        let foto = uno.abrir("s-foto"); foto.mensajes = DemoData.conFoto()
        // Ésta espera permiso: es el estado que la app nunca llegaba a pintar.
        foto.permisoPendiente = PermissionRequest(
            id: "demo-permiso", kind: .email, agentName: "Ghosty",
            question: "¿Le mando el correo a Laura?",
            detail: "Eso ya no se puede deshacer, por eso te pregunto. Me espero a que me digas.", attachment: nil)
        // Una que ya contestó y no has visto: es el estado que la lista no sabía decir.
        foto.termino = Date().addingTimeInterval(-120)
        foto.visto = false
        let vacia = uno.abrir()
        uno.activa = larga.clave
        // Gancho para poder fotografiar la conversación con entregas sin tocar la pantalla.
        if Gancho.valor("GHOSTY_DEMO_ENTREGAS") == "1" {
            uno.activa = foto.clave
        }
        larga.termino = Date().addingTimeInterval(-3600)
        // El orden de la barra es por ÚLTIMO MENSAJE ESCRITO, así que la demo lo fija a
        // mano en vez de dejarlo al orden de creación: si no, la conversación larga —la
        // que sirve para revisar el scroll— cae al final y las capturas no la enseñan.
        // Una que reventó: es el estado que la lista no sabía distinguir.
        larga.fallo = "Se cortó a media respuesta"
        // Y `GHOSTY_DEMO_TRABAJANDO=1` deja el hilo activo contestando, que es la única
        // forma de fotografiar el botón de detener del compositor.
        if Gancho.valor("GHOSTY_DEMO_TRABAJANDO") == "1" {
            larga.fallo = nil
            larga.turno = TurnActivity(id: "t2", title: "el informe", detail: "Leyendo",
                                       step: 1, totalSteps: 4, elapsed: "0:12")
            larga.anclaArriba = larga.mensajes.last(where: \.esDeUsuario)?.id
        }
        // `GHOSTY_DEMO_HERRAMIENTAS=1`: el turno SIGUE pero ninguna herramienta corre
        // ahora mismo —el modelo está pensando la siguiente—. Es el hueco donde antes no
        // quedaba ningún indicador de carga, y donde más se tarda.
        if Gancho.valor("GHOSTY_DEMO_HERRAMIENTAS") == "1" {
            larga.fallo = nil
            larga.turno = TurnActivity(id: "t3", title: "el informe", detail: "Pensando",
                                       step: 2, totalSteps: 4, elapsed: "1:08")
            larga.anclaArriba = larga.mensajes.last(where: \.esDeUsuario)?.id
            larga.mensajes.append(Message(id: "da-tools", kind: .agent(
                text: "", tools: ToolRun(herramientas: [
                    Herramienta(id: "h1", titulo: "Buscar en la web", clase: .search,
                                estado: .hecha, salida: "3 resultados", donde: nil,
                                detalle: "conectores populares"),
                ]), trailing: nil)))
        }
        // `GHOSTY_DEMO_STEER=acp|nativo`: si este agente acepta que le mandes algo MÁS
        // mientras trabaja (acp) o si mandarlo le corta el trabajo (nativo).
        if let modo = Gancho.valor("GHOSTY_DEMO_STEER") {
            uno.puedeSteer = modo == "acp"
            larga.fallo = nil
            if larga.turno == nil {
                larga.turno = TurnActivity(id: "t4", title: "el informe", detail: "Leyendo",
                                           step: 1, totalSteps: 4, elapsed: "0:20")
            }
        }
        // `GHOSTY_DEMO_INTERRUMPIDO=1`: el hilo que dejaste trabajando y iOS suspendió.
        // Es el estado que hay que poder MIRAR — el cartel de «sigue con esto» y la fila
        // gris de la lista— sin tener que bloquear un teléfono de verdad.
        if Gancho.valor("GHOSTY_DEMO_INTERRUMPIDO") == "1" {
            larga.fallo = nil
            larga.turno = nil
            larga.interrumpido = true
        }
        larga.tocado = Date()
        foto.tocado = Date().addingTimeInterval(-120)
        vacia.tocado = Date().addingTimeInterval(-300)
        uno.hilosRemotos = DemoData.sesiones
        // `GHOSTY_DEMO_REMOTO=1`: el agente trabajando desde la Mac. Es lo único que deja
        // MIRAR ese estado sin tener dos aparatos delante.
        if Gancho.valor("GHOSTY_DEMO_REMOTO") == "1" {
            larga.fallo = nil
            // ⚠️ Sin el permiso: «espera tu visto bueno» GANA sobre cualquier trabajo, y
            // con razón —está detenido esperándote—, pero entonces tapa justo el estado
            // que este gancho existe para poder mirar.
            foto.permisoPendiente = nil
            uno.hilosRemotos = DemoData.sesiones + DemoData.sesionesRemotas
            for s in DemoData.sesionesRemotas { marcarSinVerRemota(s, agente: uno.cuenta.id) }
        }
        uno.estadoHilos = .listo
        uno.infoDeLaCaja = "demo 1.0"

        // Agente 2: contestando ahora mismo, para que salgan los chips y el punto.
        let dos = Canal(cuenta: DemoData.cuentas[1])
        let vivo = dos.abrir("s-vivo")
        vivo.mensajes = [Message(id: "dv1", kind: .user("resume el trimestre"))]
        vivo.prompt = "resume el trimestre"
        vivo.turno = TurnActivity(id: "t", title: "resume el trimestre",
                                  detail: "Leyendo el CSV", step: 1, totalSteps: 3,
                                  elapsed: "0:42")
        let dormida = dos.abrir("s-vieja-2")
        dormida.mensajes = [Message(id: "dd1", kind: .user("cotización de abril")),
                            Message(id: "dd2", kind: .agent(text: "Ahí va.", tools: nil, trailing: nil))]
        dormida.termino = Date().addingTimeInterval(-7200)
        dos.activa = vivo.clave
        dos.hilosRemotos = DemoData.sesiones
        dos.estadoHilos = .listo

        // Artefactos lee del almacén, no del hilo: sin esto la pestaña sale vacía.
        for e in [DemoData.conFotoEntregas()].flatMap({ $0 }) { entregas.registrar(e) }
        ponerCanalesDeDemo([DemoData.cuentas[0].id: uno, DemoData.cuentas[1].id: dos])
        conexion = .lista
        aplicarAvisoPendiente()
    }
}
