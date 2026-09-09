import Foundation
import Observation

/// El store real: habla con la caja de EasyBits. Implementa el mismo protocolo que
/// el mock, así que las vistas no cambian ni una línea al pasar de uno a otro —
/// que es justo la razón de que la frontera exista.
@Observable
@MainActor
final class LiveAgentStore: AgentStoring {

    // Estado que las vistas leen
    var agents: [Agent] = []
    var selectedAgentID: Agent.ID = ""
    var messages: [Message] = []
    var currentTurn: TurnActivity?
    var log: [LogEntry] = []
    var pendingPermission: PermissionRequest?
    var permissionHistory: [PermissionRecord] = []
    var artifacts: [Artifact] = []
    var deliveredToday: [Artifact] = []

    /// Estado de conexión, para que la pantalla pueda decir la verdad en vez de
    /// quedarse en blanco.
    enum Conexion: Equatable {
        case cargando
        case lista
        case sinLlave
        case fallo(String)
    }
    var conexion: Conexion = .cargando
    var ultimoUso: (entrada: Int, salida: Int)?

    private let cliente: EasyBitsClient?
    private var sesiones: [String: String] = [:]      // agentId → sessionId
    private var turnoEnVuelo: Task<Void, Never>?
    private var inicioDelTurno: Date?
    private var cronometro: Task<Void, Never>?

    init() {
        if let llave = Credentials.easyBitsAPIKey() {
            cliente = EasyBitsClient(apiKey: llave)
        } else {
            cliente = nil
            conexion = .sinLlave
        }
    }

    // MARK: - Carga

    func cargar() async {
        guard let cliente else { conexion = .sinLlave; return }
        conexion = .cargando
        do {
            let remotos = try await cliente.agents()
            // Sólo los que hablan ACP y están de pie: un agente `lost` no contesta
            // y meterlo en la lista sólo produce un turno que muere en 502.
            let utiles = remotos.filter { $0.status == "running" }
            let orden: [AgentTone] = [.durazno, .lila, .azul]
            agents = utiles.enumerated().map { i, a in
                Agent(
                    id: a.agentId,
                    name: a.name ?? "agente",
                    tone: orden[i % orden.count],
                    status: .idle(since: "listo"),
                    engine: a.template ?? "—"
                )
            }
            if let preferido = Credentials.defaultAgentID(),
               agents.contains(where: { $0.id == preferido }) {
                selectedAgentID = preferido
            } else {
                selectedAgentID = agents.first?.id ?? ""
            }
            conexion = agents.isEmpty
                ? .fallo("Ninguna de tus cajas está encendida ahora mismo.")
                : .lista
        } catch {
            conexion = .fallo(error.localizedDescription)
        }
    }

    // MARK: - AgentStoring

    func send(_ text: String) async {
        let limpio = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty, let cliente, !selectedAgentID.isEmpty else { return }

        turnoEnVuelo?.cancel()
        messages.removeAll { $0.kind == .typing }
        messages.append(Message(id: UUID().uuidString, kind: .user(limpio)))

        let idRespuesta = UUID().uuidString
        messages.append(Message(id: "typing", kind: .typing))

        let agente = selectedAgentID
        // La etiqueta de estado NO es el prompt: un mensaje largo desbordaba la
        // cabecera. El prompt completo ya se ve en su propia burbuja.
        marcarTrabajando(agente, tarea: "Trabajando…")
        arrancarCronometro(titulo: primeraFrase(limpio))

        turnoEnVuelo = Task { [weak self] in
            guard let self else { return }
            var acumulado = ""
            do {
                let flujo = cliente.message(
                    agentID: agente,
                    content: limpio,
                    sessionID: self.sesiones[agente]
                )
                EasyBitsClient.diag("consumidor: iterando")
                for try await evento in flujo {
                    EasyBitsClient.diag("consumidor: evento \(evento)")
                    switch evento {
                    case .chunk(let trozo):
                        acumulado += trozo
                        self.pintarRespuesta(id: idRespuesta, texto: acumulado)
                    case .usage(let entrada, let salida, _):
                        self.ultimoUso = (entrada, salida)
                    case .newSession(let s):
                        self.sesiones[agente] = s
                    case .error(let detalle):
                        self.pintarRespuesta(id: idRespuesta,
                                             texto: acumulado.isEmpty ? "⚠️ \(detalle)" : acumulado + "\n\n⚠️ \(detalle)")
                    case .done:
                        break
                    case .unknown:
                        break
                    }
                }
                EasyBitsClient.diag("consumidor: fin, \(acumulado.count) chars")
                if acumulado.isEmpty {
                    self.pintarRespuesta(id: idRespuesta, texto: "_El turno cerró sin texto._")
                }
            } catch {
                EasyBitsClient.diag("consumidor: FALLO \(error)")
                self.pintarRespuesta(
                    id: idRespuesta,
                    texto: acumulado.isEmpty
                        ? "⚠️ No pude completar el turno.\n\n\(error.localizedDescription)"
                        : acumulado + "\n\n⚠️ El turno se cortó: \(error.localizedDescription)"
                )
            }
            self.cerrarTurno(agente)
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
                             title: request.question,
                             detail: request.detail,
                             outcome: etiqueta(decision)),
            at: 0
        )
    }

    func respondToPR(_ card: PullRequestCard, approve: Bool) async {
        await send(approve
                   ? "Aprueba el \(card.reference)."
                   : "Pide cambios en el \(card.reference) y deja el comentario en la línea del bloqueante.")
    }

    // MARK: - Interno

    private func pintarRespuesta(id: String, texto: String) {
        messages.removeAll { $0.kind == .typing }
        let nuevo = Message(id: id, kind: .agent(text: texto, tools: nil, trailing: nil))
        if let i = messages.firstIndex(where: { $0.id == id }) {
            messages[i] = nuevo
        } else {
            messages.append(nuevo)
        }
    }

    private func marcarTrabajando(_ id: String, tarea: String) {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[i].status = .working(task: tarea)
    }

    private func cerrarTurno(_ id: String) {
        cronometro?.cancel(); cronometro = nil
        currentTurn = nil
        inicioDelTurno = nil
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
        let corte = t.prefix(60)
        return corte.count < t.count ? corte + "…" : String(corte)
    }

    private func etiqueta(_ d: PermissionDecision) -> String {
        switch d {
        case .allowOnce:    return "Permitido esta vez · ahora"
        case .allowForTask: return "Permitido para esa tarea · ahora"
        case .deny:         return "Rechazado · ahora"
        }
    }
}
