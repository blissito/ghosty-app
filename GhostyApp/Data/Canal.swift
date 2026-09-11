import Foundation
import Observation

enum EstadoHilos: Equatable { case sinPedir, cargando, listo, fallo(String) }

/// UNA conversación viva: sus mensajes, su turno y su permiso.
///
/// ⚠️ Esto existía por AGENTE y estaba mal. Con un solo hilo por agente, abrir otra
/// conversación mientras una contestaba pisaba `mensajes` y `sesionID`, y el turno que
/// seguía corriendo escribía su respuesta **dentro del hilo recién abierto**: dos
/// conversaciones cosidas en pantalla. Y no se podía pedirle dos cosas a la vez al mismo
/// agente, que era justo lo que se buscaba.
///
/// El socket sigue siendo uno por agente (ver `Canal`): son hilos de una misma caja, no
/// cajas distintas. Lo que los separa es el `sessionId`, que el protocolo ya mandaba.
@Observable
@MainActor
final class Hilo {
    /// Identidad LOCAL y estable. Existe desde antes que la de la caja: un hilo nuevo
    /// tiene mensajes en pantalla mientras `session/new` está en vuelo, y sin esto no
    /// habría a qué colgarlos.
    let clave = UUID().uuidString
    /// La de la caja. `nil` = todavía no se ha creado allá.
    var sesionID: String?

    var mensajes: [Message] = []

    /// Pone un mensaje por su id: si ya está, lo sustituye en su sitio; si no, al final.
    /// Es la ÚNICA forma sana de añadir: dos mensajes con el mismo id dejan el `ForEach`
    /// en blanco con el hilo entero dentro.
    func poner(_ m: Message) {
        if let i = mensajes.firstIndex(where: { $0.id == m.id }) { mensajes[i] = m }
        else { mensajes.append(m) }
    }

    var turno: TurnActivity?
    var permisoACP: ACPClient.Permiso?
    var permisoPendiente: PermissionRequest?
    var modo = "auto"

    var enVuelo: Task<Void, Never>?
    var cronometro: Task<Void, Never>?
    var creando: Task<String, Error>?
    /// En qué conexión se rehidrató esta sesión por última vez.
    ///
    /// ⚠️ La caja **no conserva la sesión entre conexiones**: al reconectar, mandarle un
    /// turno con el `sessionId` viejo le llega a una sesión que para ella empieza en
    /// blanco, y el agente contesta "no tengo contexto previo, esta conversación empieza
    /// con tu mensaje". Hay que hacerle `session/load` una vez por socket.
    var cargadaEn: ObjectIdentifier?
    var prompt = ""
    /// ¿Se cayó el último envío ANTES de llegar al agente? Vive en el HILO: con dos
    /// envíos a la vez, un fallo global le devolvía los adjuntos a la conversación
    /// equivocada — o le borraba los suyos a la que sí salió.
    var envioFallo = false
    /// Viene de un caché anterior al ruteo por hilo y **puede estar cruzado**. Se pinta
    /// igual (no le quitamos nada a nadie sin red) pero se recarga en cuanto se pueda.
    var sospechoso = false
    var uso = (entrada: 0, salida: 0)
    var inicio: Date?

    var trabajando: Bool { turno != nil }
    /// ¿La caja no ha mandado ninguna herramienta en este turno? Entonces lo único que
    /// sabemos es cuánto lleva, y el estado lo pone el cronómetro.
    var sinHerramientas = true
    var transcurrido: String { turno?.elapsed ?? "" }

