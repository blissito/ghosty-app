import Foundation
import Observation

/// La frontera única entre las vistas y los datos.
///
/// Todos los métodos son `async` **desde ya**, aunque el mock responda inmediato: el día
/// que esto hable ACP por WebSocket no cambia ni una firma en las vistas. Las vistas
/// nunca conocen `MockData`.
@MainActor
protocol AgentStoring: AnyObject, Observable {
    var agents: [Agent] { get }
    var selectedAgentID: Agent.ID { get set }

    var messages: [Message] { get }
    var currentTurn: TurnActivity? { get }
    var log: [LogEntry] { get }

    var pendingPermission: PermissionRequest? { get }
    var permissionHistory: [PermissionRecord] { get }

    var artifacts: [Artifact] { get }
    var deliveredToday: [Artifact] { get }

    func send(_ text: String) async
    func stopTurn() async
    func decide(_ request: PermissionRequest, _ decision: PermissionDecision) async
    func respondToPR(_ card: PullRequestCard, approve: Bool) async
}

extension AgentStoring {
    var selectedAgent: Agent? {
        agents.first { $0.id == selectedAgentID }
    }
}

/// Datos cableados. Muta estado local a propósito: así Detener y los tres botones de
/// permiso hacen algo visible cuando alguien toca el prototipo en un teléfono.
@Observable
@MainActor
final class MockAgentStore: AgentStoring {
    var agents: [Agent] = MockData.agents
    var selectedAgentID: Agent.ID = MockData.agents[0].id

    var messages: [Message] = MockData.messages
    var currentTurn: TurnActivity? = MockData.currentTurn
    var log: [LogEntry] = MockData.log

    var pendingPermission: PermissionRequest? = MockData.pendingPermission
    var permissionHistory: [PermissionRecord] = MockData.permissionHistory

    var artifacts: [Artifact] = MockData.artifacts
    var deliveredToday: [Artifact] = MockData.deliveredToday

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.removeAll { $0.kind == .typing }
        messages.append(Message(id: UUID().uuidString, kind: .user(trimmed)))
        messages.append(Message(id: "typing", kind: .typing))
    }

    func stopTurn() async {
        currentTurn = nil
        // el agente que trabajaba pasa a reposo, como haría el cierre real del turno
        if let i = agents.firstIndex(where: { if case .working = $0.status { return true } else { return false } }) {
            agents[i].status = .idle(since: "ahora")
        }
    }

    func decide(_ request: PermissionRequest, _ decision: PermissionDecision) async {
        guard pendingPermission?.id == request.id else { return }
        pendingPermission = nil
        permissionHistory.insert(
            PermissionRecord(
                id: request.id,
                icon: request.kind == .email ? .document : .cart,
                title: request.question,
                detail: request.detail,
                outcome: Self.outcomeLabel(decision)
            ),
            at: 0
        )
        if let i = agents.firstIndex(where: { $0.status == .awaitingApproval }) {
            agents[i].status = .idle(since: "ahora")
        }
    }

    func respondToPR(_ card: PullRequestCard, approve: Bool) async {
        let texto = approve
            ? "Aprobé el \(card.reference)."
            : "Dejé los cambios pedidos en el \(card.reference), con el comentario en la línea."
        messages.append(Message(id: UUID().uuidString, kind: .agent(text: texto, tools: nil, trailing: nil)))
    }

    private static func outcomeLabel(_ d: PermissionDecision) -> String {
        switch d {
        case .allowOnce:   return "Permitido esta vez · ahora"
        case .allowForTask: return "Permitido para esa tarea · ahora"
        case .deny:        return "Rechazado · ahora"
        }
    }
}
