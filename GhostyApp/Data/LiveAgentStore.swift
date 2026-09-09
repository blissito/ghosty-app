import Foundation
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
    private var turnoEnVuelo: Task<Void, Never>?
    private var promptDelTurno = ""
    private var usoDelTurno = (entrada: 0, salida: 0)
    private var inicioDelTurno: Date?
    private var cronometro: Task<Void, Never>?

    // MARK: - Carga

    func cargar() async {
        conexion = .cargando
        cuentas = Credentials.accounts
        guard !cuentas.isEmpty else { conexion = .sinLlave; return }

        // Con una llave de cuenta (`eb_sk_…`) sí se puede listar, así que la flota se
        // completa con los agentes encendidos de ese dueño. Con un token de agente
        // (`agt_…`) el API contesta 401 al listar: la lista es lo que haya conectado
        // a mano, y ya.
        for cuenta in cuentas where cuenta.esLlaveDeCuenta {
            let cliente = EasyBitsClient(apiKey: cuenta.token)
            if let remotos = try? await cliente.agents() {
                for r in remotos where r.status == "running" {
                    if !cuentas.contains(where: { $0.id == r.agentId }) {
                        cuentas.append(AgentAccount(id: r.agentId,
                                                    token: cuenta.token,
                                                    name: r.name ?? "agente"))
                    }
                }
            }
        }

        let tonos: [AgentTone] = [.lila, .azul, .durazno]
        agents = cuentas.enumerated().map { i, c in
            Agent(id: c.id, name: c.name, tone: tonos[i % tonos.count],
                  status: .idle(since: "listo"),
                  engine: c.esTokenDeAgente ? "token del agente" : "llave de cuenta")
        }
        selectedAgentID = Credentials.activeID ?? cuentas[0].id
        messages = hilos[selectedAgentID] ?? []
        conexion = .lista
    }

    func recargarCredencial() async { await cargar() }

    /// Trae archivos y documentos. Con un token de agente el API contesta **401**
    /// —sólo deja mandar mensajes—, y eso se dice en pantalla en vez de mostrar una
    /// lista vacía que parece un fallo.
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
        Task {
            do {
                let cliente = try await asegurarSocket(cuenta)
                let (id, modos) = try await cliente.nuevaSesion()
                sesiones[cuenta.id] = id
                hiloAbierto = id
                // `approve` es lo que hace que el agente PIDA permiso; en `auto`
                // aprueba las herramientas solo y nunca llega la petición.
                if modos?.disponibles.contains(where: { $0.id == "approve" }) == true {
                    modoDeSesion[id] = "auto"
                }
                hilosRemotos = try await cliente.sesiones()
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
        let c = ACPClient(agentID: cuenta.id, token: cuenta.token)
        do {
            infoDeLaCaja = try await c.conectar()
        } catch {
            EasyBitsClient.diag("socket falló, despertando por HTTP: \(error)")
            let http = EasyBitsClient(apiKey: cuenta.token)
            for try await _ in http.message(agentID: cuenta.id, content: "ping") { break }
            infoDeLaCaja = try await c.conectar()
        }
        acp = c
        await c.alPedirPermiso { [weak self] p in
            Task { @MainActor in self?.recibirPermiso(p) }
        }
        return c
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
            hilos[selectedAgentID] = messages
            // El turno siguiente continúa ESE hilo, no uno nuevo.
            sesiones[selectedAgentID] = hilo.id
            hiloAbierto = hilo.id
        } catch {
            estadoHilos = .fallo(error.localizedDescription)
        }
    }

    // MARK: - AgentStoring

    func send(_ text: String) async {
        let limpio = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty,
              let cuenta = cuentas.first(where: { $0.id == selectedAgentID })
        else { return }

        turnoEnVuelo?.cancel()
        messages.removeAll { $0.kind == .typing }
        messages.append(Message(id: UUID().uuidString, kind: .user(limpio)))
        let idRespuesta = UUID().uuidString
        messages.append(Message(id: "typing", kind: .typing))

        marcarTrabajando(cuenta.id, tarea: "Trabajando…")
        arrancarCronometro(titulo: primeraFrase(limpio))
        promptDelTurno = limpio
        usoDelTurno = (0, 0)

        turnoEnVuelo = Task { [weak self] in
            guard let self else { return }
            // Se prefiere el WebSocket: es el único que respeta el hilo. El HTTP
            // siempre habla con la única sesión ACP del agente, así que por ahí todo
            // acaba en la misma conversación.
            if let sid = self.sesiones[cuenta.id],
               await self.intentarPorSocket(cuenta, sid: sid, texto: limpio, respuesta: idRespuesta) {
                return
            }
            await self.porHTTP(cuenta, texto: limpio, respuesta: idRespuesta)
        }
    }

    /// Turno por WebSocket. Devuelve `false` si no se pudo ni empezar, para que el
    /// HTTP tome el relevo.
    private func intentarPorSocket(_ cuenta: AgentAccount, sid: String,
                                   texto: String, respuesta: String) async -> Bool {
        let cliente: ACPClient
        do { cliente = try await asegurarSocket(cuenta) }
        catch {
            EasyBitsClient.diag("socket no disponible, va por HTTP: \(error)")
            return false
        }

        porSocket = true
        var acumulado = ""
        var herramientas: [(id: String, titulo: String)] = []

        do {
            for try await evento in cliente.prompt(sessionID: sid, texto: texto) {
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
        return true
    }

    /// Turno por HTTP. Es el que **despierta la caja**, así que sigue siendo el
    /// respaldo y el primer turno de una app recién abierta.
    private func porHTTP(_ cuenta: AgentAccount, texto: String, respuesta: String) async {
        porSocket = false
        let cliente = EasyBitsClient(apiKey: cuenta.token)
        var acumulado = ""
        var intentos = 0

        while intentos < 2 {
            intentos += 1
            do {
                for try await evento in cliente.message(agentID: cuenta.id, content: texto,
                                                        sessionID: sesiones[cuenta.id]) {
                    switch evento {
                    case .chunk(let t):
                        acumulado += t
                        pintarRespuesta(id: respuesta, texto: acumulado)
                    case .usage(let e, let s, _):
                        ultimoUso = (e, s); usoDelTurno = (e, s)
                    case .newSession(let s):
                        sesiones[cuenta.id] = s
                    case .error(let d):
                        pintarRespuesta(id: respuesta,
                            texto: acumulado.isEmpty ? "⚠️ \(d)" : acumulado + "\n\n⚠️ \(d)")
                    case .done, .unknown:
                        break
                    }
                }
                if acumulado.isEmpty {
                    pintarRespuesta(id: respuesta, texto: "_El turno cerró sin texto._")
                }
                anotar(cuenta, chars: acumulado.count, como: .done)
                break
            } catch {
                if Self.esCorteDeTransporte(error), acumulado.isEmpty, intentos < 2 {
                    pintarRespuesta(id: respuesta, texto: "_Se cortó la conexión. Reintentando…_")
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                pintarRespuesta(id: respuesta, texto: Self.mensajeDeFallo(error, parcial: acumulado))
                anotar(cuenta, chars: acumulado.count, como: Task.isCancelled ? .stopped : .failed)
                break
            }
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
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[i].status = .idle(since: "ahora")
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
