import Foundation
// SwiftUI sólo por `withAnimation`: la entrega se inserta animada y la transacción
// tiene que envolver al append (ver el comentario de abajo).
import SwiftUI
import Observation

/// El store real: habla con las cajas de EasyBits. Implementa el mismo protocolo que
/// el mock, así que las vistas no cambian al pasar de uno a otro.
@Observable
@MainActor
final class LiveAgentStore: AgentStoring {

    var agents: [Agent] = []
    var selectedAgentID: Agent.ID = ""
    var log: [LogEntry] = []
    var permissionHistory: [PermissionRecord] = []
    var artifacts: [Artifact] = []
    var deliveredToday: [Artifact] = []

    enum Conexion: Equatable {
        case cargando, lista, sinLlave
        case fallo(String)
    }
    var conexion: Conexion = .cargando
    var ultimoUso: (entrada: Int, salida: Int)?

    /// Un canal por agente: su socket, su hilo y su turno. Cambiar de agente cambia
    /// de canal, no cancela nada. Ver `Canal.swift`.
    private(set) var canales: [String: Canal] = [:]

    /// Puertas para el modo demo. `cuentas` y `canales` son privados a propósito —nadie de
    /// fuera debe montarlos— y la demo vive en otro archivo.
    func ponerCanalesDeDemo(_ nuevos: [String: Canal]) { canales = nuevos }
    func ponerCuentasDeDemo(_ nuevas: [AgentAccount]) { cuentas = nuevas }
    private var cuentas: [AgentAccount] = []

    var canalActivo: Canal? { canales[selectedAgentID] }
    /// La conversación que se está mirando.
    var hiloActivo: Hilo? { canalActivo?.hilo }

    /// Todas las conversaciones que están contestando o esperándote, de todos los agentes.
    /// Es lo que pinta la fila de chips y lo que decide el punto de la pestaña.
    var enCurso: [(canal: Canal, hilo: Hilo)] {
        agents.compactMap { canales[$0.id] }.flatMap { c in
            c.hilos.filter { $0.trabajando || $0.permisoPendiente != nil }.map { (c, $0) }
        }
    }

    /// Agentes con algo que no has visto: terminaron o piden permiso mientras mirabas
    /// otra cosa. Es lo que enciende el punto de la pestaña Flota.
    private(set) var sinVer: Set<String> = []

    var hayPendientes: Bool { !sinVer.isEmpty }

    /// Pedirle al chat que abra el teclado al llegar. Lo enciende quien te manda allí
    /// —el botón de nueva conversación— y lo apaga el chat al obedecer.
    var pedirTeclado = false

    func visto(_ id: String) { sinVer.remove(id) }
    func vistoTodo() { sinVer.removeAll() }

    /// Los que están trabajando ahora mismo, en el orden de la flota. Es lo que pinta
    /// la barra de "trabajando en segundo plano".
    var trabajando: [Canal] { agents.compactMap { canales[$0.id] }.filter(\.trabajando) }

    /// Cuántos turnos puede tener UN agente a la vez.
    ///
    /// ⚠️ Es un tope NUESTRO, no uno que diga la caja: no hay número documentado, y
    /// preferimos decirlo nosotros a que la caja falle de una forma que no sabemos leer.
    /// Tres es también el techo humano: más de tres cosas a la vez no las sigues en una
    /// pantalla de teléfono.
    static let topeDeTurnos = 3

    // MARK: - Fachada del canal activo
    //
    // Las vistas siguen hablando de "la conversación" y "el turno" en singular: lo que
    // cambió es que ahora eso es SIEMPRE el canal seleccionado, no un estado global.

    var messages: [Message] {
        get { hiloActivo?.mensajes ?? [] }
        set { hiloActivo?.mensajes = newValue }
    }
    var currentTurn: TurnActivity? {
        get { hiloActivo?.turno }
        set { hiloActivo?.turno = newValue }
    }
    /// El permiso que hay que contestar. Si el que miras no tiene, se enseña el de
    /// CUALQUIER hilo de este agente: un turno detenido esperándote no puede quedar
    /// escondido detrás de la conversación que resulte estar abierta.
    var pendingPermission: PermissionRequest? {
        get { hiloActivo?.permisoPendiente ?? canalActivo?.esperandoPermiso.first?.permisoPendiente }
        set { hiloActivo?.permisoPendiente = newValue }
    }
    var hilosRemotos: [ACPClient.Session] {
        get { canalActivo?.hilosRemotos ?? [] }
        set { canalActivo?.hilosRemotos = newValue }
    }
    var estadoHilos: EstadoHilos {
        get { canalActivo?.estadoHilos ?? .sinPedir }
        set { canalActivo?.estadoHilos = newValue }
    }
    var infoDeLaCaja: String? { canalActivo?.infoDeLaCaja }
    var hiloAbierto: String? { hiloActivo?.sesionID }
    var despertando: Bool { canalActivo?.despertando ?? false }
    /// La identidad de la conversación que se mira. La usa la vista para saber cuándo
    /// tiene que volver a poner el ojo abajo. ⚠️ Es la LOCAL: dos conversaciones nuevas
    /// del mismo agente no tienen `sesionID` todavía y serían indistinguibles.
    var claveDelHilo: String { hiloActivo?.clave ?? "" }
    let bitacora = TurnLogStore()
    /// Las conversaciones guardadas en el teléfono. Ver `CacheDeHilos.swift`.
    /// El único store de la app.
    ///
    /// ⚠️ Existe porque un push llega al **delegado**, que no tiene vista ni entorno de
    /// SwiftUI: sin un punto de entrada como éste, despertar en el fondo para recoger una
    /// respuesta no tiene a quién pedírselo. Nace aquí y `RootView` usa ÉSTE, no otro.
    static let compartido = LiveAgentStore()

    let cache = CacheDeHilos()
    /// Lo que el agente ha entregado por este teléfono. Ver `Entregas.swift`.
    let entregas = EntregasStore()

    /// ¿Se cayó el último envío ANTES de llegar al agente?
    ///
    /// Sólo lo enciende un fallo de subida, no un turno que reventó a medias: el
    /// compositor lo usa para devolverle sus adjuntos a la persona, y devolvérselos
    /// después de que el agente ya los recibió sería duplicarlos.
    /// ⚠️ Ahora sale del HILO. Global, con dos envíos a la vez, el fallo de uno le
    /// devolvía los adjuntos a la conversación equivocada — o le borraba los suyos a la
    /// que sí salió.
    var ultimoEnvioFallo: Bool { hiloActivo?.envioFallo ?? false }

    /// Lo que dijo el servidor si un adjunto no se pudo subir. El compositor lo enseña.
    var falloDeSubida: String?

    /// Cuánto almacenamiento lleva usado la cuenta. Lo dice el SERVIDOR.
    private(set) var almacenamiento: GhostyAPI.Almacenamiento?

    /// Las integraciones de la cuenta. Vacío = no hay ninguna; `hayConectores` false =
    /// el servidor todavía no lo soporta, y entonces la entrada NO se enseña.
    private(set) var conectores: [Conector] = []
    private(set) var hayConectores = false

    /// Lo que existe hoy en el registry de Teams. Se enseña DESACTIVADO mientras el
    /// servidor no lo sirva: la lista se irá completando conforme cada uno se active desde
    /// el teléfono, y verla es más útil que una pantalla vacía.
    ///
    /// ⚠️ Es un respaldo para pintar, NO una promesa de que funcionan: cada fila dice "muy
    /// pronto" y no se puede tocar. En cuanto el servidor conteste, manda él.
    private static let catalogo: [Conector] = [
        // Las de casa primero: son las que de verdad vamos a activar antes, y las que
        // reconoces por su marca sin leer el nombre.
        Conector(id: "easybits", nombre: "EasyBits", conectado: false, disponible: false),
        Conector(id: "denik", nombre: "Deník", conectado: false, disponible: false),
        Conector(id: "mailmask", nombre: "Mailmask", conectado: false, disponible: false),
        Conector(id: "github", nombre: "GitHub", conectado: false, disponible: false),
        Conector(id: "google", nombre: "Gmail", conectado: false, disponible: false),
        Conector(id: "google-calendar", nombre: "Google Calendar", conectado: false, disponible: false),
        Conector(id: "google-drive", nombre: "Google Drive", conectado: false, disponible: false),
        Conector(id: "calendly", nombre: "Calendly", conectado: false, disponible: false),
        Conector(id: "spotify", nombre: "Spotify", conectado: false, disponible: false),
        Conector(id: "canva", nombre: "Canva", conectado: false, disponible: false),
        Conector(id: "odoo", nombre: "Odoo", conectado: false, disponible: false),
        Conector(id: "kommo", nombre: "Kommo", conectado: false, disponible: false),
    ]

    /// Lo último que falló al hablar de integraciones. La pantalla lo pinta y lo limpia.
    private(set) var falloDeConectores: String?

    func cargarConectores() async {
        guard !DemoData.encendido else { conectores = Self.catalogo; hayConectores = false; return }
        switch await GhostyAPI.conectores() {
        case .servidos(let lista):
            conectores = lista
            hayConectores = true
            falloDeConectores = nil
        case .sinSoporte:
            conectores = Self.catalogo
            hayConectores = false
            falloDeConectores = nil
        case .fallo(let motivo):
            // ⚠️ Se CONSERVA lo que ya se había cargado. Pisarlo con el catálogo apagado
            // haría que un error de red se viera como si los conectores se hubieran
            // desconectado solos — y eso manda a la persona a reconectar algo que estaba
            // perfectamente conectado.
            if conectores.isEmpty { conectores = Self.catalogo }
            falloDeConectores = motivo
        }
    }

    func urlDeConexion(_ id: String) async -> URL? { await GhostyAPI.urlDeConexion(id) }

    func desconectar(_ id: String) async {
        let r = await GhostyAPI.desconectar(id)
        guard r.ok else {
            falloDeConectores = "No pude desconectarlo. Inténtalo de nuevo."
            return
        }
        falloDeConectores = r.aviso
        await cargarConectores()
    }

    /// Tras conectar hay que soltar la conversación viva.
    ///
    /// ⚠️ No es cosmético: una sesión ACP **congela su catálogo de herramientas al nacer**
    /// —el MCP pide `tools/list` una sola vez, al arrancar— así que la conversación que ya
    /// existía seguiría sin las tools nuevas por mucho que la caja se haya reiniciado. Y el
    /// modo en que eso se manifiesta es el peor: el agente no dice "no tengo permiso", dice
    /// que la integración no está activa y manda a la persona a arreglar lo que ya está bien.
    func reiniciarSesionTrasConectar() async {
        nuevaConversacion()
        await cargarConectores()
    }

    func cargarAlmacenamiento() async {
        guard !DemoData.encendido else { return }
        almacenamiento = try? await GhostyAPI.almacenamiento()
    }
    let titulos = TitleStore()

    /// Archivos y documentos de la cuenta. ⚠️ NO son del agente: el modelo `File` de
    /// EasyBits no tiene `agentId` y los artefactos se atribuyen al dueño, así que
    /// filtrar por agente sería inventar. La pantalla lo dice.
    var archivos: [EasyBitsClient.RemoteFile] = []
    var documentos: [EasyBitsClient.RemoteDocument] = []
    enum EstadoArchivos: Equatable { case sinPedir, cargando, listo, noPermitido, fallo(String) }
    var estadoArchivos: EstadoArchivos = .sinPedir

    /// Los hilos que viven EN LA CAJA, no en este teléfono. Vienen por WebSocket
    /// (`session/list`), así que sobreviven a reinstalar la app y los comparten
    /// todos los clientes del agente.
    /// Qué transporte llevó el último turno, para poder decirlo en pantalla.
    var porSocket = false