    /// Cuándo cerró su último turno, y si ya lo viste.
    ///
    /// ⚠️ «4 mensajes» no dice lo que uno quiere saber de una conversación que dejaste
    /// trabajando: quiere saber si YA CONTESTÓ. Con varias a la vez es la única forma de
    /// decidir a cuál volver.
    var termino: Date?
    var visto = true
    /// Por qué se rompió el último turno, si se rompió.
    ///
    /// ⚠️ Una conversación que reventó se veía en la lista igual que una que fue bien
    /// —«5 mensajes»— así que había que entrar a cada una para descubrir cuál había
    /// fallado. Y con varias a la vez, eso es justo lo que no puedes hacer.
    var fallo: String?
    /// El agente sigue con esto, pero ya no lo estamos oyendo: se cayó nuestra conexión,
    /// casi siempre porque el teléfono se durmió.
    ///
    /// ⚠️ No es un fallo y ya no hay nada que «recuperar»: el turno vive en el servidor.
    /// Se apaga solo en cuanto volvemos a escuchar.
    var interrumpido = false
    /// Estamos preguntando qué pasó mientras no mirábamos.
    var poniendoseAlDia = false
    /// Cuándo se le ESCRIBIÓ por última vez.
    ///
    /// ⚠️ Sólo al escribir, no al mirar. Es lo que ordena la barra de conversaciones, y
    /// reordenarla al tocar un chip movería las fichas debajo del dedo justo cuando estás
    /// eligiendo: miras para decidir, y lo que miras no debe cambiarse de sitio. Lo que
    /// revive una conversación es mandarle algo.
    var tocado = Date()

    /// En qué anda, en una línea, para una lista.
    enum Estado: Equatable {
        case trabajando(String), listo(String), fallo(String), sinEstrenar, enReposo(String)
        case interrumpido, alDia
    }

    var estado: Estado {
        if let turno { return .trabajando(turno.elapsed.isEmpty ? "…" : turno.elapsed) }
        // Gana sobre «contestó»: si el turno se rompió, eso es lo que hay que saber.
        if poniendoseAlDia { return .alDia }
        // ⚠️ Gana sobre «contestó». Un hilo cortado por la suspensión conserva su `termino`
        // de antes, y sin esta línea se pintaba «Contestó hace 2 min» cuando lo que había
        // era una respuesta a medias esperando a que la recogiéramos.
        if interrumpido { return .interrumpido }
        if let fallo { return .fallo(fallo) }
        if let termino, !visto { return .listo(Self.hace(termino)) }
        if mensajes.isEmpty { return .sinEstrenar }
        let n = mensajes.count
        return .enReposo(n == 1 ? "1 mensaje" : "\(n) mensajes")
    }

    /// «hace 2 min», en español y sin depender del idioma del teléfono para la forma.
    static func hace(_ fecha: Date) -> String {
        let s = Int(Date().timeIntervalSince(fecha))
        if s < 10 { return "ahora mismo" }
        if s < 60 { return "hace \(s) s" }
        if s < 3600 { return "hace \(s / 60) min" }
        if s < 86_400 { return "hace \(s / 3600) h" }
        return "hace \(s / 86_400) d"
    }

    /// De qué va, para poder nombrarlo en una lista.
    /// De qué va la conversación: su PRIMER mensaje.
    ///
    /// ⚠️ Miraba `prompt` primero, y `prompt` es lo ÚLTIMO que escribiste: el título del
    /// chip cambiaba con cada mensaje, así que una conversación que empezó con «ejecuta
    /// echo hola» aparecía en la barra como «busca sonidos de comic». Una conversación se
    /// llama por donde empezó, no por lo último que dijiste — es lo que hacen todos.
    var titulo: String {
        for m in mensajes { if case .user(let t, _) = m.kind, !t.isEmpty { return Self.limpio(t) } }
        // Sólo mientras el mensaje va en camino y todavía no está en la lista.
        if !prompt.isEmpty { return Self.limpio(prompt) }
        return "Conversación nueva"
    }

    /// El título es texto PLANO: los backticks y asteriscos de lo que escribiste salían
    /// literales («Ejecuta el comando \`echo»).
    private static func limpio(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        for marca in ["**", "__", "`", "#"] { s = s.replacingOccurrences(of: marca, with: "") }
        return String(s.trimmingCharacters(in: .whitespaces).prefix(40))
    }

    func soltar() {
        enVuelo?.cancel(); enVuelo = nil
        cronometro?.cancel(); cronometro = nil
        creando = nil
        turno = nil
    }
}

