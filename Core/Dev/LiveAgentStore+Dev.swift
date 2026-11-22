import Foundation

// La conversación de un pendiente (`dev:<id>`) se ve con el MISMO chat de la app (`ConversationView`),
// dentro de la pestaña «Conversación» de Dev. Esto la enfoca sin mandarte a Chats y, al salir, deja todo
// como estaba: el hilo `dev:` no vive en la lista de chats (decisión de bliss, 22-nov).
extension LiveAgentStore {
    struct DevFocus { let agentID: String; let threadKey: String?; let devThread: ChatThread; let devAgentID: String }

    /// Enfoca el hilo del escritor. `nil` si su agente no está entre los tuyos (entonces no hay chat que montar).
    func focusDevThread(agent agentID: String, session: String) -> DevFocus? {
        guard agents.contains(where: { $0.id == agentID }) else { return nil }
        let previous = (selectedAgentID, channels[selectedAgentID]?.activa)
        seleccionar(agentID)  // crea su canal si no existe
        guard let canal = channels[agentID] else { return nil }
        let hilo = canal.hilo(sesion: session) ?? canal.abrir(session)
        focus(hilo, agent: agentID)
        refresh(hilo)
        return DevFocus(agentID: previous.0, threadKey: previous.1, devThread: hilo, devAgentID: agentID)
    }

    /// Regresa al agente y la conversación de antes y suelta el hilo `dev:` (no va en Chats).
    func releaseDevThread(_ f: DevFocus) {
        channels[f.devAgentID]?.cerrar(f.devThread)
        if !f.agentID.isEmpty, f.agentID != selectedAgentID { seleccionar(f.agentID) }
        if let k = f.threadKey { channels[f.agentID]?.activa = k }
    }
}