    // MARK: - Carga

    /// El correo de la cuenta, para poder enseñarlo en Ajustes.
    var correo: String?

    func cargar() async {
        conexion = .cargando

        // Datos falsos y ni un byte de red. Ver `DemoData.swift`: es lo que permite abrir
        // la app en el simulador y TOCARLA sin tener una sesión.
        if DemoData.encendido { cargarDemo(); return }

        // Sin sesión no hay nada que pedir: la app arranca en el login.
        guard Session.haySesion else { conexion = .sinLlave; return }

        // La flota la sabe el servidor. Esto es lo que borra el paso de teclear un
        // token y un id: la cuenta ya sabe qué agentes tiene, y si no tiene ninguno,
        // el servidor le provisiona el primero.
        let flota: GhostyAPI.Flota
        do {
            flota = try await GhostyAPI.flota()
        } catch Session.Fallo.caducada {
            conexion = .sinLlave
            return
        } catch {
            conexion = .fallo(error.localizedDescription)
            return
        }

        correo = flota.correo
        cuentas = flota.agentes
        Credentials.guardar(cuentas)

        guard !cuentas.isEmpty else {
            // Vacío tiene DOS causas distintas y la persona merece saber cuál: o no se
            // pudo crear el agente, o existe pero todavía no se le puede hablar.
            conexion = .fallo(
                flota.motivoSinAgente
                    ?? (flota.faltanTokens
                        ? "Tu agente se está preparando. Vuelve a intentarlo en un momento."
                        : "Todavía no tienes ningún agente.")
            )
            return
        }

        let tonos: [AgentTone] = [.lila, .azul, .durazno]
        agents = cuentas.enumerated().map { i, c in
            Agent(id: c.id, name: c.name, tone: tonos[i % tonos.count],
                  status: .idle(since: "listo"),
                  engine: c.esAgenteNativo ? "Ghosty Studio" : "EasyBits")
        }
        // El agente activo se conserva entre arranques, pero sólo si sigue existiendo:
        // uno borrado desde la web dejaría la app apuntando a la nada.
        let activo = Credentials.activeID
        selectedAgentID = cuentas.contains(where: { $0.id == activo }) ? activo! : cuentas[0].id
        // ⚠️ Los canales se crean AQUÍ y no bajo demanda desde una vista: crearlos al
        // leerlos sería mutar estado observado durante el pintado, y eso repinta en
        // bucle. Un canal que ya existe conserva su turno vivo entre recargas.
        for c in cuentas where canales[c.id] == nil {
            let canal = Canal(cuenta: c)
            // Lo guardado se pinta ANTES de hablar con la caja. Es todo el punto: el
            // historial y el hilo salen al instante y se afinan cuando la caja conteste.
            let hilos = cache.lista(c.id)
            if !hilos.isEmpty {
                canal.hilosRemotos = hilos
                canal.estadoHilos = .listo
            }
            for guardado in cache.abiertos(c.id) {
                let h = canal.abrir(guardado.sesionID)
                h.mensajes = guardado.mensajes
                h.sospechoso = guardado.sospechoso
            }
            // Siempre hay una conversación donde escribir: si no había ninguna guardada,
            // se abre una vacía. Sin esto el compositor no tendría a qué mandar.
            if canal.hilos.isEmpty { canal.abrir() }
            canal.activa = canal.hilos.last?.clave
            canales[c.id] = canal
        }
        for id in canales.keys where !cuentas.contains(where: { $0.id == id }) {
            canales[id]?.soltar(); canales[id] = nil
        }
        conexion = .lista
    }

    /// Cierra sesión: revoca en el servidor, borra el llavero y vuelve al login.
    func cerrarSesion() async {
        await Session.cerrarSesion()
        cuentas = []
        agents = []
        for c in canales.values { c.soltar() }
        canales = [:]
        cache.limpiar()
        correo = nil
        conexion = .sinLlave
    }

    /// Vuelve a pedir la flota al servidor. La usa la pantalla de cuenta.
    func recargarCredencial() async { await cargar() }

    /// Trae archivos y documentos. Con un token de agente el API contesta **401**
    /// —sólo deja mandar mensajes—, y eso se dice en pantalla en vez de mostrar una
    /// lista vacía que parece un fallo.
    /// ¿Tiene esta cuenta forma de listar archivos?
    ///
    /// Es la MISMA regla que aplica `cargarArchivos()`, dicha en un solo sitio para que la
    /// barra de pestañas pueda esconder Artefactos en vez de abrirla y disculparse. El
    /// agente que enrola la app se conecta con otra credencial, así que para él esa
    /// pantalla nunca tuvo nada que enseñar.
    var puedeVerArchivos: Bool {
        cuentas.first(where: { $0.id == selectedAgentID })?.esLlaveDeCuenta ?? false
    }

    func cargarArchivos() async {
        guard !DemoData.encendido else { estadoArchivos = .listo; return }
        guard let cuenta = cuentas.first(where: { $0.id == selectedAgentID }) else { return }
        guard cuenta.esLlaveDeCuenta else { estadoArchivos = .noPermitido; return }
        guard estadoArchivos != .cargando else { return }

        estadoArchivos = .cargando
        let cliente = EasyBitsClient(apiKey: cuenta.token)
        do {
            async let a = cliente.files(limit: 50)
            async let d = cliente.documents(limit: 50)
            archivos = try await a
            documentos = try await d
            estadoArchivos = .listo
        } catch {
            estadoArchivos = .fallo(error.localizedDescription)
        }
    }

    /// La liga viene firmada y caduca en una hora, así que se pide al abrir.
    func ligaDeArchivo(_ id: String) async -> URL? {
        guard let cuenta = cuentas.first(where: { $0.id == selectedAgentID }),
              cuenta.esLlaveDeCuenta else { return nil }
        return try? await EasyBitsClient(apiKey: cuenta.token).readURL(fileID: id)
    }

    /// Cambia de agente. **No cancela nada**: el canal del que dejas atrás sigue con
    /// su socket abierto y su turno corriendo, y al volver está donde lo dejaste.
    ///
    /// ⚠️ Esto ANTES cerraba el socket y vaciaba el hilo, así que irte con otro agente
    /// mataba el trabajo del primero sin decirlo. Era el fallo mudo de siempre: la
    /// pantalla no enseñaba ningún error, simplemente no volvía la respuesta.
    func seleccionar(_ id: String) {
        guard id != selectedAgentID, let cuenta = cuentas.first(where: { $0.id == id }) else { return }
        // El momento con contexto para pedir el permiso de notificaciones: acabas de
        // dejar a alguien trabajando y te vas. Al arrancar no significa nada y se rechaza.
        if canalActivo?.trabajando == true { Avisos.pedirPermisoSiHaceFalta() }
        if canales[id]?.hilos.isEmpty == true { canales[id]?.abrir() }
        if canales[id] == nil { canales[id] = Canal(cuenta: cuenta) }
        Credentials.activar(id)
        selectedAgentID = id
        sinVer.remove(id)
    }

    /// Empieza de cero con este agente. Suelta el `sessionId`, así que la caja abre
    /// un hilo nuevo y no arrastra el contexto anterior.
    /// Empieza un hilo NUEVO en la caja.
    ///
    /// ⚠️ Por HTTP esto era imposible y por eso apendaba: EasyBits siempre usa la
    /// única sesión ACP del agente. Sólo `session/new` por WebSocket crea un hilo.
    /// ⚠️ **Añade** una conversación, ya no vacía la que había. Vaciarla era lo que hacía
    /// imposible pedirle dos cosas al mismo agente: la anterior desaparecía de la pantalla
    /// aunque su turno siguiera corriendo, y su respuesta acababa cayendo en la nueva.
    ///
    /// La sesión de la caja NO se crea aquí: se crea al mandar el primer mensaje. Crearla
    /// antes deja hilos vacíos en la caja cada vez que alguien toca el botón y cambia de
    /// idea.
    func nuevaConversacion() {
        guard let canal = canalActivo else { return }
        // Si la que miras ya está vacía y sin estrenar, no se abre otra igual.
        if let h = canal.hilo, h.mensajes.isEmpty, h.sesionID == nil { return }
        canal.abrir()
        canal.podar()
    }

    /// Cambia de conversación DENTRO del mismo agente. No cancela nada.
    func mirar(_ hilo: Hilo, de agenteID: String? = nil) {
        let id = agenteID ?? selectedAgentID
        if id != selectedAgentID { seleccionar(id) }
        canales[id]?.activa = hilo.clave
        hilo.visto = true
    }

    // MARK: - Volver del fondo

    /// La app volvió a estar delante: recoger lo que pasó mientras no mirábamos.
    ///
    /// ⚠️ iOS suspende la app a los pocos segundos de irte y se lleva el socket. La caja
    /// **no** se entera: sigue trabajando y su sesión sigue ahí. Lo que fallaba es que al
    /// volver nadie iba a preguntar, así que el turno se quedaba pintado como un fallo y
    /// la respuesta que el agente sí produjo no aparecía nunca.
    func volverDelFondo() async {
        guard !DemoData.encendido, Session.haySesion else { return }
        for canal in canales.values {
            // Las de memoria MÁS las apuntadas en disco: si iOS mató el proceso mientras
            // no mirabas, en memoria no queda ni rastro de que había algo pendiente.
            let deLaMemoria = canal.hilos.filter { $0.interrumpido || $0.trabajando }
            let sesionesEnDeuda = Set(cache.deudas(canal.cuenta.id).map(\.sesionID))
            let delDisco = canal.hilos.filter {
                guard let sid = $0.sesionID else { return false }
                return sesionesEnDeuda.contains(sid)
            }
            var pendientes: [Hilo] = []
            for h in deLaMemoria + delDisco where !pendientes.contains(where: { $0 === h }) {
                pendientes.append(h)
            }
            guard !pendientes.isEmpty else { continue }
            // ⚠️ Sólo si NO hay nada corriendo. Soltarlo a ciegas era matar el turno que
            // acababas de mandar: el siguiente `asegurarSocket` abre uno nuevo y, al
            // hacerlo, CIERRA el viejo —y cerrar termina todos los turnos en vuelo—. Se
            // veía como mensajes que no contestaban nunca.
            if canal.enCurso.isEmpty {
                canal.acp = nil
                canal.infoDeLaCaja = nil
            }
            // ⚠️ Una tarea POR HILO, no un `await` en fila. Con tres conversaciones
            // pendientes, la tercera esperaba a que las dos primeras acabaran de hablar
            // con la caja — minutos mirando una pantalla que no cambia.
            for hilo in pendientes { recoger(hilo, de: canal) }
        }
    }

    /// La app se va al fondo. Se anota ANTES de que iOS mate nada.
    ///
    /// ⚠️ Se llama en `.inactive`, que llega mientras la app todavía está viva. En
    /// `.background` el socket ya puede estar muerto, y entonces el error que llega no se
    /// distingue de un fallo del agente: ésta es la única ventana para dejar dicho que lo
    /// que venga después fue iOS.
    func marcarFondo() {
        for canal in canales.values {
            for hilo in canal.hilos where hilo.trabajando { hilo.huboFondo = true }
        }
    }

