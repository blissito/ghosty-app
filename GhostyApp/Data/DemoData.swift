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
        ProcessInfo.processInfo.environment["GHOSTY_DEMO"] == "1"
    }

    static let cuentas: [AgentAccount] = [
        AgentAccount(id: "demo-1", token: "gat_demo1", name: "Ghosty", host: nil),
        AgentAccount(id: "demo-2", token: "gat_demo2", name: "Nube", host: nil),
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
                    + "botón de bajar aparece cuando toca.",
                tools: nil, trailing: nil)))
        }
        return m
    }

    /// Una imagen GRANDE de verdad, en disco, para comprobar que la burbuja la acota.
    /// Sin red: el simulador no siempre la tiene y una prueba que depende de internet no
    /// prueba nada.
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

    /// La conversación con una foto mandada y una entrega recibida.
    static func conFoto() -> [Message] {
        var foto = Adjunto(nombre: "bukowski.png", mime: "image/png", datos: png)
        foto.remoto = GhostyAPI.ArchivoRemoto(id: "demo-file", nombre: "bukowski.png",
                                              mime: "image/png", bytes: png.count, url: "")
        let entrega = Entrega(id: "demo-entrega", agentID: "demo-1", sesionID: "s-foto",
                              forma: .archivo, titulo: "recorte.png", recibida: Date(),
                              contenido: nil, datos: png)
        return [
            Message(id: "df1", kind: .user("solo me interesa la foto", adjuntos: [foto])),
            Message(id: "df2", kind: .agent(
                // La imagen va DENTRO de una lista a propósito: así se escribe cuando el
                // agente devuelve resultados, y es el caso que se salía de la pantalla.
                text: "Ya está, recortada. Te la entrego.\n\n"
                    + "1. **Gatito naranja** ![gatito](\(imagenGrande().absoluteString))\n",
                tools: nil, trailing: nil)),
            Message(id: "entrega-demo-entrega", kind: .entrega(entrega)),
        ]
    }

    static let sesiones: [ACPClient.Session] = [
        ACPClient.Session(id: "s-larga", title: "El informe", cwd: "/data/work",
                          updatedAt: Date(), messageCount: 24),
        ACPClient.Session(id: "s-vieja", title: "Cotización de marzo", cwd: "/data/work",
                          updatedAt: Date().addingTimeInterval(-86_400), messageCount: 6),
    ]
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
                  status: .idle(since: "listo"), engine: "Ghosty Studio")
        }
        selectedAgentID = DemoData.cuentas[0].id

        // Agente 1: tres conversaciones.
        let uno = Canal(cuenta: DemoData.cuentas[0])
        let larga = uno.abrir("s-larga"); larga.mensajes = DemoData.larga()
        let foto = uno.abrir("s-foto"); foto.mensajes = DemoData.conFoto()
        // Ésta espera permiso: es el estado que la app nunca llegaba a pintar.
        foto.permisoPendiente = PermissionRequest(
            id: "demo-permiso", kind: .publish, agentName: "Ghosty",
            question: "¿Dejas que publique el recorte?",
            detail: "El turno está detenido hasta que contestes.", attachment: nil)
        // Una que ya contestó y no has visto: es el estado que la lista no sabía decir.
        foto.termino = Date().addingTimeInterval(-120)
        foto.visto = false
        let vacia = uno.abrir()
        uno.activa = larga.clave
        larga.termino = Date().addingTimeInterval(-3600)
        // El orden de la barra es por ÚLTIMO MENSAJE ESCRITO, así que la demo lo fija a
        // mano en vez de dejarlo al orden de creación: si no, la conversación larga —la
        // que sirve para revisar el scroll— cae al final y las capturas no la enseñan.
        // Una que reventó: es el estado que la lista no sabía distinguir.
        larga.fallo = "Se cortó a media respuesta"
        larga.tocado = Date()
        foto.tocado = Date().addingTimeInterval(-120)
        vacia.tocado = Date().addingTimeInterval(-300)
        uno.hilosRemotos = DemoData.sesiones
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

        ponerCanalesDeDemo([DemoData.cuentas[0].id: uno, DemoData.cuentas[1].id: dos])
        conexion = .lista
    }
}
