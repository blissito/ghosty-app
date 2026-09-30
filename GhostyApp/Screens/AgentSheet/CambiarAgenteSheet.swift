import SwiftUI

/// «Cambiar de agente»: el contenido de la `GhostySheet` que abre el avatar de la barra.
///
/// Agentes reales, con su tipo (personal, espacio o compartido), la barra de uso REAL
/// que dé `/me/usage` para cada uno y la palomita en el seleccionado. Nunca números
/// inventados: si el uso no llegó o no aplica (llave propia, sin tope), no hay barra.
struct CambiarAgenteSheet: View {
    let store: LiveAgentStore
    /// Se eligió uno (o el mismo): quien la abrió cierra la hoja y va al chat.
    var onElegido: () -> Void

    /// Uso por agente, compartido con Perfil: al reabrir la hoja las barras ya están.
    /// Ausente = todavía no llega o falló.
    @State private var cache = UsosDeAgentes.compartido
    private var usos: [String: PersonalUsage] { cache.usos }

    /// Grupos por espacio: primero lo tuyo, luego cada workspace (en el orden en que llegan)
    /// y al final lo compartido contigo. Con un solo grupo no se pinta encabezado.
    private var grupos: [(titulo: String, agentes: [Agent])] {
        var orden: [String] = []
        var porClave: [String: (String, [Agent])] = [:]
        for a in store.agents {
            let (clave, titulo): (String, String)
            switch a.space?.kind {
            case .workspace?:
                let n = a.space!.name
                (clave, titulo) = ("w:" + a.space!.id, n.prefix(1).uppercased() + n.dropFirst())
            case .shared?: (clave, titulo) = ("~shared", "Compartidos contigo")
            default:
                (clave, titulo) = a.compartidoPor == nil ? ("0personal", "Tuyos") : ("~shared", "Compartidos contigo")
            }
            if porClave[clave] == nil { orden.append(clave); porClave[clave] = (titulo, []) }
            porClave[clave]!.1.append(a)
        }
        // Dentro de cada grupo, por último uso; los grupos de espacio, por su agente más reciente.
        func reciente(_ a: Agent) -> Date { a.ultimaActividad ?? .distantPast }
        for k in orden { porClave[k]!.1.sort { reciente($0) > reciente($1) } }
        let ordenados = orden.sorted { x, y in
            if rango(x) != rango(y) { return rango(x) < rango(y) }
            return (porClave[x]!.1.first.map(reciente) ?? .distantPast) > (porClave[y]!.1.first.map(reciente) ?? .distantPast)
        }
        return ordenados.map { (porClave[$0]!.0, porClave[$0]!.1) }
    }

    private func rango(_ clave: String) -> Int {
        clave == "0personal" ? 0 : clave == "~shared" ? 2 : 1
    }

    var body: some View {
        let gs = grupos
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(gs.enumerated()), id: \.offset) { g, grupo in
                if gs.count > 1 {
                    Text(grupo.titulo)
                        .gSectionCaps()
                        .padding(.horizontal, 6)
                        .padding(.top, g == 0 ? 2 : 12)
                        .gIn(duration: 0.25, delay: 0.02 + Double(g) * 0.05)
                }
                ForEach(Array(grupo.agentes.enumerated()), id: \.element.id) { i, agente in
                    let elegido = agente.id == store.selectedAgentID
                    GhostySheetRow(title: agente.name, subtitle: Self.subtitulo(agente, agrupado: gs.count > 1),
                                   selected: elegido,
                                   action: { elegir(agente) },
                                   leading: { AgentAvatar(tone: agente.tone, size: 40) },
                                   // Sólo elegir: el uso vive en Perfil y en la hoja del agente de arriba.
                                   extra: { EmptyView() })
                        .overlay(alignment: .bottom) {
                            // Hairline desde donde empieza el nombre (82), menos en el último.
                            if i < grupo.agentes.count - 1 {
                                Rectangle().fill(Color.gHairline).frame(height: 1).padding(.leading, 82)
                            }
                        }
                        .accessibilityIdentifier("agente-\(agente.id)")
                        // Las filas entran escalonadas, como el `gin` del prototipo.
                        .gIn(duration: 0.25, delay: 0.04 + Double(min(g * 3 + i, 8)) * 0.04)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.selectedAgentID)
    }

    /// Con encabezado de grupo, el espacio ya se lee arriba: la línea dice el modelo.
    static func subtitulo(_ a: Agent, agrupado: Bool) -> String {
        guard agrupado else { return tipo(a) }
        if let de = a.compartidoPor { return "De \(de)" }
        return a.model ?? a.engine
    }

    /// La línea bajo el nombre: de quién es el agente.
    static func tipo(_ a: Agent) -> String {
        switch a.space?.kind {
        case .workspace?:
            let n = a.space!.name
            return "Espacio · \(n.prefix(1).uppercased() + n.dropFirst())"
        case .shared?:
            return a.compartidoPor.map { "Compartido · de \($0)" } ?? "Compartido contigo"
        default:
            if let de = a.compartidoPor { return "Compartido · de \(de)" }
            return "Personal · \(a.model ?? a.engine)"
        }
    }

    @ViewBuilder
    private func barra(de agente: Agent) -> some View {
        if let m = Self.medida(usos[agente.id]) {
            let pct = m.0, etiqueta = m.1
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gSeparator)
                        Capsule().fill(Color.gPrimary)
                            .frame(width: geo.size.width * min(1, max(0, pct)))
                    }
                }
                .frame(height: 4)
                Text(etiqueta)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.gInk2)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, 6)
            .transition(.opacity)
        }
    }

    /// Qué barra se enseña: la del espacio si el agente es de uno, la semanal del plan
    /// si le aplica. Llave propia o sin tope: ninguna (no hay tope que medir).
    static func medida(_ u: PersonalUsage?) -> (Double, String)? {
        guard let u else { return nil }
        if u.applies == false, let ws = u.workspace {
            return (ws.pct, "\(Int((ws.pct * 100).rounded())) % del espacio")
        }
        if u.ownKey != nil || u.exempt == true || u.applies == false { return nil }
        guard let pct = u.week.pct else { return nil }
        return (pct, "\(Int((pct * 100).rounded())) % de la semana")
    }

    private func elegir(_ agente: Agent) {
        store.seleccionar(agente.id)
        onElegido()
    }
}