    /// Cerrar bien lo que quede antes de que nos suspendan.
    ///
    /// iOS da ~30 segundos de gracia si se piden. Se usan para dejar el turno marcado como
    /// interrumpido, apuntar la deuda en disco y cerrar los sockets nosotros, en vez de que
    /// los mate a media trama.
    func irseAlFondo() {
        #if canImport(UIKit)
        // ⚠️ `endBackgroundTask` SIEMPRE, incluso si algo lanza: un identificador sin
        // cerrar no es un aviso, es que iOS mata la app (`0x8badf00d`).
        var gracia: UIBackgroundTaskIdentifier = .invalid
        gracia = UIApplication.shared.beginBackgroundTask(withName: "guardar-el-trabajo") {
            UIApplication.shared.endBackgroundTask(gracia)
            gracia = .invalid
        }
        defer { if gracia != .invalid { UIApplication.shared.endBackgroundTask(gracia) } }
        #endif

        for canal in canales.values {
            var hayQueGuardar = false
            for hilo in canal.hilos {
                // Una recogida a medias no sigue en el fondo: gastaría batería para que
                // iOS la suspenda a media negociación. Se retoma al volver.
                hilo.recogiendo?.cancel(); hilo.recogiendo = nil
                guard hilo.trabajando, let sid = hilo.sesionID else { continue }
                hilo.huboFondo = true
                hilo.interrumpido = true
                cache.anotarDeuda(.init(sesionID: sid, desde: Date(),
                                        mensajesAlCortar: hilo.mensajes.count),
                                  de: canal.cuenta.id)
                hayQueGuardar = true
            }
            // El parcial de la respuesta también se guarda: es lo que vas a ver al abrir.
            if hayQueGuardar { guardarHilos(canal) }
            // Y el registro: irse al fondo es justo cuando hay que poder mirarlo después.
            Bitacora.volcar()
            // ⚠️ El socket se cierra SÓLO si no hay nada corriendo, y esto es lo contrario
            // de lo que puse ayer. Cerrarlo «a propósito para que iOS no lo mate a media
            // trama» MATA EL TURNO: bloquear el teléfono tres segundos después de mandar
            // un mensaje lo tumbaba, y como el corte se lee como suspensión, la respuesta
            // no llegaba nunca y la conversación se quedaba con el cartel puesto. Medido
            // en el teléfono: «cerrando a propósito — turnos vivos: 20260909_40», y el
            // turno muerto dos milisegundos después.
            //
            // Con un turno vivo se deja abierto: los ~30 s de gracia que da iOS pueden
            // bastar para que termine, y si no, lo mata el sistema — que es exactamente
            // lo que la recogida sabe recuperar.
            if canal.enCurso.isEmpty {
                Task { [acp = canal.acp] in await acp?.cerrar() }
                canal.acp = nil
                canal.infoDeLaCaja = nil
            }
        }
    }

    /// Una sola pasada por una conversación concreta, para cuando nos despierta un push.
    ///
    /// ⚠️ Con presupuesto DURO. iOS da ~30 s a una app despertada en el fondo y castiga —en
    /// silencio, dejando de entregar los siguientes— a la que se pasa. Devuelve si trajo
    /// algo nuevo, que es lo que hay que contestarle al sistema.
    func recogerYa(agente agentID: String, sesion sid: String) async -> Bool {
        guard !DemoData.encendido, Session.haySesion,
              let canal = canales[agentID],
              let hilo = canal.hilos.first(where: { $0.sesionID == sid }) else { return false }
        if canal.enCurso.isEmpty {
            canal.acp = nil
            canal.infoDeLaCaja = nil
        }
        let antes = hilo.mensajes.count
        let completo = await resincronizar(hilo, de: canal)
        if completo { cache.saldarDeuda(sesion: sid, de: agentID) }
        return hilo.mensajes.count != antes
    }

    /// Insiste hasta que la caja tenga la respuesta, o hasta rendirse.
    ///
    /// ⚠️ Una sola pasada no basta y ése era el fallo: si el agente sigue a media faena
    /// cuando vuelves, `session/load` devuelve el hilo SIN la respuesta y nadie volvía a
    /// preguntar. La espera crece y lleva azar (`random(0, min(30, 2^n))`): sin ese azar,
    /// cuando vuelve la red todos los teléfonos entran a la vez.
    private func recoger(_ hilo: Hilo, de canal: Canal) {
        hilo.recogiendo?.cancel()
        let limite = Date().addingTimeInterval(10 * 60)
        hilo.recogiendo = Task { [weak self, weak canal] in
            // Un respiro antes del primer intento: el turno acaba de cortarse y la caja
            // puede estar todavía escribiendo la respuesta.
            try? await Task.sleep(for: .seconds(8))
            var intento = 0
            while !Task.isCancelled, Date() < limite {
                guard let self, let canal else { return }
                // ⚠️ Por SESIÓN, no por este objeto. Puede haber dos `Hilo` apuntando a
                // la misma conversación —uno abierto y otro de la lista guardada— y con
                // `hilo.trabajando` a secas la recogida del segundo seguía viva mientras
                // el primero contestaba: cada intento abría OTRO socket a la misma caja y
                // hacía `session/load` sobre la sesión que estaba corriendo. Medido en el
                // teléfono: turno a las 16:36:47 y `session/load` cada dos segundos
                // encima, hasta el intento 6. Eso es el «le escribo y no contesta».
                if hilo.trabajando || canal.enCurso.contains(where: {
                    $0.sesionID != nil && $0.sesionID == hilo.sesionID
                }) {
                    hilo.recogiendo = nil
                    return
                }
                let completo = await self.resincronizar(hilo, de: canal)
                if completo {
                    if let sid = hilo.sesionID {
                        self.cache.saldarDeuda(sesion: sid, de: canal.cuenta.id)
                    }
                    hilo.recogiendo = nil
                    return
                }
                // ⚠️ Se empieza ESPERANDO, y espaciado. El primer intento salía a los
                // 1,5 s del corte y luego cada dos o tres: si la caja seguía trabajando,
                // eso era martillearla con `session/load` sobre una sesión viva — y el
                // relé no tiene ninguna defensa contra eso (confirmado con quien lo
                // mantiene). Recoger no puede costar más que esperar.
                let tope = min(60.0, 10.0 * pow(1.8, Double(intento)))
                intento += 1
                EasyBitsClient.diag("[fondo] \(hilo.sesionID ?? "?") sigue trabajando; intento \(intento)")
                try? await Task.sleep(for: .seconds(Double.random(in: 0...tope)))
            }
            guard !Task.isCancelled, let self, let canal else { return }
            // Diez minutos sin respuesta: ya no es «espera un poco», es algo que hay que
            // contarle a quien está mirando. Y se deja de gastar red.
            hilo.interrumpido = false
            hilo.fallo = "No pude recuperar la respuesta. Vuelve a preguntarle."
            if let sid = hilo.sesionID { self.cache.saldarDeuda(sesion: sid, de: canal.cuenta.id) }
            self.refrescarEstado(canal)
            hilo.recogiendo = nil
        }
    }

    /// Vuelve a pedirle a la caja ESTA conversación y se queda con lo que diga.
    ///
    /// Es la misma operación que hace `abrirHilo`, con las mismas guardas: no pisar un
    /// hilo que está contestando, no pisar si creció, y **nunca** pisar con un replay
    /// vacío —que es lo que una vez dejó una conversación en blanco—.
    /// Devuelve si el turno YA está completo —o sea, si hay algo que enseñar y no hace
    /// falta volver a preguntar—.
    @discardableResult
    private func resincronizar(_ hilo: Hilo, de canal: Canal) async -> Bool {
        guard let sid = hilo.sesionID else { hilo.interrumpido = false; return true }
        // La misma regla, en el sitio donde de verdad se habla con la caja: nadie se pone
        // al día de una conversación que está contestando ahora mismo.
        if canal.enCurso.contains(where: { $0.sesionID == sid }) { return false }
        hilo.poniendoseAlDia = true
        defer { hilo.poniendoseAlDia = false }
        let antes = hilo.mensajes.count
        do {
            let cliente = try await asegurarSocket(canal)
            guard let replay = try await cliente.cargar(sid, cwd: "/data/work") else { return false }
            hilo.cargadaEn = ObjectIdentifier(cliente)
            let archivos = await GhostyAPI.archivosDe(sesion: sid)
            var mensajes = ReplayToMessages.convertir(replay, archivos: archivos)
            for e in entregas.deSesion(sid) where !mensajes.contains(where: { $0.id == "entrega-\(e.id)" }) {
                mensajes.append(Message(id: "entrega-\(e.id)", kind: .entrega(e)))
            }
            guard !hilo.trabajando, hilo.mensajes.count <= antes, !mensajes.isEmpty else { return true }
            // ⚠️ Que la caja conteste no quiere decir que el agente haya terminado: si
            // sigue en ello, el replay acaba en TU mensaje. Sin esta comprobación
            // dábamos la recogida por buena y enseñábamos una conversación a medias como
            // si fuera la respuesta final.
            guard Self.tieneRespuesta(mensajes) else {
                EasyBitsClient.diag("[fondo] \(sid) todavía sin respuesta")
                return false
            }
            hilo.mensajes = mensajes
            hilo.interrumpido = false
            hilo.fallo = nil
            // Es AHORA cuando de verdad contestó: por eso el aviso va aquí y no cuando se
            // cortó el socket. Y sólo si no lo estás mirando, como en cualquier turno.
            if hilo.clave != hiloActivo?.clave || Avisos.enElFondo {
                hilo.visto = false
                hilo.termino = Date()
                Avisos.sonarFin()
                if !(Avisos.hayPush && Avisos.enElFondo) {
                    Avisos.avisar(titulo: "\(canal.cuenta.name) terminó",
                                  cuerpo: hilo.prompt.isEmpty ? "Tu agente acabó el turno." : hilo.prompt,
                                  agentID: canal.cuenta.id)
                    sinVer.insert(canal.cuenta.id)
                }
            }
            refrescarEstado(canal)
            guardarHilos(canal)
            EasyBitsClient.diag("[fondo] \(sid) al día: \(mensajes.count) mensajes")
            return true
        } catch {
            EasyBitsClient.diag("[fondo] no pude ponerme al día con \(sid): \(error)")
            // Una sesión caducada no se arregla insistiendo, y callarlo deja al hilo dando
            // vueltas contra algo que ya no existe.
            if Self.esDefinitivo(error) {
                hilo.interrumpido = false
                hilo.fallo = "Hay que volver a entrar a tu cuenta."
                return true
            }
            return false
        }
    }

    /// ¿Hay respuesta del agente DESPUÉS de lo último que escribiste?
    ///
    /// Es lo único que distingue «ya terminó» de «sigue en ello» sin poder preguntárselo a
    /// la caja: el relé no tiene forma de decir si un turno sigue vivo.
    private static func tieneRespuesta(_ mensajes: [Message]) -> Bool {
        guard let ultimoTuyo = mensajes.lastIndex(where: {
            if case .user = $0.kind { return true } else { return false }
        }) else { return !mensajes.isEmpty }
        return mensajes[(ultimoTuyo + 1)...].contains {
            switch $0.kind {
            case .agent, .entrega: return true
            default: return false
            }
        }
    }

    // MARK: - Borrar

    /// Lo último que falló al borrar algo. Lo pinta quien lo pidió y lo limpia al leerlo.
    var falloAlBorrar: String?

    /// Borra una entrega. Es LOCAL: no hay nada que se pueda quedar huérfano.
    ///
    /// ⚠️ Se quita también de las conversaciones. La entrega viaja DENTRO del mensaje
    /// guardado (`MensajeGuardado.entrega`), así que borrarla sólo del almacén la haría
    /// reaparecer en cuanto se recargara el hilo.
    func borrarEntrega(_ id: String) {
        // ⚠️ Dentro de `withAnimation`, como el resto de los borrados. Una fila que
        // desaparece de golpe no se lee como "se borró": se lee como un parpadeo, y deja
        // dudando de si el toque hizo lo que pedías. La transición la ponen las vistas.
        withAnimation(Self.alBorrar) {
            entregas.olvidar(id)
            for canal in canales.values {
                for hilo in canal.hilos {
                    hilo.mensajes.removeAll { $0.id == "entrega-\(id)" }
                }
            }
        }
        for canal in canales.values { guardarHilos(canal) }
    }

