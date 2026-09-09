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
    var messages: [Message] = []
    var currentTurn: TurnActivity?
    var log: [LogEntry] = []
    var pendingPermission: PermissionRequest?
    var permissionHistory: [PermissionRecord] = []
    var artifacts: [Artifact] = []
    var deliveredToday: [Artifact] = []

    enum Conexion: Equatable {
        case cargando, lista, sinLlave
        case fallo(String)
    }
    var conexion: Conexion = .cargando
    var ultimoUso: (entrada: Int, salida: Int)?

    /// Un hilo por agente: cambiar de agente no debe mezclar conversaciones.
    private var hilos: [String: [Message]] = [:]
    private var sesiones: [String: String] = [:]
    private var cuentas: [AgentAccount] = []
    let bitacora = TurnLogStore()
    /// Lo que el agente ha entregado por este teléfono. Ver `Entregas.swift`.
    let entregas = EntregasStore()

    /// ¿Se cayó el último envío ANTES de llegar al agente?
    ///
    /// Sólo lo enciende un fallo de subida, no un turno que reventó a medias: el
    /// compositor lo usa para devolverle sus adjuntos a la persona, y devolvérselos
    /// después de que el agente ya los recibió sería duplicarlos.
    private(set) var ultimoEnvioFallo = false
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
    var hilosRemotos: [ACPClient.Session] = []
    enum EstadoHilos: Equatable { case sinPedir, cargando, listo, fallo(String) }
    var estadoHilos: EstadoHilos = .sinPedir
    var infoDeLaCaja: String?
    /// El permiso que el agente está esperando, con el id JSON-RPC para contestarlo.
    var permisoACP: ACPClient.Permiso?
    /// Qué hilo remoto se está mirando, para marcarlo en la lista.
    var hiloAbierto: String?
    /// Qué transporte llevó el último turno, para poder decirlo en pantalla.
    var porSocket = false
    private var acp: ACPClient?
    private var modoDeSesion: [String: String] = [:]
    /// La creación de hilo en vuelo. Sin esto, escribir rápido después de tocar
    /// "Nueva conversación" mandaba el turno sin sesión y caía en el hilo viejo.
    private var creandoHilo: Task<String, Error>?
    private var turnoEnVuelo: Task<Void, Never>?
    private var promptDelTurno = ""
    private var usoDelTurno = (entrada: 0, salida: 0)
    private var inicioDelTurno: Date?
    private var cronometro: Task<Void, Never>?

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
        messages = hilos[selectedAgentID] ?? []
        conexion = .lista
    }

    /// Cierra sesión: revoca en el servidor, borra el llavero y vuelve al login.
    func cerrarSesion() async {
        await Session.cerrarSesion()
        cuentas = []
        agents = []
        messages = []
        hilos = [:]
        sesiones = [:]
        hilosRemotos = []
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

    /// Cambia de agente conservando cada hilo por separado.
    func seleccionar(_ id: String) {
        guard id != selectedAgentID, cuentas.contains(where: { $0.id == id }) else { return }
        hilos[selectedAgentID] = messages
        Credentials.activar(id)
        selectedAgentID = id
        messages = hilos[id] ?? []
        currentTurn = nil
        // El socket es por agente: cambiar de agente lo suelta.
        Task { [acp] in await acp?.cerrar() }
        acp = nil
        infoDeLaCaja = nil
        hilosRemotos = []
        estadoHilos = .sinPedir
        hiloAbierto = nil
    }

    /// Empieza de cero con este agente. Suelta el `sessionId`, así que la caja abre
    /// un hilo nuevo y no arrastra el contexto anterior.
    /// Empieza un hilo NUEVO en la caja.
    ///
    /// ⚠️ Por HTTP esto era imposible y por eso apendaba: EasyBits siempre usa la
    /// única sesión ACP del agente. Sólo `session/new` por WebSocket crea un hilo.
    func nuevaConversacion() {
        turnoEnVuelo?.cancel()
        cronometro?.cancel()
        currentTurn = nil
        messages = []
        hilos[selectedAgentID] = []
        hiloAbierto = nil
        sesiones[selectedAgentID] = nil

        guard let cuenta = cuentas.first(where: { $0.id == selectedAgentID }) else { return }
        creandoHilo = nil
        Task {
            do {
                _ = try await asegurarHilo(cuenta)
                if let cliente = acp { hilosRemotos = try await cliente.sesiones() }
            } catch {
                estadoHilos = .fallo(error.localizedDescription)
            }
        }
    }

    /// Cambia entre aprobar solo y pedir permiso.
    func fijarModo(_ modo: String) async {
        guard let cuenta = cuentas.first(where: { $0.id == selectedAgentID }),
              let sid = sesiones[cuenta.id] else { return }
        do {
            let cliente = try await asegurarSocket(cuenta)
            try await cliente.fijarModo(modo, sessionID: sid)
            modoDeSesion[sid] = modo
        } catch {
            EasyBitsClient.diag("no pude fijar el modo: \(error)")
        }
    }

    var modoActual: String {
        guard let sid = sesiones[selectedAgentID] else { return "auto" }
        return modoDeSesion[sid] ?? "auto"
    }

    func quitarAgente(_ id: String) {
        Credentials.quitar(id)
        hilos[id] = nil
        sesiones[id] = nil
        Task { await cargar() }
    }

    // MARK: - Hilos de la caja (WebSocket ACP)

    /// El WebSocket convive con el HTTP en vez de reemplazarlo: el turno sigue yendo
    /// por HTTP porque ése **despierta la caja**, y esto sirve para lo que HTTP no
    /// puede — listar y cargar hilos.
    /// Asegura socket abierto. Si la caja está dormida el WebSocket falla, así que se
    /// la despierta con un turno HTTP mínimo —lo único que sabe despertarla— y se
    /// reintenta.
    private func asegurarSocket(_ cuenta: AgentAccount) async throws -> ACPClient {
        if let c = acp, infoDeLaCaja != nil { return c }
        let c = ACPClient(agentID: cuenta.id, token: cuenta.token, host: cuenta.host)
        do {
            infoDeLaCaja = try await c.conectar()
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
                infoDeLaCaja = try await c.conectar()
            } else {
                // ⚠️ Despertar con un turno HTTP de "ping" APENDABA al hilo por defecto
                // del agente. `/revive` levanta la caja sin tocar la conversación.
                try await EasyBitsClient(apiKey: cuenta.token).revive(agentID: cuenta.id)
                infoDeLaCaja = try await c.conectar()
            }
        }
        acp = c
        await c.alPedirPermiso { [weak self] p in
            Task { @MainActor in self?.recibirPermiso(p) }
        }
        return c
    }

    /// Devuelve el hilo activo, creándolo si hace falta.
    ///
    /// ⚠️ Esto existe porque **al abrir la app no había ninguna sesión**, así que el
    /// primer turno se iba por HTTP — y por HTTP EasyBits siempre habla con la única
    /// sesión ACP del agente, o sea que caía en el hilo viejo. Sin sesión no se manda
    /// nada por HTTP.
    private func asegurarHilo(_ cuenta: AgentAccount) async throws -> String {
        if let sid = sesiones[cuenta.id] { return sid }
        if let enVuelo = creandoHilo { return try await enVuelo.value }

        let tarea = Task<String, Error> {
            let cliente = try await asegurarSocket(cuenta)
            let (id, modos) = try await cliente.nuevaSesion()
            sesiones[cuenta.id] = id
            hiloAbierto = id
            modoDeSesion[id] = modos?.actual ?? "auto"
            return id
        }
        creandoHilo = tarea
        defer { creandoHilo = nil }
        return try await tarea.value
    }

    /// El agente pidió permiso. El turno está detenido hasta que se conteste.
    private func recibirPermiso(_ p: ACPClient.Permiso) {
        permisoACP = p
        pendingPermission = PermissionRequest(
            id: "\(p.id)",
            kind: .publish,
            agentName: selectedAgent?.name ?? "El agente",
            question: "¿Dejas que use \(p.titulo)?",
            detail: p.opciones.isEmpty
                ? "El agente espera tu respuesta para seguir."
                : "El turno está detenido hasta que contestes.",
            attachment: nil)
    }

    func cargarHilos() async {
        guard let cuenta = cuentas.first(where: { $0.id == selectedAgentID }) else { return }
        guard estadoHilos != .cargando else { return }
        estadoHilos = .cargando

        do {
            let cliente = try await asegurarSocket(cuenta)
            hilosRemotos = try await cliente.sesiones()
            estadoHilos = .listo
        } catch {
            estadoHilos = .fallo(error.localizedDescription)
            acp = nil; infoDeLaCaja = nil
        }
    }

    /// Abre un hilo de la caja en la conversación. Lo que se pinta es el replay que
    /// manda `session/load`, no algo guardado aquí.
    func abrirHilo(_ hilo: ACPClient.Session) async {
        guard let cuenta = cuentas.first(where: { $0.id == selectedAgentID }) else { return }
        do {
            let cliente = try await asegurarSocket(cuenta)
            let replay = try await cliente.cargar(hilo.id, cwd: hilo.cwd)
            messages = ReplayToMessages.convertir(replay)
            // El título sale del primer mensaje del hilo, que es lo que hacen
            // ChatGPT, Claude y la propia interfaz de goose. Sale gratis: el replay
            // ya está aquí.
            if let primero = messages.first(where: { if case .user = $0.kind { return true } else { return false } }),
               case .user(let t) = primero.kind {
                titulos.anotarSiFalta(hilo.id, desde: t)
            }
            hilos[selectedAgentID] = messages
            // El turno siguiente continúa ESE hilo, no uno nuevo.
            sesiones[selectedAgentID] = hilo.id
            hiloAbierto = hilo.id
        } catch {
            estadoHilos = .fallo(error.localizedDescription)
        }
    }

    // MARK: - AgentStoring

    /// ⚠️ El del protocolo `AgentStoring`, explícito y no por valor por defecto: Swift NO
    /// da por cumplido un requisito con un parámetro que tiene default, y el error que da
    /// («no conforma») no menciona el método.
    func send(_ text: String) async { await send(text, adjuntos: []) }

    func send(_ text: String, adjuntos: [Adjunto] = []) async {
        let limpio = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty || !adjuntos.isEmpty,
              let cuenta = cuentas.first(where: { $0.id == selectedAgentID })
        else { return }

        turnoEnVuelo?.cancel()
        messages.removeAll { $0.kind == .typing }
        // Lo que se pinta lleva los adjuntos: mandar sólo una foto dejaría una burbuja
        // vacía y parecería que el mensaje no salió.
        //
        // ⚠️ SIN emoji. El 📎 salía como un cuadro con interrogación: la burbuja se pinta
        // con el renderizador de Markdown y su fuente no lo tiene. Un nombre entre backticks
        // se lee igual de bien y no depende de qué glifos traiga la tipografía.
        let visible = adjuntos.isEmpty
            ? limpio
            : ([limpio.isEmpty ? nil : limpio]
                .compactMap { $0 } + adjuntos.map { "`\($0.nombre)`" }).joined(separator: "\n")
        messages.append(Message(id: UUID().uuidString, kind: .user(visible)))
        let idRespuesta = UUID().uuidString
        messages.append(Message(id: "typing", kind: .typing))

        marcarTrabajando(cuenta.id, tarea: "Trabajando…")
        arrancarCronometro(titulo: primeraFrase(limpio))
        promptDelTurno = limpio
        usoDelTurno = (0, 0)

        turnoEnVuelo = Task { [weak self] in
            guard let self else { return }
            do {
                // El turno va SIEMPRE por el socket: es el único que respeta el hilo.
                // Por HTTP EasyBits habla con la única sesión ACP del agente, así que
                // cualquier turno por ahí acaba en la conversación equivocada.
                let sid = try await self.asegurarHilo(cuenta)
                self.titulos.anotarSiFalta(sid, desde: limpio)
                // Lo que no es imagen se SUBE a la máquina del agente y se le dice la ruta.
                // Si falla, el turno no sale: mandarlo dejaría al agente buscando un archivo
                // que no existe, y desde fuera eso se lee como que el agente miente.
                let texto = try await self.conAdjuntos(limpio, adjuntos)
                self.ultimoEnvioFallo = false
                await self.porSocket(cuenta, sid: sid, texto: texto,
                                     imagenes: adjuntos.filter(\.esImagen),
                                     respuesta: idRespuesta)
            } catch {
                // Si el socket no se puede ni levantando la caja, se dice. Mandarlo
                // por HTTP en silencio lo metería en otro hilo, que es peor que fallar.
                // Un fallo aquí es "no llegó a salir": o no se pudo abrir la conversación,
                // o no se pudo subir un adjunto. En los dos casos el agente no vio nada, y
                // el compositor tiene que poder devolverle su trabajo a la persona.
                self.ultimoEnvioFallo = true
                self.pintarRespuesta(
                    id: idRespuesta,
                    texto: "⚠️ \(error.localizedDescription)")
                self.anotar(cuenta, chars: 0, como: .failed)
                self.cerrarTurno(cuenta.id)
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
    private func conAdjuntos(_ texto: String, _ adjuntos: [Adjunto]) async throws -> String {
        let archivos = adjuntos.filter { !$0.esImagen }
        guard !archivos.isEmpty, let cliente = acp else { return texto }
        var rutas: [String] = []
        for a in archivos { rutas.append(try await cliente.subir(a)) }
        let linea = rutas.count == 1
            ? "Te adjunté el archivo `\(rutas[0])`."
            : "Te adjunté estos archivos: " + rutas.map { "`\($0)`" }.joined(separator: ", ") + "."
        return texto.isEmpty ? linea : "\(linea)\n\n\(texto)"
    }

    private func porSocket(_ cuenta: AgentAccount, sid: String,
                           texto: String, imagenes: [Adjunto] = [],
                           respuesta: String) async {
        guard let cliente = acp else {
            pintarRespuesta(id: respuesta, texto: "⚠️ Se perdió la conexión con tu agente.")
            cerrarTurno(cuenta.id)
            return
        }
        var acumulado = ""
        var herramientas: [(id: String, titulo: String)] = []

        do {
            for try await evento in cliente.prompt(sessionID: sid, texto: texto, imagenes: imagenes) {
                switch evento {
                case .agent(let t):
                    acumulado += t
                    pintarRespuesta(id: respuesta, texto: acumulado, herramientas: herramientas)
                case .toolCall(let id, let titulo):
                    // "Corrió N herramientas" con datos de verdad, y EN VIVO.
                    if !herramientas.contains(where: { $0.id == id }) {
                        herramientas.append((id, titulo))
                        pintarRespuesta(id: respuesta, texto: acumulado, herramientas: herramientas)
                    }
                case .usage(let entrada, let salida):
                    usoDelTurno = (entrada, salida)
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
                        messages.append(Message(id: "entrega-\(e.id)", kind: .entrega(e)))
                    }
                case .user, .thought, .toolDone:
                    break
                }
            }
            if acumulado.isEmpty && herramientas.isEmpty {
                pintarRespuesta(id: respuesta, texto: "_El turno cerró sin texto._")
            }
            anotar(cuenta, chars: acumulado.count, como: .done)
        } catch {
            pintarRespuesta(id: respuesta, texto: Self.mensajeDeFallo(error, parcial: acumulado))
            anotar(cuenta, chars: acumulado.count, como: Task.isCancelled ? .stopped : .failed)
        }
        cerrarTurno(cuenta.id)
    }

    func stopTurn() async {
        turnoEnVuelo?.cancel()
        cerrarTurno(selectedAgentID)
        messages.removeAll { $0.kind == .typing }
    }

    func decide(_ request: PermissionRequest, _ decision: PermissionDecision) async {
        guard pendingPermission?.id == request.id else { return }

        // Si viene de la caja, hay que contestarle: el turno está detenido esperando.
        if let p = permisoACP, "\(p.id)" == request.id, let cliente = acp {
            let opcion = Self.elegirOpcion(decision, entre: p.opciones)
            try? await cliente.responderPermiso(p.id, opcion: opcion)
            permisoACP = nil
        }
        pendingPermission = nil
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
    private func anotar(_ cuenta: AgentAccount, chars: Int, como: TurnRecord.Outcome) {
        let inicio = inicioDelTurno ?? Date()
        bitacora.registrar(TurnRecord(
            id: UUID().uuidString,
            agentID: cuenta.id,
            agentName: cuenta.name,
            prompt: promptDelTurno,
            startedAt: inicio,
            seconds: max(0, Int(Date().timeIntervalSince(inicio))),
            inputTokens: usoDelTurno.entrada,
            outputTokens: usoDelTurno.salida,
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

    private func pintarRespuesta(id: String, texto: String,
                                 herramientas: [(id: String, titulo: String)] = []) {
        messages.removeAll { $0.kind == .typing }
        let tools: ToolRun? = herramientas.isEmpty ? nil : ToolRun(
            count: herramientas.count,
            summary: herramientas
                .map { $0.titulo.components(separatedBy: " · ").first ?? $0.titulo }
                .reduce(into: [String]()) { acc, t in if !acc.contains(t) { acc.append(t) } }
                .joined(separator: " · "))
        let nuevo = Message(id: id, kind: .agent(text: texto, tools: tools, trailing: nil))
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i] = nuevo }
        else { messages.append(nuevo) }
    }

    private func marcarTrabajando(_ id: String, tarea: String) {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[i].status = .working(task: tarea)
    }

    private func cerrarTurno(_ id: String) {
        cronometro?.cancel(); cronometro = nil
        currentTurn = nil; inicioDelTurno = nil
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].status = .idle(since: "ahora")
        }
        // ⚠️ La caja NO guarda un hilo hasta que tiene mensajes: `session/new` no
        // aparece en `session/list` hasta el primer turno. Por eso la lista se
        // refresca al cerrar, o un hilo recién creado no se vería nunca.
        Task { [weak self] in
            guard let self, let cliente = self.acp else { return }
            if let frescos = try? await cliente.sesiones() { self.hilosRemotos = frescos }
        }
    }

    /// El cronómetro corre en el cliente porque la caja no manda progreso por paso:
    /// el contrato sólo trae `chunk` · `usage` · `done`. Mejor un reloj honesto que
    /// una barra inventada.
    private func arrancarCronometro(titulo: String) {
        inicioDelTurno = Date()
        currentTurn = TurnActivity(id: UUID().uuidString, title: titulo,
                                   detail: "Pensando…", step: 0, totalSteps: 0, elapsed: "0:00")
        cronometro?.cancel()
        cronometro = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let inicio = self.inicioDelTurno else { return }
                let s = Int(Date().timeIntervalSince(inicio))
                self.currentTurn?.elapsed = String(format: "%d:%02d", s / 60, s % 60)
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
