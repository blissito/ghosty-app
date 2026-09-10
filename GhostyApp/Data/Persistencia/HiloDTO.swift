import Foundation

/// Cómo se ESCRIBE una conversación en el disco de este teléfono.
///
/// ⚠️ Son tipos aparte y no los modelos de pantalla porque los modelos de pantalla **no
/// son `Codable`**, y no es un descuido: `Herramienta` importa SwiftUI y expone colores
/// (`Herramienta.Clase.tinte`), así que hacerlo `Codable` ataría el formato del disco a
/// cómo se pinta hoy. El día que la burbuja cambie, lo guardado sigue leyéndose.
///
/// Lo que NO se guarda, a propósito:
/// - **Los bytes de un adjunto.** Se guarda su id en la cuenta y se baja cuando hace falta,
///   igual que ya hace `ReplayToMessages` con un hilo que vuelve de la caja. Guardar las
///   fotos otra vez sería duplicar en el teléfono lo que ya está en el almacenamiento.
/// - **`.typing`.** Son tres puntos de una respuesta que ya terminó.
/// - **`.prCard`.** Hoy sólo la emite el mock; si algún día la emite la caja, esta rama
///   avisa al compilador porque el `switch` de abajo es exhaustivo.
enum HiloDTO {}

struct AdjuntoGuardado: Codable {
    var id: String
    var nombre: String
    var mime: String
    var bytes: Int
    /// El id con el que se vuelve a bajar de la cuenta. Sin él, el adjunto sólo se puede
    /// nombrar.
    var remotoID: String?
    var segundos: Double?
    var onda: [Float]?
    var transcripcion: String?

    init(_ a: Adjunto) {
        id = a.id
        nombre = a.nombre
        mime = a.mime
        bytes = a.remoto?.bytes ?? a.datos.count
        remotoID = a.remoto?.id
        segundos = a.segundos
        onda = a.onda
        transcripcion = a.transcripcion
    }

    var adjunto: Adjunto {
        var a = Adjunto(id: id, nombre: nombre, mime: mime, datos: Data(),
                        segundos: segundos, onda: onda)
        a.transcripcion = transcripcion
        if let remotoID {
            a.remoto = GhostyAPI.ArchivoRemoto(id: remotoID, nombre: nombre, mime: mime,
                                               bytes: bytes, url: "")
        }
        return a
    }
}

struct HerramientaGuardada: Codable {
    var id: String
    var titulo: String
    var clase: String
    /// ⚠️ `Herramienta.Estado` no tiene `rawValue`, así que el nombre se pone AQUÍ. Y un
    /// estado desconocido cae en `.hecha`, no en `.corriendo`: un turno guardado ya
    /// terminó, y pintarle un spinner eterno a algo que acabó ayer sería mentir.
    var estado: String
    var salida: String?
    var donde: String?

    init(_ h: Herramienta) {
        id = h.id
        titulo = h.titulo
        clase = h.clase.rawValue
        estado = switch h.estado {
        case .corriendo: "corriendo"
        case .hecha:     "hecha"
        case .fallida:   "fallida"
        }
        salida = h.salida
        donde = h.donde
    }

    var herramienta: Herramienta {
        Herramienta(id: id, titulo: titulo, clase: Herramienta.Clase(clase),
                    estado: estado == "fallida" ? .fallida : .hecha,
                    salida: salida, donde: donde)
    }
}

struct MensajeGuardado: Codable {
    enum Quien: String, Codable { case usuario, agente, entrega }

    var id: String
    var quien: Quien
    var texto: String
    var adjuntos: [AdjuntoGuardado]
    var herramientas: [HerramientaGuardada]
    var trailing: String?
    var entrega: Entrega?

    /// `nil` para lo que no se guarda (los tres puntos, la tarjeta de PR).
    init?(_ m: Message) {
        id = m.id
        adjuntos = []
        herramientas = []
        switch m.kind {
        case .user(let t, let adj):
            quien = .usuario
            texto = t
            adjuntos = adj.map(AdjuntoGuardado.init)
        case .agent(let t, let tools, let cola):
            quien = .agente
            texto = t
            herramientas = (tools?.herramientas ?? []).map(HerramientaGuardada.init)
            trailing = cola
        case .entrega(let e):
            quien = .entrega
            texto = e.titulo
            entrega = e
        case .typing, .prCard:
            return nil
        }
    }

    var mensaje: Message? {
        switch quien {
        case .usuario:
            return Message(id: id, kind: .user(texto, adjuntos: adjuntos.map(\.adjunto)))
        case .agente:
            let run = herramientas.isEmpty
                ? nil
                : ToolRun(herramientas: herramientas.map(\.herramienta))
            return Message(id: id, kind: .agent(text: texto, tools: run, trailing: trailing))
        case .entrega:
            guard let entrega else { return nil }
            return Message(id: id, kind: .entrega(entrega))
        }
    }
}

/// Una fila del historial. `ACPClient.Session` tampoco es `Codable`: se arma a mano desde
/// el JSON de `session/list`.
struct SesionGuardada: Codable {
    var id: String
    var title: String
    var cwd: String
    var updatedAt: Date?
    var messageCount: Int?

    init(_ s: ACPClient.Session) {
        id = s.id; title = s.title; cwd = s.cwd
        updatedAt = s.updatedAt; messageCount = s.messageCount
    }

    var sesion: ACPClient.Session {
        ACPClient.Session(id: id, title: title, cwd: cwd,
                          updatedAt: updatedAt, messageCount: messageCount)
    }
}
