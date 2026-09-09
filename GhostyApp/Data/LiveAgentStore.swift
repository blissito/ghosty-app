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
    private var turnoEnVuelo: Task<Void, Never>?
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

    /// Cambia de agente conservando cada hilo por separado.
    func seleccionar(_ id: String) {
        guard id != selectedAgentID, cuentas.contains(where: { $0.id == id }) else { return }
        hilos[selectedAgentID] = messages
        Credentials.activar(id)
        selectedAgentID = id
        messages = hilos[id] ?? []
        currentTurn = nil
    }

    /// Empieza de cero con este agente. Suelta el `sessionId`, así que la caja abre
    /// un hilo nuevo y no arrastra el contexto anterior.
    func nuevaConversacion() {
        turnoEnVuelo?.cancel()
        sesiones[selectedAgentID] = nil
        hilos[selectedAgentID] = []
        messages = []
        currentTurn = nil
        cronometro?.cancel()
    }

    func quitarAgente(_ id: String) {
        Credentials.quitar(id)
        hilos[id] = nil
        sesiones[id] = nil
        Task { await cargar() }
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

        let cliente = EasyBitsClient(apiKey: cuenta.token)
        turnoEnVuelo = Task { [weak self] in
            guard let self else { return }
            var acumulado = ""
            var intentos = 0
            let maxIntentos = 2

            while intentos < maxIntentos {
                intentos += 1
                do {
                    let flujo = cliente.message(agentID: cuenta.id, content: limpio,
                                                sessionID: self.sesiones[cuenta.id])
                    for try await evento in flujo {
                        switch evento {
                        case .chunk(let trozo):
                            acumulado += trozo
                            self.pintarRespuesta(id: idRespuesta, texto: acumulado)
                        case .usage(let e, let s, _):
                            self.ultimoUso = (e, s)
                        case .newSession(let s):
                            self.sesiones[cuenta.id] = s
                        case .error(let d):
                            self.pintarRespuesta(id: idRespuesta,
                                texto: acumulado.isEmpty ? "⚠️ \(d)" : acumulado + "\n\n⚠️ \(d)")
                        case .done, .unknown:
                            break
                        }
                    }
                    if acumulado.isEmpty {
                        self.pintarRespuesta(id: idRespuesta, texto: "_El turno cerró sin texto._")
                    }
                    break
                } catch {
                    // Se reintenta sólo si no llegó NADA: con texto en pantalla, otro
                    // intento duplicaría el turno del lado del agente y lo cobraría dos veces.
                    if Self.esCorteDeTransporte(error), acumulado.isEmpty, intentos < maxIntentos {
                        self.pintarRespuesta(id: idRespuesta, texto: "_Se cortó la conexión. Reintentando…_")
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                    self.pintarRespuesta(id: idRespuesta,
                                         texto: Self.mensajeDeFallo(error, parcial: acumulado))
                    break
                }
            }
            self.cerrarTurno(cuenta.id)
        }
    }

    func stopTurn() async {
        turnoEnVuelo?.cancel()
        cerrarTurno(selectedAgentID)
        messages.removeAll { $0.kind == .typing }
    }

    func decide(_ request: PermissionRequest, _ decision: PermissionDecision) async {
        guard pendingPermission?.id == request.id else { return }
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

    private func pintarRespuesta(id: String, texto: String) {
        messages.removeAll { $0.kind == .typing }
        let nuevo = Message(id: id, kind: .agent(text: texto, tools: nil, trailing: nil))
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
