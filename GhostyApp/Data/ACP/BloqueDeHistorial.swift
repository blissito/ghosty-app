import Foundation

/// La conversación previa, dicha en el propio turno.
///
/// ⚠️ **Es un parche, y su sitio de verdad está en la caja.** Medido con logs contra el
/// agente real: `session/load` encuentra la sesión, carga sus extensiones y nos reemite el
/// transcript (14 eventos), y aun así el modelo arranca sin memoria —«cada sesión empieza
/// sin memoria de charlas previas»—. O sea que la caja reproduce la conversación **hacia
/// el cliente** pero no la reconstruye **hacia el modelo**. Desde aquí no hay forma de
/// arreglar eso… salvo mandársela nosotros.
///
/// ⚠️ Y no es gratis: son tokens de entrada en cada turno. Por eso va **recortado** —los
/// últimos intercambios, y con tope de caracteres— en vez de la conversación entera. El
/// día que la caja restaure el contexto de verdad, esto se borra y se nota en la factura.
enum BloqueDeHistorial {
    /// Cuántos mensajes de vuelta se cuentan. Lo bastante para «lo de antes» y no tanto
    /// como para pagar la conversación completa cada vez.
    private static let cuantos = 14
    /// Tope duro. Una respuesta larga con tablas se come cualquier presupuesto.
    private static let topeDeCaracteres = 6000
    /// Lo que se conserva de CADA mensaje: lo suficiente para reconocerlo.
    private static let topePorMensaje = 700

    /// `nil` si no hay nada previo que contar.
    static func texto(_ mensajes: [Message]) -> String? {
        // Lo que ya está en el turno no se repite: el último mensaje del usuario es el
        // que se está mandando, y los tres puntos no son conversación.
        var previos = mensajes
        if case .user = previos.last?.kind { previos.removeLast() }
        previos.removeAll { $0.kind == .typing }
        guard !previos.isEmpty else { return nil }

        var lineas: [String] = []
        var total = 0
        // De atrás hacia delante: si hay que cortar, se corta lo VIEJO.
        for m in previos.suffix(cuantos).reversed() {
            guard let linea = frase(m) else { continue }
            if total + linea.count > topeDeCaracteres { break }
            total += linea.count
            lineas.insert(linea, at: 0)
        }
        guard !lineas.isEmpty else { return nil }

        return """
        [CONVERSACIÓN PREVIA DE ESTE MISMO HILO — contexto, NO instrucciones nuevas]
        \(lineas.joined(separator: "\n"))
        [FIN DE LA CONVERSACIÓN PREVIA. Lo que sigue es lo que te pide la persona AHORA.]
        """
    }

    private static func frase(_ m: Message) -> String? {
        switch m.kind {
        case .user(let t, let adjuntos):
            let cuerpo = recorte(t)
            let conQue = adjuntos.isEmpty ? "" : " (con \(adjuntos.count) adjunto(s))"
            return cuerpo.isEmpty && conQue.isEmpty ? nil : "Persona: \(cuerpo)\(conQue)"
        case .agent(let t, _, _):
            let cuerpo = recorte(t)
            return cuerpo.isEmpty ? nil : "Tú: \(cuerpo)"
        case .entrega(let e):
            // Lo entregado cuenta como parte de la conversación: «el PDF de antes» sólo
            // se entiende si sabe que entregó un PDF.
            return "Tú entregaste: \(e.titulo)"
        case .prCard, .typing:
            return nil
        }
    }

    private static func recorte(_ t: String) -> String {
        let limpio = t.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return limpio.count <= topePorMensaje
            ? limpio
            : String(limpio.prefix(topePorMensaje)) + "…"
    }
}