    /// Cómo se va lo que se borra. Un poco más lento que un toque normal: es una acción
    /// irreversible y merece verse salir.
    static let alBorrar: Animation = .spring(response: 0.34, dampingFraction: 0.86)

    /// Borra un archivo del almacenamiento de la cuenta.
    ///
    /// ⚠️ Devuelve `false` si NO se borró allá, y entonces quien llama **no debe** quitarlo
    /// de la lista: dejar la fila fuera y el objeto dentro es exactamente el huérfano que
    /// esto viene a evitar.
    @discardableResult
    func borrarArchivo(_ id: String) async -> Bool {
        switch await GhostyAPI.borrarArchivo(id) {
        case .hecho:
            withAnimation(Self.alBorrar) { archivos.removeAll { $0.id == id } }
            CacheDeImagenes.olvidar(id)
            await cargarAlmacenamiento()
            falloAlBorrar = nil
            return true
        case .sinSoporte:
            falloAlBorrar = "Tu servidor todavía no sabe borrar archivos. No se tocó nada."
            return false
        case .fallo(let motivo):
            falloAlBorrar = motivo
            return false
        }
    }

    /// Borra una conversación de la CAJA y de aquí.
    ///
    /// Si la caja no puede, se cierra en la app igual pero se dice que allá sigue: callarlo
    /// haría creer que se borró de todas partes.
    func borrarConversacion(_ hilo: Hilo) async {
        // ⚠️ El canal DUEÑO de esta conversación, no el que esté seleccionado. Con
        // `canalActivo` bastaba con estar mirando a otro agente para que borrar una fila
        // de la lista no hiciera nada —o peor, tocara el canal equivocado—. La lista
        // enseña a todos los agentes a la vez, así que el activo no dice nada de la fila.
        guard let canal = canalDe(hilo) else { return }
        // En demo no hay caja: se cierra aquí y ya. Sin esto el borrado se quedaba
        // esperando a una red que no existe.
        let sid = DemoData.encendido ? nil : hilo.sesionID
        if let sid {
            do {
                let cliente = try await asegurarSocket(canal)
                try await cliente.borrarSesion(sid)
                falloAlBorrar = nil
            } catch {
                falloAlBorrar = "La cerré aquí, pero sigue guardada en tu agente."
            }
            titulos.olvidar(sid)
            withAnimation(Self.alBorrar) { canal.hilosRemotos.removeAll { $0.id == sid } }
            cache.guardarLista(canal.hilosRemotos, de: canal.cuenta.id)
        }
        cerrarHilo(hilo)
    }

    /// Borra una conversación guardada que no está abierta aquí.
    func borrarGuardada(_ sesion: ACPClient.Session, de agenteID: String) async {
        guard let canal = canales[agenteID] else { return }
        guard !DemoData.encendido else {
            canal.hilosRemotos.removeAll { $0.id == sesion.id }
            return
        }
        do {
            let cliente = try await asegurarSocket(canal)
            try await cliente.borrarSesion(sesion.id)
            falloAlBorrar = nil
        } catch {
            falloAlBorrar = "Tu agente no pudo borrarla. Sigue ahí."
            return
        }
        titulos.olvidar(sesion.id)
        withAnimation(Self.alBorrar) { canal.hilosRemotos.removeAll { $0.id == sesion.id } }
        cache.guardarLista(canal.hilosRemotos, de: canal.cuenta.id)
    }

    /// Cierra una conversación de la app. No la borra de la caja.
    /// De qué agente es esta conversación. Ver el aviso de `borrarConversacion`.
    private func canalDe(_ hilo: Hilo) -> Canal? {
        canales.values.first { c in c.hilos.contains { $0.clave == hilo.clave } }
    }

    func cerrarHilo(_ hilo: Hilo) {
        guard let canal = canalDe(hilo) else { return }
        if let sid = hilo.sesionID { Task { await canal.acp?.cancelar(sid) } }
        withAnimation(Self.alBorrar) {
            canal.cerrar(hilo)
            if canal.hilos.isEmpty { canal.abrir() }
        }
        guardarHilos(canal)
    }

    /// Cambia entre aprobar solo y pedir permiso.
    func fijarModo(_ modo: String) async {
        guard let canal = canalActivo, let hilo = canal.hilo, let sid = hilo.sesionID else { return }
        do {
            let cliente = try await asegurarSocket(canal)
            try await cliente.fijarModo(modo, sessionID: sid)
            hilo.modo = modo
        } catch {
            EasyBitsClient.diag("no pude fijar el modo: \(error)")
        }
    }

    var modoActual: String { hiloActivo?.modo ?? "auto" }

    func quitarAgente(_ id: String) {
        Credentials.quitar(id)
        canales[id]?.soltar()
        canales[id] = nil
        cache.olvidar(id)
        Task { await cargar() }
    }

    // MARK: - Hilos de la caja (WebSocket ACP)

    /// El WebSocket convive con el HTTP en vez de reemplazarlo: el turno sigue yendo
    /// por HTTP porque ése **despierta la caja**, y esto sirve para lo que HTTP no
    /// puede — listar y cargar hilos.
    /// Asegura socket abierto. Si la caja está dormida el WebSocket falla, así que se
    /// la despierta con un turno HTTP mínimo —lo único que sabe despertarla— y se
    /// reintenta.
    private func asegurarSocket(_ canal: Canal) async throws -> ACPClient {
        if let c = canal.acp, canal.infoDeLaCaja != nil { return c }
        // ⚠️ COALESCIDO. Con varias conversaciones, dos hilos arrancando a la vez entraban
        // aquí a la vez y creaban DOS `ACPClient` para el mismo agente: el segundo pisaba
        // al primero y el primero se quedaba con su socket abierto y sin dueño. Ésa es la
        // acumulación de sockets, y es la razón por la que esto se comparte.
        if let enVuelo = canal.abriendoSocket { return try await enVuelo.value }
        let tarea = Task<ACPClient, Error> { try await self.abrirSocket(canal) }
        canal.abriendoSocket = tarea
        defer { canal.abriendoSocket = nil }
        return try await tarea.value
    }

    private func abrirSocket(_ canal: Canal) async throws -> ACPClient {
        let cuenta = canal.cuenta
        // El anterior se cierra: reemplazarlo a secas dejaba su socket y su lector vivos.
        //
        // ⚠️ Salvo que tenga TURNOS EN VUELO. `cerrar()` termina sus flujos, así que
        // cerrarlo aquí mataba la respuesta que estaba llegando por él — y el turno moría
        // sin decir nada, que es como se veía «mandé tres mensajes y no contestó ninguno».
        // Se suelta la referencia y el cliente se apaga solo cuando acaben sus turnos.
        if let viejo = canal.acp {
            if await viejo.turnosVivos > 0 {
                EasyBitsClient.diag("[acp] socket viejo con turnos vivos: lo dejo terminar")
            } else {
                await viejo.cerrar()
            }
            canal.acp = nil
        }
        // Levantar una caja dormida tarda segundos. Sin decirlo, la app se siente colgada.
        canal.despertando = true
        defer { canal.despertando = false }
        let c = ACPClient(agentID: cuenta.id, token: cuenta.token, host: cuenta.host)
        do {
            canal.infoDeLaCaja = try await c.conectar()
        } catch {
            // ⚠️ El rescate por `/revive` es de EasyBits y SÓLO sirve para sus agentes:
            // con un agente nativo se le manda un cuid de gs y un token `gat_` que no
            // conoce, así que falla siempre — y su error TAPA al de verdad, que es lo que
            // convertía cualquier tropiezo en un mensaje que no explica nada.
            //
            // Para un agente nativo se reintenta a secas: una caja que hiberna despierta
            // con el propio upgrade del WebSocket, sólo tarda unos segundos.
            EasyBitsClient.diag("socket falló: \(error)")
            if cuenta.esAgenteNativo {
                try await Task.sleep(for: .seconds(2))
                canal.infoDeLaCaja = try await c.conectar()
            } else {
                // ⚠️ Despertar con un turno HTTP de "ping" APENDABA al hilo por defecto
                // del agente. `/revive` levanta la caja sin tocar la conversación.
                try await EasyBitsClient(apiKey: cuenta.token).revive(agentID: cuenta.id)
                canal.infoDeLaCaja = try await c.conectar()
            }
        }
        canal.acp = c
        await c.alPedirPermiso { [weak self, weak canal] p in
            Task { @MainActor in
                guard let canal else { return }
                self?.recibirPermiso(p, en: canal)
            }
        }
        // Si el socket se cae, el canal deja de darlo por bueno. Sin esto un corte de red
        // mataba todas las conversaciones del agente y ninguna se recuperaba sola.
        await c.alPerderse { [weak canal] in
            Task { @MainActor in
                canal?.acp = nil
                canal?.infoDeLaCaja = nil
            }
        }
        return c
    }

    /// Devuelve el hilo activo, creándolo si hace falta.
    ///
    /// ⚠️ Esto existe porque **al abrir la app no había ninguna sesión**, así que el
    /// primer turno se iba por HTTP — y por HTTP EasyBits siempre habla con la única
    /// sesión ACP del agente, o sea que caía en el hilo viejo. Sin sesión no se manda
    /// nada por HTTP.
    private func asegurarHilo(_ canal: Canal, _ hilo: Hilo) async throws -> String {
        if let sid = hilo.sesionID {
            // ⚠️ Rehidratar antes de hablar. La caja no guarda la sesión entre conexiones:
            // tras reconectar, un turno con el `sessionId` viejo cae en una sesión que
            // para ella está vacía, y el agente contesta que no tiene contexto previo. Un
            // `session/load` por socket lo devuelve a la vida — y es best-effort: si
            // falla, mejor mandar el turno sin contexto que perderlo.
            let cliente = try await asegurarSocket(canal)
            EasyBitsClient.diag("[hilo] rehidratando \(sid) en cliente \(ObjectIdentifier(cliente).debugDescription.suffix(8))")
            // ⚠️ ANTES DE CADA TURNO, no una vez por socket. El relé puede mantener el
            // socket vivo mientras la caja de detrás se recicla —el janitor la recoge a
            // las horas— y entonces la sesión se pierde sin que el socket se entere: la
            // app creía tenerla rehidratada y el agente empezaba en blanco. Cuesta una
            // ida y vuelta por turno; la memoria de la conversación vale más que eso.
            do {
                    let r = try await cliente.cargar(sid, cwd: "/data/work")
                    EasyBitsClient.diag("[hilo] rehidratada \(sid): \(r?.count ?? -1) eventos")
                } catch {
                    // ⚠️ NO se traga. Si la caja no puede devolvernos la sesión, el turno
                    // que sigue va SIN contexto y el agente contesta "no sé de qué me
                    // hablas" — que es un fallo mudo con cara de agente tonto.
                    EasyBitsClient.diag("[hilo] ⚠️ NO pude rehidratar \(sid): \(error)")
            }
            EasyBitsClient.diag("[hilo] turno a sesión \(sid)")
            return sid
        }
        if let enVuelo = hilo.creando { return try await enVuelo.value }

        let tarea = Task<String, Error> {
            let cliente = try await asegurarSocket(canal)
            let (id, modos) = try await cliente.nuevaSesion()
            EasyBitsClient.diag("[hilo] sesión NUEVA \(id)")
            hilo.sesionID = id
            hilo.cargadaEn = ObjectIdentifier(cliente)
            hilo.modo = modos?.actual ?? "auto"
            return id
        }
        hilo.creando = tarea
        defer { hilo.creando = nil }
        return try await tarea.value
    }

