import Foundation

/// Funde lo que trae gs de un hilo con lo que ya está en pantalla.
///
/// ⚠️ Existe para que NADA se reemplace. Antes cada recarga sustituía el hilo entero con ids
/// por posición (`u3`, `a4`) y un emparejado por texto (`conservarIDs`): una copia que llegaba
/// tarde se llevaba tu mensaje recién mandado y el scroll anclado a él (bliss, 8-oct). Aquí la
/// identidad es la del servidor (`seq`) y lo optimista se reconcilia por su `turnId`.
///
/// Reglas:
/// 1. Mismo `seq` → se actualiza en su sitio y conserva el `id` de vista.
/// 2. Sin `seq` local pero mismo `turnId` y rol → es lo optimista: adopta el `seq`, conserva
///    el `id` (y en tu mensaje, los adjuntos con sus bytes).
/// 3. Lo de un turno EN CURSO del agente no se toca: lo escribe el stream.
/// 4. Lo nuevo entra en orden de `seq`; lo local sin `seq` (entregas, lo que aún sube) se
///    queda donde estaba.
/// 5. Sólo se borra lo que el servidor dice borrado (`deleted`).
enum ThreadMerge {
    enum Role { case user, agent, other }

    static func role(_ m: Message) -> Role {
        switch m.kind {
        case .user, .sistema: return .user
        case .agent: return .agent
        default: return .other
        }
    }

    static func merge(_ local: [Message], with page: [Message],
                      deleted: Set<Int> = [], liveTurnId: String? = nil) -> [Message] {
        var result = local.filter { m in m.seq.map { !deleted.contains($0) } ?? true }
        for incoming in page.sorted(by: { ($0.seq ?? 0) < ($1.seq ?? 0) }) {
            guard let seq = incoming.seq, !deleted.contains(seq) else { continue }
            let isLiveAgent = liveTurnId != nil && incoming.turnId == liveTurnId && role(incoming) == .agent
            // 1. Ya está.
            if let i = result.firstIndex(where: { $0.seq == seq }) {
                if !isLiveAgent { result[i] = updated(result[i], with: incoming) }
                continue
            }
            // 2. Lo optimista de ese turno.
            if let turnId = incoming.turnId,
               let i = result.firstIndex(where: { $0.seq == nil && $0.turnId == turnId && role($0) == role(incoming) }) {
                if isLiveAgent {
                    result[i].seq = seq
                } else {
                    result[i] = updated(result[i], with: incoming)
                }
                continue
            }
            // 2b. Tu mensaje que gs guardó con OTRO turno: un steer se guarda con el `turnId`
            //     del turno vivo, no con el del POST (8-oct). Mismo texto, mismo lado, aún sin
            //     `seq`. Es el único caso que compara texto.
            if role(incoming) == .user, case .user(let text, _, _) = incoming.kind,
               let i = result.firstIndex(where: { m in
                   guard m.seq == nil, m.turnId != nil, case .user(let t, _, _) = m.kind else { return false }
                   return t == text
               }) {
                result[i] = updated(result[i], with: incoming)
                continue
            }
            // 3. La respuesta del turno vivo la pinta el stream.
            if isLiveAgent { continue }
            // 4. Nuevo: en su sitio por `seq`.
            result.insert(incoming, at: insertionIndex(for: seq, in: result))
        }
        return result
    }

    /// Lo del servidor en el sitio de lo local: mismo `id` de vista.
    private static func updated(_ old: Message, with new: Message) -> Message {
        var m = Message(id: old.id, kind: new.kind, seq: new.seq, turnId: new.turnId ?? old.turnId)
        switch (old.kind, new.kind) {
        case (.user(_, let adjuntos, let steer), .user(let text, let serverAdjuntos, _)):
            // Tus adjuntos locales traen los bytes; los del servidor sólo el nombre.
            m.kind = .user(text, adjuntos: adjuntos.isEmpty ? serverAdjuntos : adjuntos, steer: steer)
        case (.agent(_, let tools, let trailing), .agent(let text, let serverTools, let serverTrailing)):
            // Las herramientas que vimos correr valen más que la narración reconstruida.
            m.kind = .agent(text: text, tools: tools ?? serverTools, trailing: serverTrailing ?? trailing)
        default:
            break
        }
        return m
    }

    /// Detrás del último con `seq` menor y de lo local que llegó después de él (una entrega);
    /// si no hay, delante del primero con `seq` mayor; si tampoco, delante de lo optimista
    /// pendiente (que siempre va al final).
    static func insertionIndex(for seq: Int, in list: [Message]) -> Int {
        if let last = list.lastIndex(where: { m in m.seq.map { $0 < seq } ?? false }) {
            var i = last + 1
            while i < list.count, list[i].seq == nil, list[i].turnId == nil { i += 1 }
            return i
        }
        if let i = list.firstIndex(where: { ($0.seq ?? .min) > seq }) { return i }
        if let i = list.firstIndex(where: { $0.seq == nil && $0.turnId != nil }) { return i }
        return list.count
    }
}