/// Un AGENTE conectado: su socket y las conversaciones que tienes abiertas con él.
///
/// El socket es uno solo a propósito. Uno por hilo multiplicaría las conexiones a la
/// caja por cada conversación abierta y hay un límite; el protocolo ya sabe repartir por
/// `sessionId`, así que no hace falta.
@Observable
@MainActor
final class Canal {
    let cuenta: AgentAccount

    init(cuenta: AgentAccount) { self.cuenta = cuenta }

    /// Las conversaciones abiertas, la más reciente al final.
    var hilos: [Hilo] = []
    /// Cuál se está mirando (su `clave`).
    var activa: String?

    var hilosRemotos: [ACPClient.Session] = []
    var estadoHilos: EstadoHilos = .sinPedir
    var infoDeLaCaja: String?
    /// ¿Se está despertando la caja ahora mismo? Sin esto la app se siente colgada:
    /// levantar una caja dormida tarda segundos y no había nada que lo dijera.
    var despertando = false

    /// Por dónde se habla con este agente. Puede ser el WebSocket a la caja o gs; el
    /// store no distingue, y ésa es la idea. Ver `TransporteDeAgente`.
    var acp: (any TransporteDeAgente)?
    /// La apertura de socket en vuelo, COMPARTIDA. Sin esto, dos conversaciones
    /// arrancando a la vez abrían dos sockets contra la misma caja.
    var abriendoSocket: Task<any TransporteDeAgente, Error>?
    /// Cronómetro heredado; el de verdad vive en cada `Hilo`.
    var cronometro: Task<Void, Never>?

    /// La conversación que se mira.
    ///
    /// ⚠️ Si `activa` apunta a una que ya no está, **cae en la última en vez de en nada**.
    /// Devolver `nil` parecía más honesto y era peor: quien preguntaba acababa abriendo
    /// una conversación NUEVA, así que salir a otra pestaña y volver te dejaba con el hilo
    /// en blanco en lugar del que habías cargado.
    var hilo: Hilo? {
        if let activa, let h = hilos.first(where: { $0.clave == activa }) { return h }
        return hilos.last
    }

    /// Cuántas conversaciones se guardan en memoria. Abiertas cuestan poco, pero no
    /// tiene sentido arrastrar veinte: se cierra la más vieja que no esté trabajando ni
    /// esperándote.
    private static let topeAbiertas = 8

    func podar() {
        guard hilos.count > Self.topeAbiertas else { return }
        while hilos.count > Self.topeAbiertas,
              let sobra = hilos.first(where: {
                  !$0.trabajando && $0.permisoPendiente == nil && $0.clave != activa
              }) {
            cerrar(sobra)
        }
    }

    func hilo(sesion: String) -> Hilo? { hilos.first { $0.sesionID == sesion } }

    /// Uno nuevo, vacío, y pasa a ser el que se mira.
    /// Las conversaciones por uso reciente. La lista y la barra las pintan así.
    var recientes: [Hilo] { hilos.sorted { $0.tocado > $1.tocado } }

    @discardableResult
    func abrir(_ sesionID: String? = nil) -> Hilo {
        // Traer a la vista una que ya está abierta NO la reordena: eso sólo lo hace
        // escribirle. Ver el aviso de `Hilo.tocado`.
        if let sesionID, let ya = hilo(sesion: sesionID) { activa = ya.clave; return ya }
        let h = Hilo()
        h.sesionID = sesionID
        hilos.append(h)
        activa = h.clave
        return h
    }

    func cerrar(_ h: Hilo) {
        h.soltar()
        hilos.removeAll { $0.clave == h.clave }
        if activa == h.clave { activa = hilos.last?.clave }
    }

    /// Los que están contestando ahora mismo.
    var enCurso: [Hilo] { hilos.filter(\.trabajando) }
    var trabajando: Bool { !enCurso.isEmpty }
    /// Los que te están esperando a ti.
    var esperandoPermiso: [Hilo] { hilos.filter { $0.permisoPendiente != nil } }

    func soltar() {
        for h in hilos { h.soltar() }
        hilos = []
        activa = nil
        let cliente = acp
        acp = nil
        Task { await cliente?.cerrar() }
    }
}