    /// El agente pidió permiso. El turno está detenido hasta que se conteste.
    private func recibirPermiso(_ p: ACPClient.Permiso, en canal: Canal) {
        // ⚠️ Al hilo que lo pidió. `Permiso` trae su `sessionID` desde siempre y se
        // ignoraba: con dos turnos a la vez, el segundo permiso pisaba al primero y ese
        // turno se quedaba detenido en la caja para siempre, sin nada en pantalla.
        //
        // Si viene sin hilo, se le da al único que esté trabajando; con varios NO se
        // adivina: se deja en el que miras, que es donde alguien lo va a ver.
        let hilo = canal.hilo(sesion: p.sessionID)
            ?? (canal.enCurso.count == 1 ? canal.enCurso.first : nil)
            ?? canal.hilo
        guard let hilo else { return }
        hilo.permisoACP = p
        refrescarEstado(canal)
        // El más urgente de los dos avisos: este turno está DETENIDO hasta que contestes.
        // ⚠️ La condición es por HILO, no por agente: con tres conversaciones del agente
        // que estás mirando, dos podían pedirte permiso y no avisarte de ninguna.
        // Misma regla que el aviso de fin: con push registrado, el local sólo con la app
        // delante — si no, llegarían dos por lo mismo.
        if hilo.clave != hiloActivo?.clave, !(Avisos.hayPush && Avisos.enElFondo) {
            Avisos.avisar(titulo: "\(canal.cuenta.name) espera tu permiso",
                          cuerpo: "¿Dejas que use \(p.titulo)?",
                          agentID: canal.cuenta.id, sonido: .gota)
            sinVer.insert(canal.cuenta.id)
        }
        hilo.permisoPendiente = PermissionRequest(
            id: "\(p.id)",
            kind: .publish,
            agentName: canal.cuenta.name,
            question: "¿Dejas que use \(p.titulo)?",
            detail: p.opciones.isEmpty
                ? "El agente espera tu respuesta para seguir."
                : "El turno está detenido hasta que contestes.",
            attachment: nil)
    }

    func cargarHilos() async {
        guard !DemoData.encendido else { return }
        guard let canal = canalActivo, canal.estadoHilos != .cargando else { return }
        // ⚠️ Con lista cacheada NO se enseña el spinner: ya hay algo bueno en pantalla y
        // taparlo con "preguntándole a tu agente…" es empeorarlo a propósito. Se refresca
        // por detrás y se sustituye al llegar.
        let hayCache = !canal.hilosRemotos.isEmpty
        if !hayCache { canal.estadoHilos = .cargando }

        do {
            let cliente = try await asegurarSocket(canal)
            canal.hilosRemotos = try await cliente.sesiones()
            canal.estadoHilos = .listo
            cache.guardarLista(canal.hilosRemotos, de: canal.cuenta.id)
        } catch {
            // ⚠️ El socket se suelta ANTES de decidir si el fallo se enseña o no. Estaba
            // sólo en la rama sin caché, y por eso con caché el canal se quedaba pegado a
            // un socket muerto: `asegurarSocket` lo da por bueno mientras `infoDeLaCaja`
            // no sea nil, así que ya no reintentaba la reconexión nunca.
            canal.acp = nil; canal.infoDeLaCaja = nil
            // Un fallo de red con lista cacheada se traga: lo que hay sigue siendo cierto,
            // y cambiarlo por una pantalla de error borraría información buena.
            if hayCache { canal.estadoHilos = .listo; return }
            canal.estadoHilos = .fallo(error.localizedDescription)
        }
    }

    /// Abre un hilo de la caja en la conversación. Lo que se pinta es el replay que
    /// manda `session/load`, no algo guardado aquí.
    func abrirHilo(_ sesion: ACPClient.Session) async {
        guard let canal = canalActivo else { return }
        // En demo no hay caja: se abre el hilo y ya. Sin esto la pantalla se llenaba de
        // "bad response from the server" y no se podía revisar nada.
        if DemoData.encendido { _ = canal.abrir(sesion.id); return }
        // ⚠️ Lo primero: si ese hilo YA está abierto en la app, sólo se mira. No se
        // recarga y no se toca nada. Aquí estaba el fallo grave: se pisaba la
        // conversación activa aunque estuviera contestando, y su respuesta seguía
        // escribiéndose en el array que ahora enseñaba OTRA conversación.
        if let ya = canal.hilo(sesion: sesion.id) {
            canal.activa = ya.clave
            // Y si está contestando, ni se le ocurra recargarlo: el replay entra por el
            // mismo `session/update` que el streaming y le metería la conversación
            // entera dentro del turno en curso.
            guard !ya.trabajando else { return }
        }
        let hilo = canal.abrir(sesion.id)
        // Lo guardado se pinta YA y el replay lo sustituye cuando llegue. Manda el
        // replay: un caché que gana sobre la caja es un caché que miente.
        if hilo.mensajes.isEmpty, let guardado = cache.abierto(canal.cuenta.id, sesion: sesion.id) {
            hilo.mensajes = guardado
        }
        canal.podar()
        // Con qué conversación empezamos. Si crece mientras carga es que la persona
        // escribió, y entonces el replay ya no puede pisarla.
        let antes = hilo.mensajes.count
        do {
            let cliente = try await asegurarSocket(canal)
            guard let replay = try await cliente.cargar(sesion.id, cwd: sesion.cwd) else { return }
            hilo.cargadaEn = ObjectIdentifier(cliente)
            // Los archivos que se subieron EN esta conversación. Es lo que devuelve a la
            // vida sus adjuntos: el replay de ACP trae sólo texto. Best-effort — si no
            // contesta, el hilo se abre igual y los adjuntos salen nombrados.
            let archivos = await GhostyAPI.archivosDe(sesion: sesion.id)
            var mensajes = ReplayToMessages.convertir(replay, archivos: archivos)
            // ⚠️ Las entregas se vuelven a coser AQUÍ. El replay de la caja no las trae
            // —el relé las empuja en vivo y no las guarda—, así que sin esto la foto que
            // te entregó el agente desaparecía del hilo al reabrirlo: seguía en
            // Artefactos, pero la conversación se quedaba con el texto solo.
            for e in entregas.deSesion(sesion.id) where !mensajes.contains(where: { $0.id == "entrega-\(e.id)" }) {
                mensajes.append(Message(id: "entrega-\(e.id)", kind: .entrega(e)))
            }
            // ⚠️⚠️ Tres motivos para NO pisar lo que hay, y los tres pasaron:
            //
            // 1. El turno arrancó mientras cargábamos. Alguien escribió en el segundo que
            //    tardó el replay y pisarlo le borraría su mensaje.
            // 2. La conversación creció por cualquier otra vía.
            // 3. **El replay volvió VACÍO.** Un `session/load` que no devuelve nada
            //    significa que la caja no nos dio el hilo, NO que el hilo esté vacío.
            //    Creerlo a ciegas borraba la conversación entera —memoria y disco— y te
            //    dejaba mirando un chat en blanco. Es el peor fallo que ha tenido esto.
            guard !hilo.trabajando, hilo.mensajes.count <= antes else { return }
            guard !mensajes.isEmpty || hilo.mensajes.isEmpty else {
                EasyBitsClient.diag("⚠️ session/load de \(sesion.id) volvió vacío — se conserva lo que había")
                return
            }
            hilo.mensajes = mensajes
            hilo.sospechoso = false
            // El título sale del primer mensaje del hilo, que es lo que hacen
            // ChatGPT, Claude y la propia interfaz de goose. Sale gratis: el replay
            // ya está aquí.
            if let primero = mensajes.first(where: { if case .user = $0.kind { return true } else { return false } }),
               case .user(let t, _) = primero.kind {
                titulos.anotarSiFalta(sesion.id, desde: t)
            }
            guardarHilos(canal)
        } catch {
            canal.estadoHilos = .fallo(error.localizedDescription)
        }
    }

    /// Vuelca a disco las conversaciones abiertas de un agente.
    private func guardarHilos(_ canal: Canal) {
        cache.guardarAbiertos(canal.hilos.compactMap { h in
            guard let sid = h.sesionID, !h.mensajes.isEmpty else { return nil }
            return (sid, h.mensajes)
        }, de: canal.cuenta.id)
    }

    /// Guarda YA la conversación que se está mirando.
    ///
    /// ⚠️ Antes sólo se guardaba al cerrar el turno, así que lo que escribías vivía sólo
    /// en memoria hasta que el agente terminara. Cualquier tropiezo entre medias —y hubo
    /// uno que vaciaba el hilo— se llevaba tu mensaje sin dejar copia.
    private func guardarYa(_ canal: Canal) { guardarHilos(canal) }

    /// El estado de un agente, calculado de sus conversaciones.
    ///
    /// ⚠️ Se pregunta AQUÍ y no se lee de `agents[i].status`, porque un valor guardado se
    /// desincroniza: en la demo la mascota decía "En reposo" con un turno corriendo
    /// delante. Lo que no se guarda no puede contradecir a lo que pasa.
    func estado(de agentID: String) -> AgentStatus {
        guard let canal = canales[agentID] else { return .idle(since: "listo") }
        if !canal.esperandoPermiso.isEmpty { return .awaitingApproval }
        if let vivo = canal.enCurso.last {
            return .working(task: vivo.turno?.detail ?? "Trabajando…")
        }
        // ⚠️ Un hilo INTERRUMPIDO no está en reposo. La cabecera decía «En reposo · listo»
        // justo encima del cartel que dice «tu agente sigue con esto»: dos frases que se
        // contradicen en la misma pantalla, y la de arriba es la que hace pensar que se
        // colgó. El turno local ya no existe —lo mató la suspensión— pero el trabajo sí.
        if canal.hilos.contains(where: { $0.interrumpido }) {
            return .working(task: "Sigue trabajando…")
        }
        return .idle(since: "listo")
    }

    /// El estado del agente SALE de sus hilos, nunca se asigna a mano.
    ///
    /// ⚠️ Se asignaba en `marcarTrabajando` y `cerrarTurno`, y con varias conversaciones
    /// eso miente: el primer turno que termina apagaba el estado del agente aunque los
    /// otros dos siguieran corriendo.
    private func refrescarEstado(_ canal: Canal) {
        guard let i = agents.firstIndex(where: { $0.id == canal.cuenta.id }) else { return }
        if !canal.esperandoPermiso.isEmpty {
            // Gana siempre: es lo único que te está esperando a ti, y está detenido.
            agents[i].status = .awaitingApproval
        } else if let vivo = canal.enCurso.last {
            agents[i].status = .working(task: vivo.turno?.detail ?? "Trabajando…")
        } else {
            agents[i].status = .idle(since: "ahora")
        }
    }

    // MARK: - AgentStoring

    /// ⚠️ El del protocolo `AgentStoring`, explícito y no por valor por defecto: Swift NO
    /// da por cumplido un requisito con un parámetro que tiene default, y el error que da
    /// («no conforma») no menciona el método.
    func send(_ text: String) async { await send(text, adjuntos: []) }

