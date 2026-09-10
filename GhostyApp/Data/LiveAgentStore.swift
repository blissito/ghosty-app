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
    private var cuentas: [AgentAccount] = []

    var canalActivo: Canal? { canales[selectedAgentID] }

    /// Agentes con algo que no has visto: terminaron o piden permiso mientras mirabas
    /// otra cosa. Es lo que enciende el punto de la pestaña Flota.
    private(set) var sinVer: Set<String> = []

    var hayPendientes: Bool { !sinVer.isEmpty }

    func visto(_ id: String) { sinVer.remove(id) }
    func vistoTodo() { sinVer.removeAll() }

    /// Los que están trabajando ahora mismo, en el orden de la flota. Es lo que pinta
    /// la barra de "trabajando en segundo plano".
    var trabajando: [Canal] { agents.compactMap { canales[$0.id] }.filter(\.trabajando) }

    // MARK: - Fachada del canal activo
    //
    // Las vistas siguen hablando de "la conversación" y "el turno" en singular: lo que
    // cambió es que ahora eso es SIEMPRE el canal seleccionado, no un estado global.

    var messages: [Message] {
        get { canalActivo?.mensajes ?? [] }
        set { canalActivo?.mensajes = newValue }
    }
    var currentTurn: TurnActivity? {
        get { canalActivo?.turno }
        set { canalActivo?.turno = newValue }
    }
    var pendingPermission: PermissionRequest? {
        get { canalActivo?.permisoPendiente }
        set { canalActivo?.permisoPendiente = newValue }
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
    var hiloAbierto: String? { canalActivo?.hiloAbierto }
    var permisoACP: ACPClient.Permiso? { canalActivo?.permisoACP }
    let bitacora = TurnLogStore()
    /// Las conversaciones guardadas en el teléfono. Ver `CacheDeHilos.swift`.
    let cache = CacheDeHilos()
    /// Lo que el agente ha entregado por este teléfono. Ver `Entregas.swift`.
    let entregas = EntregasStore()

    /// ¿Se cayó el último envío ANTES de llegar al agente?
    ///
    /// Sólo lo enciende un fallo de subida, no un turno que reventó a medias: el
    /// compositor lo usa para devolverle sus adjuntos a la persona, y devolvérselos
    /// después de que el agente ya los recibió sería duplicarlos.
    private(set) var ultimoEnvioFallo = false

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
            if let (sid, mensajes) = cache.abierto(c.id) {
                canal.mensajes = mensajes
                canal.sesionID = sid
                canal.hiloAbierto = sid
            }
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
    func nuevaConversacion() {
        guard let canal = canalActivo else { return }
        canal.enVuelo?.cancel()
        // ⚠️ Por `cerrarTurno` y no a mano: puesto a mano se quedaba sin apagar
        // `agents[i].status`, así que un agente al que le abrías conversación nueva a
        // media respuesta seguía diciendo "trabajando" para siempre en la flota.
        cerrarTurno(canal, avisar: false)
        canal.mensajes = []
        canal.hiloAbierto = nil
        canal.sesionID = nil
        canal.creandoHilo = nil
        cache.guardarAbierto([], hilo: nil, de: canal.cuenta.id)
        Task {
            do {
                _ = try await asegurarHilo(canal)
                if let cliente = canal.acp { canal.hilosRemotos = try await cliente.sesiones() }
            } catch {
                canal.estadoHilos = .fallo(error.localizedDescription)
            }
        }
    }

    /// Cambia entre aprobar solo y pedir permiso.
    func fijarModo(_ modo: String) async {
        guard let canal = canalActivo, let sid = canal.sesionID else { return }
        do {
            let cliente = try await asegurarSocket(canal)
            try await cliente.fijarModo(modo, sessionID: sid)
            canal.modo = modo
        } catch {
            EasyBitsClient.diag("no pude fijar el modo: \(error)")
        }
    }

    var modoActual: String { canalActivo?.modo ?? "auto" }

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
        let cuenta = canal.cuenta
        if let c = canal.acp, canal.infoDeLaCaja != nil { return c }
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
        return c
    }

    /// Devuelve el hilo activo, creándolo si hace falta.
    ///
    /// ⚠️ Esto existe porque **al abrir la app no había ninguna sesión**, así que el
    /// primer turno se iba por HTTP — y por HTTP EasyBits siempre habla con la única
    /// sesión ACP del agente, o sea que caía en el hilo viejo. Sin sesión no se manda
    /// nada por HTTP.
    private func asegurarHilo(_ canal: Canal) async throws -> String {
        if let sid = canal.sesionID { return sid }
        if let enVuelo = canal.creandoHilo { return try await enVuelo.value }

        let tarea = Task<String, Error> {
            let cliente = try await asegurarSocket(canal)
            let (id, modos) = try await cliente.nuevaSesion()
            canal.sesionID = id
            canal.hiloAbierto = id
            canal.modo = modos?.actual ?? "auto"
            return id
        }
        canal.creandoHilo = tarea
        defer { canal.creandoHilo = nil }
        return try await tarea.value
    }

    /// El agente pidió permiso. El turno está detenido hasta que se conteste.
    private func recibirPermiso(_ p: ACPClient.Permiso, en canal: Canal) {
        canal.permisoACP = p
        // ⚠️ El estado del AGENTE, no sólo el del canal. `StatusLine` ya sabe pintar
        // "Espera tu visto bueno" con su punto rojo, y no salía nunca porque el store
        // sólo encendía `.working` e `.idle`.
        if let i = agents.firstIndex(where: { $0.id == canal.cuenta.id }) {
            agents[i].status = .awaitingApproval
        }
        // El más urgente de los dos avisos: este turno está DETENIDO hasta que contestes,
        // así que no enterarte cuesta el trabajo entero.
        if canal.cuenta.id != selectedAgentID || Avisos.enElFondo {
            Avisos.avisar(titulo: "\(canal.cuenta.name) espera tu permiso",
                          cuerpo: "¿Dejas que use \(p.titulo)?",
                          agentID: canal.cuenta.id)
            sinVer.insert(canal.cuenta.id)
        }
        canal.permisoPendiente = PermissionRequest(
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
    func abrirHilo(_ hilo: ACPClient.Session) async {
        guard let canal = canalActivo else { return }
        // Si es el que ya estaba guardado, se pinta YA y el replay lo sustituye cuando
        // llegue. ⚠️ Manda el replay: un caché que gana sobre la caja es un caché que
        // miente, y el hilo puede haber avanzado desde otro cliente.
        if canal.hiloAbierto != hilo.id,
           let (sid, mensajes) = cache.abierto(canal.cuenta.id), sid == hilo.id {
            canal.mensajes = mensajes
            canal.hiloAbierto = hilo.id
        }
        do {
            let cliente = try await asegurarSocket(canal)
            let replay = try await cliente.cargar(hilo.id, cwd: hilo.cwd)
            // Los archivos que se subieron EN esta conversación. Es lo que devuelve a la
            // vida sus adjuntos: el replay de ACP trae sólo texto. Best-effort — si no
            // contesta, el hilo se abre igual y los adjuntos salen nombrados.
            let archivos = await GhostyAPI.archivosDe(sesion: hilo.id)
            let mensajes = ReplayToMessages.convertir(replay, archivos: archivos)
            canal.mensajes = mensajes
            // El título sale del primer mensaje del hilo, que es lo que hacen
            // ChatGPT, Claude y la propia interfaz de goose. Sale gratis: el replay
            // ya está aquí.
            if let primero = mensajes.first(where: { if case .user = $0.kind { return true } else { return false } }),
               case .user(let t, _) = primero.kind {
                titulos.anotarSiFalta(hilo.id, desde: t)
            }
            // El turno siguiente continúa ESE hilo, no uno nuevo.
            canal.sesionID = hilo.id
            canal.hiloAbierto = hilo.id
            cache.guardarAbierto(mensajes, hilo: hilo.id, de: canal.cuenta.id)
        } catch {
            canal.estadoHilos = .fallo(error.localizedDescription)
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
        // Mandarle a OTRO agente es dejarlo trabajando sin mirarlo: es justo el caso que
        // necesita el aviso, y el momento con contexto para pedirlo.
        if cuenta.id != selectedAgentID { Avisos.pedirPermisoSiHaceFalta() }

        // ⚠️ Sólo se cancela el turno de ESTE canal. Antes era un `turnoEnVuelo` único,
        // así que escribirle a un agente cortaba en seco al otro.
        canal.enVuelo?.cancel()
        canal.mensajes.removeAll { $0.kind == .typing }
        // ⚠️ Envuelto en `withAnimation` cuando hay voz: es lo que deja que la barra de
        // grabación y la burbuja se emparejen con `matchedGeometryEffect`. Sin transacción
        // animada, la barra desaparece y la burbuja aparece — dos hechos, no un movimiento.
        let conVoz = adjuntos.contains(where: \.esVoz)
        let mensaje = Message(id: UUID().uuidString, kind: .user(limpio, adjuntos: adjuntos))
        if conVoz {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { canal.mensajes.append(mensaje) }
        } else {
            canal.mensajes.append(mensaje)
        }
        let idRespuesta = UUID().uuidString
        canal.mensajes.append(Message(id: "typing", kind: .typing))

        marcarTrabajando(cuenta.id, tarea: primeraFrase(limpio))
        arrancarCronometro(canal, titulo: primeraFrase(limpio))
        canal.prompt = limpio
        canal.uso = (0, 0)

        canal.enVuelo = Task { [weak self] in
            guard let self else { return }
            do {
                // El turno va SIEMPRE por el socket: es el único que respeta el hilo.
                // Por HTTP EasyBits habla con la única sesión ACP del agente, así que
                // cualquier turno por ahí acaba en la conversación equivocada.
                let sid = try await self.asegurarHilo(canal)
                self.titulos.anotarSiFalta(sid, desde: limpio)
                // Todo adjunto se sube a la cuenta; una imagen viaja ADEMÁS inline, y una
                // nota de voz se transcribe aquí.
                let conArchivos = await self.subidos(adjuntos, sesion: sid)
                self.ultimoEnvioFallo = false
                // La transcripción va en el TEXTO del turno, delante de lo que escribiera
                // la persona: es lo que dijo, no un adjunto que haya que ir a buscar.
                let dicho = conArchivos.compactMap(\.transcripcion)
                    .map(BloqueDeAdjuntos.transcripcion)
                    .joined(separator: "\n\n")
                let conVoz = dicho.isEmpty ? limpio
                    : (limpio.isEmpty ? dicho : "\(dicho)\n\n\(limpio)")
                await self.porSocket(canal, sid: sid, texto: conVoz,
                                     adjuntos: conArchivos,
                                     respuesta: idRespuesta)
            } catch {
                // Si el socket no se puede ni levantando la caja, se dice. Mandarlo
                // por HTTP en silencio lo metería en otro hilo, que es peor que fallar.
                // Un fallo aquí es "no llegó a salir": o no se pudo abrir la conversación,
                // o no se pudo subir un adjunto. En los dos casos el agente no vio nada, y
                // el compositor tiene que poder devolverle su trabajo a la persona.
                self.ultimoEnvioFallo = true
                self.pintarRespuesta(canal, id: idRespuesta,
                                     texto: "⚠️ \(error.localizedDescription)")
                self.anotar(canal, chars: 0, como: .failed)
                self.cerrarTurno(canal)
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

    private func porSocket(_ canal: Canal, sid: String,
                           texto: String, adjuntos: [Adjunto] = [],
                           respuesta: String) async {
        guard let cliente = canal.acp else {
            pintarRespuesta(canal, id: respuesta, texto: "⚠️ Se perdió la conexión con tu agente.")
            cerrarTurno(canal)
            return
        }
        var acumulado = ""
        var herramientas: [Herramienta] = []

        do {
            for try await evento in cliente.prompt(sessionID: sid, texto: texto, adjuntos: adjuntos) {
                switch evento {
                case .agent(let t):
                    acumulado += t
                    pintarRespuesta(canal, id: respuesta, texto: acumulado, herramientas: herramientas)
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
                    if let viva = herramientas.last(where: \.esperando) {
                        canal.turno?.detail = viva.titulo
                    }
                    canal.turno?.step = herramientas.filter { !$0.esperando }.count
                    canal.turno?.totalSteps = herramientas.count
                    pintarRespuesta(canal, id: respuesta, texto: acumulado, herramientas: herramientas)
                case .usage(let entrada, let salida):
                    canal.uso = (entrada, salida)
                case .entrega(let e):
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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        canal.mensajes.append(Message(id: "entrega-\(e.id)", kind: .entrega(e)))
                    }
                case .user, .thought:
                    break
                }
            }
            if acumulado.isEmpty && herramientas.isEmpty {
                pintarRespuesta(canal, id: respuesta, texto: "_El turno cerró sin texto._")
            }
            anotar(canal, chars: acumulado.count, como: .done)
        } catch {
            pintarRespuesta(canal, id: respuesta, texto: Self.mensajeDeFallo(error, parcial: acumulado))
            anotar(canal, chars: acumulado.count, como: Task.isCancelled ? .stopped : .failed)
        }
        cerrarTurno(canal)
    }

    func stopTurn() async { detener(canalActivo) }

    /// Detiene el turno de UN canal. La flota la usa para parar a un agente que dejaste
    /// trabajando sin tener que ir a su conversación.
    func detener(_ canal: Canal?) {
        guard let canal else { return }
        canal.enVuelo?.cancel()
        cerrarTurno(canal, avisar: false)
        canal.mensajes.removeAll { $0.kind == .typing }
    }

    func decide(_ request: PermissionRequest, _ decision: PermissionDecision) async {
        // El permiso puede ser de CUALQUIER canal: uno pide permiso mientras miras a
        // otro, y contestarle desde la flota tiene que llegar a su turno detenido.
        guard let canal = canales.values.first(where: { $0.permisoPendiente?.id == request.id })
        else { return }

        // Si viene de la caja, hay que contestarle: el turno está detenido esperando.
        if let p = canal.permisoACP, "\(p.id)" == request.id, let cliente = canal.acp {
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
            canal.permisoACP = nil
        }
        canal.permisoPendiente = nil
        // El agente vuelve a lo suyo: si el turno sigue vivo, a trabajar.
        if canal.trabajando, let i = agents.firstIndex(where: { $0.id == canal.cuenta.id }) {
            agents[i].status = .working(task: canal.turno?.detail ?? "Trabajando…")
        }
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
    private func anotar(_ canal: Canal, chars: Int, como: TurnRecord.Outcome) {
        let inicio = canal.inicio ?? Date()
        bitacora.registrar(TurnRecord(
            id: UUID().uuidString,
            agentID: canal.cuenta.id,
            agentName: canal.cuenta.name,
            prompt: canal.prompt,
            startedAt: inicio,
            seconds: max(0, Int(Date().timeIntervalSince(inicio))),
            inputTokens: canal.uso.entrada,
            outputTokens: canal.uso.salida,
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
    static func esCorteDeTransporte(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .secureConnectionFailed:
            return true
        default: return false
        }
    }

    /// «network connection was lost» a secas suena a que el agente falló, y no fue él.
    static func mensajeDeFallo(_ error: Error, parcial: String) -> String {
        let detalle: String
        if let u = error as? URLError {
            switch u.code {
            case .networkConnectionLost:
                detalle = "Se cortó la conexión a media respuesta. El agente sí recibió el mensaje."
            case .notConnectedToInternet: detalle = "El teléfono no tiene internet."
            case .timedOut: detalle = "El turno tardó más de lo que aguanta la conexión."
            default: detalle = u.localizedDescription
            }
        } else {
            detalle = error.localizedDescription
        }
        return parcial.isEmpty ? "⚠️ \(detalle)" : parcial + "\n\n⚠️ \(detalle)"
    }

    // MARK: - Interno

    private func pintarRespuesta(_ canal: Canal, id: String, texto: String,
                                 herramientas: [Herramienta] = []) {
        canal.mensajes.removeAll { $0.kind == .typing }
        let tools: ToolRun? = herramientas.isEmpty ? nil : ToolRun(herramientas: herramientas)
        let nuevo = Message(id: id, kind: .agent(text: texto, tools: tools, trailing: nil))
        if let i = canal.mensajes.firstIndex(where: { $0.id == id }) { canal.mensajes[i] = nuevo }
        else { canal.mensajes.append(nuevo) }
    }

    private func marcarTrabajando(_ id: String, tarea: String) {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[i].status = .working(task: tarea)
    }

    /// `avisar` es lo que distingue un turno que ACABÓ de uno que paraste tú o que
    /// tiraste al abrir conversación nueva. Sin esta distinción, detener a un agente
    /// desde la flota te mandaba una notificación diciendo que había terminado.
    private func cerrarTurno(_ canal: Canal, avisar: Bool = true) {
        canal.cronometro?.cancel(); canal.cronometro = nil
        canal.turno = nil; canal.inicio = nil
        // El turno acabó: es el momento en que la conversación está completa y vale la
        // pena escribirla. Guardar en cada trozo del streaming sería escribir el archivo
        // decenas de veces por respuesta.
        cache.guardarAbierto(canal.mensajes, hilo: canal.sesionID, de: canal.cuenta.id)
        // Sólo si NO lo estabas mirando. Avisar de algo que acabas de ver aparecer en
        // pantalla es ruido.
        if avisar, canal.cuenta.id != selectedAgentID || Avisos.enElFondo {
            Avisos.avisar(titulo: "\(canal.cuenta.name) terminó",
                          cuerpo: canal.prompt.isEmpty ? "Tu agente acabó el turno." : canal.prompt,
                          agentID: canal.cuenta.id)
            sinVer.insert(canal.cuenta.id)
        }
        if let i = agents.firstIndex(where: { $0.id == canal.cuenta.id }) {
            agents[i].status = .idle(since: "ahora")
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
    private func arrancarCronometro(_ canal: Canal, titulo: String) {
        canal.inicio = Date()
        canal.turno = TurnActivity(id: UUID().uuidString, title: titulo,
                                   detail: "Pensando…", step: 0, totalSteps: 0, elapsed: "0:00")
        canal.cronometro?.cancel()
        canal.cronometro = Task { [weak canal] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let canal, let inicio = canal.inicio else { return }
                let s = Int(Date().timeIntervalSince(inicio))
                canal.turno?.elapsed = String(format: "%d:%02d", s / 60, s % 60)
            }
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