    /// `a` es a QUÉ agente. Sin él, al que estás mirando.
    ///
    /// ⚠️ Existe para poder mandarle algo a otro agente **sin cambiar de conversación**,
    /// que es lo que hace la Flota. Antes cualquier turno iba forzosamente al canal activo,
    /// así que poner a dos a trabajar obligaba a ir y volver.
    func send(_ text: String, adjuntos: [Adjunto] = [], a agenteID: String? = nil) async {
        let limpio = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty || !adjuntos.isEmpty,
              let canal = canales[agenteID ?? selectedAgentID] else { return }
        let cuenta = canal.cuenta
        // A qué conversación. Desde la flota se le manda a la que tuviera abierta; si no
        // tiene ninguna, se le abre una.
        // ⚠️ `canal.hilo` ya cae en la última si `activa` quedó colgada; abrir una nueva
        // aquí sólo pasa si el agente no tenía ninguna. Crear una a la ligera es lo que
        // hacía que un mensaje acabara en una conversación en blanco.
        let hilo = canal.hilo ?? canal.abrir()
        canal.activa = hilo.clave
        // Un turno nuevo borra el fallo del anterior: lo que importa es cómo va ÉSTE.
        hilo.fallo = nil
        // Y manda sobre la recogida de lo anterior: si le vuelves a escribir, lo que sea
        // que estuviéramos rescatando ya no es lo que estás esperando.
        hilo.recogiendo?.cancel(); hilo.recogiendo = nil
        hilo.interrumpido = false
        hilo.paraReintentar = nil
        hilo.huboFondo = false
        if let sid = hilo.sesionID { cache.saldarDeuda(sesion: sid, de: cuenta.id) }
        // ⚠️ AQUÍ y sólo aquí: escribirle es lo que revive una conversación y la manda al
        // principio de la barra. Mirarla no la mueve — reordenar mientras eliges cambia
        // las fichas de sitio debajo del dedo.
        //
        // ⚠️ Y ANIMADO. Sin transacción, el chip salta de su sitio al principio de la fila
        // en un fotograma: se lee como que la conversación **desapareció**, no como que se
        // movió. Animado, se ve irse.
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            hilo.tocado = Date()
        }
        // Mandarle a OTRO agente es dejarlo trabajando sin mirarlo: es justo el caso que
        // necesita el aviso, y el momento con contexto para pedirlo.
        if cuenta.id != selectedAgentID { Avisos.pedirPermisoSiHaceFalta() }

        // ⚠️ El tope se comprueba SOBRE LOS OTROS hilos: reenviar a uno que ya trabaja es
        // legítimo (lo cancela y manda de nuevo), abrir un cuarto turno no.
        let otros = canal.enCurso.filter { $0.clave != hilo.clave }.count
        if otros >= Self.topeDeTurnos {
            hilo.mensajes.append(Message(
                id: UUID().uuidString,
                kind: .agent(text: "⚠️ \(cuenta.name) ya tiene \(otros) conversaciones trabajando. "
                             + "Espera a que alguna termine, o detén una desde la Flota.",
                             tools: nil, trailing: nil)))
            return
        }

        // ⚠️ Sólo se cancela el turno de ESTE hilo. Cancelar el del canal cortaba las
        // otras conversaciones del mismo agente.
        //
        // ⚠️ Y se GUARDA para esperarlo: ACP admite un `session/prompt` por sesión a la
        // vez, y su `session/cancel` viaja por el mismo socket en otra tarea. Encadenar el
        // turno nuevo sin esperar dejaba la cancelación del viejo llegando DESPUÉS de que
        // el nuevo empezara — cancelándolo a él. Es lo que pasaba al mandar dos seguidos
        // sin esperar respuesta: el segundo contestaba «no tengo ningún encargo previo».
        let anterior = hilo.enVuelo
        anterior?.cancel()
        hilo.mensajes.removeAll { $0.kind == .typing }
        // ⚠️ Envuelto en `withAnimation` cuando hay voz: es lo que deja que la barra de
        // grabación y la burbuja se emparejen con `matchedGeometryEffect`. Sin transacción
        // animada, la barra desaparece y la burbuja aparece — dos hechos, no un movimiento.
        let conVoz = adjuntos.contains(where: \.esVoz)
        let mensaje = Message(id: UUID().uuidString, kind: .user(limpio, adjuntos: adjuntos))
        if conVoz {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { hilo.mensajes.append(mensaje) }
        } else {
            hilo.mensajes.append(mensaje)
        }
        let idRespuesta = UUID().uuidString
        hilo.mensajes.append(Message(id: "typing", kind: .typing))
        hilo.sinHerramientas = true
        EasyBitsClient.diag("[envío] hilo=\(hilo.clave.prefix(8)) sesión=\(hilo.sesionID?.prefix(8) ?? "nueva") "
                            + "activa=\(canal.activa?.prefix(8) ?? "-") mensajes=\(hilo.mensajes.count) "
                            + "hilos=\(canal.hilos.count)")
        // Lo que acabas de escribir va a disco YA, no al cerrar el turno.
        guardarYa(canal)

        refrescarEstado(canal)
        arrancarCronometro(hilo, titulo: primeraFrase(limpio))
        // ⚠️ Levantar una caja dormida tarda segundos —hay `/revive` y reintentos— y
        // hasta ahora eso eran tres puntitos mudos: la app se sentía colgada. Decirlo no
        // la hace más rápida, la hace honesta.
        if canal.acp == nil { hilo.turno?.detail = "Despertando a tu agente…" }
        hilo.prompt = limpio
        hilo.uso = (0, 0)

        hilo.enVuelo = Task { [weak self] in
            guard let self else { return }
            // El turno anterior tiene que estar MUERTO antes de hablarle a la misma sesión.
            await anterior?.value
            do {
                // El turno va SIEMPRE por el socket: es el único que respeta el hilo.
                // Por HTTP EasyBits habla con la única sesión ACP del agente, así que
                // cualquier turno por ahí acaba en la conversación equivocada.
                let sid = try await self.asegurarHilo(canal, hilo)
                self.titulos.anotarSiFalta(sid, desde: limpio)
                // Todo adjunto se sube a la cuenta; una imagen viaja ADEMÁS inline, y una
                // nota de voz se transcribe aquí.
                let conArchivos = await self.subidos(adjuntos, sesion: sid)
                hilo.envioFallo = false
                // La transcripción va en el TEXTO del turno, delante de lo que escribiera
                // la persona: es lo que dijo, no un adjunto que haya que ir a buscar.
                let dicho = conArchivos.compactMap(\.transcripcion)
                    .map(BloqueDeAdjuntos.transcripcion)
                    .joined(separator: "\n\n")
                let conVoz = dicho.isEmpty ? limpio
                    : (limpio.isEmpty ? dicho : "\(dicho)\n\n\(limpio)")
                // ⚠️ La conversación previa viaja EN el turno. Ver `BloqueDeHistorial`:
                // está medido que la caja reemite el transcript al cliente pero no
                // reconstruye el contexto del modelo, así que si no se la mandamos
                // nosotros, el agente empieza en blanco en cada mensaje. Es un parche con
                // coste en tokens y se borra el día que la caja lo haga bien.
                let conHistoria = BloqueDeHistorial.texto(hilo.mensajes)
                    .map { "\($0)\n\n\(conVoz)" } ?? conVoz
                await self.porSocket(canal, hilo, sid: sid, texto: conHistoria,
                                     adjuntos: conArchivos,
                                     respuesta: idRespuesta)
            } catch {
                // Si el socket no se puede ni levantando la caja, se dice. Mandarlo
                // por HTTP en silencio lo metería en otro hilo, que es peor que fallar.
                // Un fallo aquí es "no llegó a salir": o no se pudo abrir la conversación,
                // o no se pudo subir un adjunto. En los dos casos el agente no vio nada, y
                // el compositor tiene que poder devolverle su trabajo a la persona.
                hilo.envioFallo = true
                hilo.fallo = "No llegó a salir"
                self.pintarRespuesta(hilo, id: idRespuesta,
                                     texto: "⚠️ \(error.localizedDescription)")
                self.anotar(canal, hilo, chars: 0, como: .failed)
                self.cerrarTurno(canal, hilo)
            }
        }
    }

    /// El turno por WebSocket.
    /// Sube lo que no es imagen y le antepone al turno una línea que NOMBRA cada archivo.
    ///
    /// ⚠️ Decírselo no es opcional: guardar la ruta sin mencionarla no entrega nada. Es la
    /// regla de la casa —«autodescubrible ≠ leída»— y aquí es literal, porque el agente no
    /// tiene forma de enterarse de que apareció un archivo en su disco.
    ///
    /// La ruta es la que sus propias skills ya nombran (`adjuntos/…`), así que sabe qué
    /// hacer con ella sin que se lo expliquemos.
    /// Sube los adjuntos al almacenamiento de la CUENTA y devuelve los que llegaron.
    ///
    /// ⚠️ Ya no van a la caja del agente. Un adjunto vivía sólo en `/data/work/adjuntos/`,
    /// y el janitor recicla esa caja a las 72 h dormida y la repone vacía: el archivo
    /// desaparecía sin que nada lo dijera, así que "vuelve a mirar la foto de ayer" no
    /// tenía respuesta. Ahora cuelga de la cuenta y el agente se lo baja cuando lo
    /// necesita — la caja sigue siendo desechable a propósito.
    ///
    /// ⚠️ Las imágenes se suben IGUAL que lo demás, aunque además viajen inline. Inline es
    /// lo único que deja al modelo VERLA; el archivo es lo que deja recortarla o medirla.
    /// Son complementarias, no alternativas.
    ///
    /// ⚠️ Un archivo que no sube NO tumba el turno: se manda igual y el prompt lo DICE
    /// (`BloqueDeAdjuntos.noEntregado`). Perder la pregunta entera por un adjunto es peor
    /// que contestar sin él, y callarlo es el fallo mudo de siempre.
    private func subidos(_ adjuntos: [Adjunto], sesion: String?) async -> [Adjunto] {
        var salida: [Adjunto] = []
        for var a in adjuntos {
            // La voz se transcribe AQUÍ, en la plataforma. Medido en Teams: pedírselo al
            // agente costaba 3 llamadas de shell para leer 4 segundos de voz.
            //
            // Best-effort: si whisper no contesta, el audio viaja igual y su línea del
            // bloque vuelve a decirle al agente cómo transcribirlo él. Perder la nota
            // entera por una transcripción sería mucho peor.
            if a.esVoz {
                a.transcripcion = await GhostyAPI.transcribir(a.datos, mime: a.mime)
            }
            do {
                a.remoto = try await GhostyAPI.subir(a, sesion: sesion)
            } catch {
                falloDeSubida = error.localizedDescription
                print("[adjunto] no subió \(a.nombre): \(error.localizedDescription)")
            }
            salida.append(a)
        }
        return salida
    }

    private func porSocket(_ canal: Canal, _ hilo: Hilo, sid: String,
                           texto: String, adjuntos: [Adjunto] = [],
                           respuesta: String) async {
        EasyBitsClient.diag("[turno] arrancando \(sid) en cliente \(canal.acp.map { ObjectIdentifier($0).debugDescription.suffix(8) } ?? "NINGUNO")")
        guard let cliente = canal.acp else {
            pintarRespuesta(hilo, id: respuesta, texto: "⚠️ Se perdió la conexión con tu agente.")
            cerrarTurno(canal, hilo)
            return
        }
        var acumulado = ""
        var herramientas: [Herramienta] = []

        do {
            for try await evento in cliente.prompt(sessionID: sid, texto: texto, adjuntos: adjuntos) {
                // ⚠️ Que llegue UN evento es la prueba de que la caja está ahí: se apaga
                // la marca de interrumpido. Sin esto, un hilo que se cortó una vez se
                // quedaba con el cartel de «tu agente sigue con esto» y la cabecera
                // diciendo «Sigue trabajando…» PARA SIEMPRE, aunque la respuesta ya
                // hubiera llegado y estuviera pintada debajo.
                if hilo.interrumpido {
                    hilo.interrumpido = false
                    cache.saldarDeuda(sesion: sid, de: canal.cuenta.id)
                    refrescarEstado(canal)
                }
                switch evento {
                case .agent(let t):
                    acumulado += t
                    // ⚠️ Un ` ```eb-file ` deja de ser texto y pasa a ser tarjeta. Ver
                    // `BloqueEbFile`: es un puente hasta que el relé mande
                    // `ghosty/artifact` para todo lo que produce. Sin esto salía el JSON
                    // crudo en mitad de la respuesta y el archivo no llegaba a Artefactos.
                    for hallado in BloqueEbFile.buscar(acumulado, agentID: canal.cuenta.id,
                                                       sesionID: sid).reversed() {
                        acumulado.removeSubrange(hallado.rango)
                        entregas.registrar(hallado.entrega)
                        let idEntrega = "entrega-\(hallado.entrega.id)"
                        if !hilo.mensajes.contains(where: { $0.id == idEntrega }) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                hilo.mensajes.append(Message(id: idEntrega,
                                                             kind: .entrega(hallado.entrega)))
                            }
                        }
                    }
                    pintarRespuesta(hilo, id: respuesta, texto: acumulado, herramientas: herramientas)
                case .tool(let h):
                    // ACP manda la MISMA herramienta varias veces conforme avanza: se
                    // actualiza en su sitio en vez de duplicarla, y así el spinner se
                    // convierte en palomita sin que la lista salte.
                    //
                    // ⚠️ Un update posterior puede venir sin título (sólo con el estado):
                    // se conserva el que ya teníamos o quedaría "herramienta" a secas.
                    if let i = herramientas.firstIndex(where: { $0.id == h.id }) {
                        var v = h
                        if v.titulo == "herramienta" { v.titulo = herramientas[i].titulo }
                        if v.salida == nil { v.salida = herramientas[i].salida }
                        if v.donde == nil { v.donde = herramientas[i].donde }
                        herramientas[i] = v
                    } else {
                        herramientas.append(h)
                    }
                    // Lo que está haciendo AHORA, donde el ojo ya está mirando.
                    // ⚠️ Manda la que está CORRIENDO ahora, no «hubo alguna alguna vez».
                    // Con lo segundo, la primera herramienta apagaba la rotación para
                    // siempre y el estado se congelaba en su nombre —o en «Trabajando…»—
                    // durante todo lo que quedara del turno, que suele ser lo más largo.
                    if let viva = herramientas.last(where: \.esperando) {
                        hilo.sinHerramientas = false
                        hilo.turno?.detail = viva.titulo
                    } else {
                        // Ninguna corriendo: vuelve a mandar el reloj.
                        hilo.sinHerramientas = true
                    }
                    hilo.turno?.step = herramientas.filter { !$0.esperando }.count
                    hilo.turno?.totalSteps = herramientas.count
                    pintarRespuesta(hilo, id: respuesta, texto: acumulado, herramientas: herramientas)
                case .usage(let entrada, let salida):
                    hilo.uso = (entrada, salida)
                case .entrega(var e):
                    // De QUÉ conversación. Sin esto no se puede devolver al hilo al
                    // recargarlo, porque el replay de la caja no trae entregas.
                    e.sesionID = sid
                    // Se guarda ANTES de pintarla: si la app muere entre una cosa y otra,
                    // preferimos una entrega guardada que no se anunció a un anuncio de
                    // algo que ya no está.
                    entregas.registrar(e)
                    // Tarjeta propia, no un campo del mensaje: la entrega llega a mitad
                    // del turno y el texto del agente sigue creciendo después. Metida en
                    // la burbuja, cada trozo nuevo la repintaría.
                    // ⚠️ El append va DENTRO de `withAnimation` o la `.transition` de la
                    // tarjeta no corre: SwiftUI anima la inserción sólo si el cambio de
                    // estado ocurre dentro de una transacción animada. Este repo no usa
                    // `.animation(` implícito en ningún sitio, y mezclarlo haría saltar
                    // cosas sin que nada lo explique.
                    // ⚠️ NUNCA dos mensajes con el mismo id en un hilo. Desde que el id
                    // de la entrega es determinista, la misma entrega puede llegar dos
                    // veces al mismo hilo —el relé no dice a qué conversación va, así que
                    // con varios turnos vivos se reparte a todos—. Y un `ForEach` con ids
                    // repetidos no pinta "de más": deja de pintar, y el hilo se queda EN
                    // BLANCO con los mensajes ahí. Es el fallo que se veía como
                    // "escribo y desaparece el historial".
                    let idEntrega = "entrega-\(e.id)"
                    if !hilo.mensajes.contains(where: { $0.id == idEntrega }) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            hilo.mensajes.append(Message(id: idEntrega, kind: .entrega(e)))
                        }
                    }
                case .user, .thought:
                    break
                }
            }
            if acumulado.isEmpty && herramientas.isEmpty {
                pintarRespuesta(hilo, id: respuesta, texto: "_El turno cerró sin texto._")
            }
            // Terminó de verdad: nada de esto sigue pendiente.
            hilo.interrumpido = false
            hilo.huboFondo = false
            hilo.recogiendo?.cancel(); hilo.recogiendo = nil
            cache.saldarDeuda(sesion: sid, de: canal.cuenta.id)
            anotar(canal, hilo, chars: acumulado.count, como: .done)
        } catch {
            // ⚠️⚠️ AQUÍ SE DECÍA UNA MENTIRA, y estuvo dicha varios días: que la caja
            // seguía trabajando y que al volver recogeríamos la respuesta. **No es
            // verdad con este transporte.** Medido contra la caja de verdad el
            // 2026-09-10: se manda un turno, se corta el socket a los 3 s, se espera 25 s
            // y `session/load` devuelve CERO caracteres del agente.
            //
            // La razón está en el relé: la caída del socket del cliente cierra también el
            // socket hacia goose, y en Rust soltar la conexión cancela el futuro que
            // atiende el `session/prompt`. Un turno **es** su socket; cuando el socket
            // muere no queda trabajo huérfano al que volver.
            //
            // Así que el turno se da por PERDIDO y se dice. Una app que promete recuperar
            // algo que ya no existe es peor que una que admite que lo perdió: enseña a no
            // creerle. Esto cambia el día que el turno sea del servidor —ahí sí sobrevive
            // sin nosotros—, y ese día vuelve el texto de «sigue trabajando».
            EasyBitsClient.diag("[turno] \(sid) murió: \(error)")
            let corte = !Task.isCancelled
                && Self.esCorteDeTransporte(error, seFueAlFondo: hilo.huboFondo)
            hilo.interrumpido = false
            hilo.fallo = Task.isCancelled ? nil
                : corte ? "Se cortó la conexión y el turno se perdió. Vuelve a pedírselo."
                        : "Se cortó a media respuesta"
            // Lo que escribiste se guarda para poder reintentarlo de un toque: volver a
            // teclearlo es trabajo que la app puede ahorrarte, y en una nota de voz ni
            // siquiera se puede.
            if corte { hilo.paraReintentar = texto }
            // ⚠️ En el camino del corte NO se escribe el aviso DENTRO del mensaje. Ese
            // texto se guardaba en el hilo y sobrevivía a la recogida: quedaba un «se
            // cortó la conexión» pegado para siempre en mitad de una conversación que
            // había terminado bien. Ahora lo dice un cartel atado a `interrumpido`, que
            // desaparece solo en cuanto se recoge la respuesta. El parcial sí se conserva.
            if corte && acumulado.isEmpty {
                // Nada que enseñar todavía: se quita el «escribiendo…» y ya. Una burbuja
                // vacía se lee como que el agente contestó con silencio.
                hilo.mensajes.removeAll { $0.kind == .typing }
            } else {
                pintarRespuesta(hilo, id: respuesta,
                                texto: corte ? acumulado
                                             : Self.mensajeDeFallo(error, parcial: acumulado))
            }
            anotar(canal, hilo, chars: acumulado.count, como: Task.isCancelled ? .stopped : .failed)
        }
        cerrarTurno(canal, hilo)
    }

    /// Vuelve a mandar el turno que se perdió al cortarse la conexión.
    func reintentar() async {
        guard let canal = canalActivo, let hilo = canal.hilo,
              let texto = hilo.paraReintentar else { return }
        hilo.paraReintentar = nil
        hilo.fallo = nil
        await send(texto, a: canal.cuenta.id)
    }

    func stopTurn() async {
        guard let canal = canalActivo, let hilo = canal.hilo else { return }
        detener(canal, hilo)
    }

    /// Detiene UN turno. La flota la usa para parar sin ir a la conversación.
    ///
    /// ⚠️ Cancelar aquí no bastaba: sin `session/cancel` el agente seguía trabajando —y
    /// cobrando— hasta terminar. Ahora se le dice a la caja. Ver `ACPClient.cancelar`.
    func detener(_ canal: Canal, _ hilo: Hilo) {
        hilo.enVuelo?.cancel()
        if let sid = hilo.sesionID { Task { [acp = canal.acp] in await acp?.cancelar(sid) } }
        cerrarTurno(canal, hilo, avisar: false)
        hilo.mensajes.removeAll { $0.kind == .typing }
    }

    /// Para TODO lo que un agente tenga en marcha.
    func detenerTodo(_ canal: Canal) {
        for h in canal.enCurso { detener(canal, h) }
    }

    func decide(_ request: PermissionRequest, _ decision: PermissionDecision) async {
        // El permiso puede ser de CUALQUIER canal: uno pide permiso mientras miras a
        // otro, y contestarle desde la flota tiene que llegar a su turno detenido.
        guard let (canal, hilo) = canales.values.compactMap({ c -> (Canal, Hilo)? in
            guard let h = c.hilos.first(where: { $0.permisoPendiente?.id == request.id })
            else { return nil }
            return (c, h)
        }).first else { return }

        // Si viene de la caja, hay que contestarle: el turno está detenido esperando.
        if let p = hilo.permisoACP, "\(p.id)" == request.id, let cliente = canal.acp {
            let opcion = Self.elegirOpcion(decision, entre: p.opciones)
            do {
                try await cliente.responderPermiso(p.id, opcion: opcion)
            } catch {
                // ⚠️ Era un `try?` seguido de borrar la petición, y ése es el peor fallo
                // mudo posible aquí: la pantalla daba el permiso por contestado y el turno
                // del agente se quedaba detenido AL OTRO LADO, para siempre y sin forma de
                // reintentar. Si no llegó, la pregunta se queda en pantalla.
                canal.estadoHilos = .fallo("No pude contestarle a tu agente. Inténtalo otra vez.")
                return
            }
            hilo.permisoACP = nil
        }
        hilo.permisoPendiente = nil
        refrescarEstado(canal)
        permissionHistory.insert(
            PermissionRecord(id: request.id,
                             icon: request.kind == .email ? .document : .cart,
                             title: request.question, detail: request.detail,
                             outcome: etiqueta(decision)), at: 0)
    }

    func respondToPR(_ card: PullRequestCard, approve: Bool) async {
        await send(approve ? "Aprueba el \(card.reference)."
                           : "Pide cambios en el \(card.reference) y deja el comentario en la línea del bloqueante.")
    }

    /// Cierra la bitácora del turno. El tiempo sale del cronómetro que ya corría;
    /// los tokens, del evento `usage` que manda la caja.
    private func anotar(_ canal: Canal, _ hilo: Hilo, chars: Int, como: TurnRecord.Outcome) {
        let inicio = hilo.inicio ?? Date()
        bitacora.registrar(TurnRecord(
            id: UUID().uuidString,
            agentID: canal.cuenta.id,
            agentName: canal.cuenta.name,
            prompt: hilo.prompt,
            startedAt: inicio,
            seconds: max(0, Int(Date().timeIntervalSince(inicio))),
            inputTokens: hilo.uso.entrada,
            outputTokens: hilo.uso.salida,
            outcome: como,
            replyChars: chars))
    }

    /// Traduce nuestra decisión al `optionId` que ofreció el agente. Los nombres
    /// los pone él, así que se buscan por forma en vez de asumir un catálogo fijo.
    private static func elegirOpcion(_ d: PermissionDecision,
                                     entre opciones: [(id: String, nombre: String, tipo: String)]) -> String {
        func buscar(_ agujas: [String]) -> String? {
            for a in agujas {
                if let o = opciones.first(where: { $0.tipo.lowercased().contains(a) || $0.id.lowercased().contains(a) }) {
                    return o.id
                }
            }
            return nil
        }
        switch d {
        case .allowOnce:    return buscar(["allow_once", "once", "allow"]) ?? opciones.first?.id ?? "allow"
        case .allowForTask: return buscar(["allow_always", "always", "session", "allow"]) ?? opciones.first?.id ?? "allow"
        case .deny:         return buscar(["reject", "deny", "cancel"]) ?? opciones.last?.id ?? "reject"
        }
    }

    // MARK: - Fallos de red

    /// Cortes del transporte, no del agente. En un teléfono son la vida normal.
    ///
    /// ⚠️ Esta función es la que decide si una conversación se recupera o se da por muerta,
    /// y durante semanas contestó que NO al caso más común de todos. Al bloquear el
    /// teléfono, iOS mata el socket y el error que llega es **`NSPOSIXErrorDomain 53`**
    /// (ECONNABORTED), que **no es un `URLError`**: el `as? URLError` de la primera línea
    /// devolvía `nil`, el turno se marcaba como fallo del agente y `volverDelFondo` —que
    /// sólo mira los hilos `interrumpido`— no volvía a preguntar nunca. El trabajo que la
    /// caja SÍ había terminado se perdía, y la conversación se quedaba diciendo «vuelve a
    /// intentarlo» para siempre.
    ///
    /// `seFueAlFondo` es la evidencia más fuerte que tenemos y por eso vale por sí sola:
    /// si la app pasó por el fondo durante el turno, lo que rompió el socket fue iOS.
    /// Cubre los errores que todavía no conocemos, que es de donde vino este fallo.
    static func esCorteDeTransporte(_ error: Error, seFueAlFondo: Bool = false) -> Bool {
        // Lo paraste tú, o el mensaje no cabía, o hay que volver a entrar: reintentar no
        // arregla ninguna de las tres. Se mira ANTES que `seFueAlFondo`, o un 401 dejaría
        // el hilo reintentando contra una sesión muerta sin decírtelo.
        if esDefinitivo(error) { return false }
        if seFueAlFondo { return true }

        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain {
            // 53 ECONNABORTED —el del teléfono bloqueado—, 54 ECONNRESET, 57 ENOTCONN,
            // 32 EPIPE, 60 ETIMEDOUT, 50/51 red caída. Todos son «el socket se murió por
            // debajo», ninguno es el agente.
            return [53, 54, 57, 32, 60, 50, 51].contains(e.code)
        }
        // Por CÓDIGO y no sólo con `as? URLError`: un error reenvuelto por `URLSession` no
        // siempre castea, y ahí volvíamos a caer en el mismo agujero.
        if e.domain == NSURLErrorDomain {
            return [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                    NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                    NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
                    NSURLErrorSecureConnectionFailed]
                .contains(e.code)
        }
        if let f = error as? ACPClient.Fallo {
            switch f {
            // Sólo sale de `romper(_:)` o de un socket que ya no está. Siempre transporte.
            case .noConectado: return true
            // El reloj de 900 s de un turno largo: la caja sigue en ello. Y SÓLO el del
            // turno — que expire `session/new` o `session/load` sí es un fallo de esa
            // operación, y tratarlo como corte esconde un problema real de la caja.
            case .timeout(let metodo): return metodo == "session/prompt"
            case .remoto, .handshake: return false
            }
        }
        return false
    }

    /// Errores que NO se arreglan volviendo a preguntar.
    private static func esDefinitivo(_ error: Error) -> Bool {
        let e = error as NSError
        // EMSGSIZE: el turno traía algo demasiado grande. Repetirlo lo repite igual.
        if e.domain == NSPOSIXErrorDomain && e.code == 40 { return true }
        if error.localizedDescription.contains("Message too long") { return true }
        // Sesión caducada: hay que volver a entrar, y hay que ENTERARSE.
        let d = error.localizedDescription.lowercased()
        return d.contains("401") || d.contains("403") || d.contains("unauthorized")
    }

    /// «network connection was lost» a secas suena a que el agente falló, y no fue él.
    ///
    /// ⚠️ Aquí vivía la rama de «connection abort» (POSIX 53). Ya no: ese error es el que
    /// deja iOS al suspender la app, así que ahora lo reconoce `esCorteDeTransporte` y
    /// nunca llega hasta aquí. Cuando estaba, decía «vuelve a intentarlo» por un trabajo
    /// que la caja estaba terminando.
    static func mensajeDeFallo(_ error: Error, parcial: String) -> String {
        let detalle: String
        if let u = error as? URLError {
            switch u.code {
            case .networkConnectionLost:
                detalle = "Se cortó la conexión a media respuesta. El agente sí recibió el mensaje."
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                detalle = "No pude alcanzar a tu agente. Puede que su caja esté despertando; vuelve a intentarlo."
            case .notConnectedToInternet: detalle = "El teléfono no tiene internet."
            case .timedOut: detalle = "El turno tardó más de lo que aguanta la conexión."
            default: detalle = u.localizedDescription
            }
        } else if (error as NSError).code == 40 || error.localizedDescription.contains("Message too long") {
            // ⚠️ POSIX 40 = EMSGSIZE. Salía tal cual, en inglés y sin decir de qué mensaje
            // hablaba. Ver el tope del socket en `ACPClient.conectar`.
            detalle = "Ese turno traía un mensaje demasiado grande para la conexión."
        } else {
            detalle = error.localizedDescription
        }
        return parcial.isEmpty ? "⚠️ \(detalle)" : parcial + "\n\n⚠️ \(detalle)"
    }

    // MARK: - Interno

    private func pintarRespuesta(_ hilo: Hilo, id: String, texto: String,
                                 herramientas: [Herramienta] = []) {
        hilo.mensajes.removeAll { $0.kind == .typing }
        let tools: ToolRun? = herramientas.isEmpty ? nil : ToolRun(herramientas: herramientas)
        let nuevo = Message(id: id, kind: .agent(text: texto, tools: tools, trailing: nil))
        if let i = hilo.mensajes.firstIndex(where: { $0.id == id }) { hilo.mensajes[i] = nuevo }
        else { hilo.mensajes.append(nuevo) }
    }

    /// `avisar` es lo que distingue un turno que ACABÓ de uno que paraste tú o que
    /// tiraste al abrir conversación nueva. Sin esta distinción, detener a un agente
    /// desde la flota te mandaba una notificación diciendo que había terminado.
    private func cerrarTurno(_ canal: Canal, _ hilo: Hilo, avisar: Bool = true) {
        // ⚠️ Un turno que se cortó NO terminó, y esta función corre igual por ese camino:
        // marcaba «contestó», sonaba la burbuja y mandaba un aviso diciendo que el agente
        // había acabado, justo cuando lo que había pasado era que bloqueaste el teléfono.
        // El reloj sí se limpia —el turno local ya no existe—, pero la conversación queda
        // pendiente hasta que se recoja de verdad.
        let hubo = hilo.turno != nil && !hilo.interrumpido
        hilo.cronometro?.cancel(); hilo.cronometro = nil
        hilo.turno = nil; hilo.inicio = nil
        if hubo {
            hilo.termino = Date()
            // Visto sólo si lo estabas mirando de verdad. Si no, la conversación queda
            // marcada como "contestó" hasta que entres, y suena.
            hilo.visto = hilo.clave == hiloActivo?.clave && !Avisos.enElFondo
            if !hilo.visto { Avisos.sonarFin() }
        }
        refrescarEstado(canal)
        // El turno acabó: es el momento en que la conversación está completa y vale la
        // pena escribirla. Guardar en cada trozo del streaming sería escribir el archivo
        // decenas de veces por respuesta.
        guardarHilos(canal)
        // Sólo si NO lo estabas mirando. Avisar de algo que acabas de ver aparecer en
        // pantalla es ruido.
        // ⚠️ Por HILO, no por agente: con tres conversaciones del agente que miras, dos
        // podían terminar sin avisarte de ninguna sólo porque el agente era el activo.
        if avisar, hubo, hilo.clave != hiloActivo?.clave || Avisos.enElFondo {
            Avisos.avisar(titulo: "\(canal.cuenta.name) terminó",
                          cuerpo: hilo.prompt.isEmpty ? "Tu agente acabó el turno." : hilo.prompt,
                          agentID: canal.cuenta.id)
            sinVer.insert(canal.cuenta.id)
        }
        // ⚠️ La caja NO guarda un hilo hasta que tiene mensajes: `session/new` no
        // aparece en `session/list` hasta el primer turno. Por eso la lista se
        // refresca al cerrar, o un hilo recién creado no se vería nunca.
        Task { [weak canal] in
            guard let canal, let cliente = canal.acp else { return }
            if let frescos = try? await cliente.sesiones() { canal.hilosRemotos = frescos }
        }
    }

    /// El cronómetro corre en el cliente porque la caja no manda progreso por paso:
    /// el contrato sólo trae `chunk` · `usage` · `done`. Mejor un reloj honesto que
    /// una barra inventada.
    private func arrancarCronometro(_ hilo: Hilo, titulo: String) {
        hilo.inicio = Date()
        hilo.turno = TurnActivity(id: UUID().uuidString, title: titulo,
                                  detail: "Pensando…", step: 0, totalSteps: 0, elapsed: "0:00")
        hilo.cronometro?.cancel()
        hilo.cronometro = Task { [weak hilo] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let hilo, let inicio = hilo.inicio else { return }
                let s = Int(Date().timeIntervalSince(inicio))
                hilo.turno?.elapsed = String(format: "%d:%02d", s / 60, s % 60)
                // ⚠️ Sin esto el estado se queda congelado en «Pensando…» cuando la caja
                // no manda herramientas, y un turno de tres minutos diciendo siempre lo
                // mismo se lee como colgado. NO inventa progreso —no hay pasos que
                // contar—: dice la única verdad que tenemos, cuánto lleva, y a partir de
                // un rato que se puede detener.
                if hilo.sinHerramientas { hilo.turno?.detail = Self.comoVa(s) }
            }
        }
    }

    /// Qué decir de un turno del que sólo sabemos cuánto lleva.
    static func comoVa(_ segundos: Int) -> String {
        switch segundos {
        case ..<6:   return "Pensando…"
        case ..<15:  return "Trabajando…"
        case ..<30:  return "Sigue en ello…"
        case ..<60:  return "Esto lleva un poco…"
        case ..<120: return "Sigue trabajando…"
        case ..<300: return "Lleva un buen rato…"
        default:     return "Muy largo — puedes detenerlo"
        }
    }

    private func primeraFrase(_ t: String) -> String {
        let c = t.prefix(60)
        return c.count < t.count ? c + "…" : String(c)
    }

    private func etiqueta(_ d: PermissionDecision) -> String {
        switch d {
        case .allowOnce: return "Permitido esta vez · ahora"
        case .allowForTask: return "Permitido para esa tarea · ahora"
        case .deny: return "Rechazado · ahora"
        }
    }
}
