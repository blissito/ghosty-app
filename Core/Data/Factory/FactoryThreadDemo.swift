import Foundation

/// La demo de lo que contesta @plan, con las cinco formas: trabajando, plan listo, sprint, ideas y
/// pregunta. Contestar la pregunta (#9004) la convierte en el plan del #42, como pasaría de verdad.
extension FactoryStore {
    static let demoPending: [PendingThread] = [
        .init(slug: "demo", room: "agenda", threadId: 9005, text: "Que el cliente pueda reagendar desde el link del recordatorio", at: Date().addingTimeInterval(-60)),
        .init(slug: "demo", room: "agenda", threadId: 9004, text: "Recordatorio un día antes de la cita", at: Date().addingTimeInterval(-600)),
        .init(slug: "demo", room: "agenda", threadId: 9002, text: "Quiero cobrar las citas por adelantado", at: Date().addingTimeInterval(-1800)),
        .init(slug: "demo", room: "agenda", threadId: 9003, text: "¿Qué le falta a la agenda para venderla?", at: Date().addingTimeInterval(-3600)),
    ]

    /// Lo que se contestó en la demo (hilo → texto), para que el hilo avance.
    nonisolated(unsafe) static var demoAnswers: [Int: String] = [:]
    /// El sprint de la demo tal como lo dejó la persona (quitar tickets, aprobar).
    nonisolated(unsafe) static var demoSprintState: FactorySprint?

    static var demoSprints: [FactorySprintRow] {
        let s = demoSprint
        return [
            .init(id: s.id, title: s.title, status: s.status, repo: s.repo, room: "agenda", threadId: 9002,
                  total: s.included.count, merged: s.merged, updatedAt: Int(Date().timeIntervalSince1970) - 1800),
            .init(id: 5, title: "Clientes frecuentes", status: "active", repo: "demo/agenda", room: "agenda", threadId: 8800,
                  total: 4, merged: 2, updatedAt: Int(Date().timeIntervalSince1970) - 86400),
        ]
    }

    static var demoSprint: FactorySprint {
        if let s = demoSprintState { return s }
        func item(_ i: Int, _ key: String, _ title: String, _ size: String, _ deps: [String], _ body: String) -> FactorySprint.Item {
            .init(id: 70 + i, idx: i, key: key, title: title, size: size, dependsOn: deps, bodyMd: body, included: true,
                  status: "pending", runId: nil, prUrl: nil, issueUrl: nil, issueNumber: nil, stage: nil)
        }
        return FactorySprint(
            id: 7, title: "Cobrar las citas por adelantado",
            goal: "Que el cliente pague al reservar y el negocio vea quién ya pagó.", repo: "demo/agenda",
            status: "draft", version: 1, canEdit: true, change: nil,
            items: [
                item(1, "K1", "Cuenta de MercadoPago del negocio", "M", [],
                     "## Qué\nConectar la cuenta de MercadoPago del negocio desde Ajustes.\n\n**Listo cuando:** el dueño conecta su cuenta y ve «Conectado».\n\n- Guardar el token cifrado\n- Botón «Desconectar»"),
                item(2, "K2", "Pago al reservar", "L", ["K1"],
                     "## Qué\nAl reservar, el cliente paga con MercadoPago antes de confirmar.\n\n**Listo cuando:** una reserva de prueba queda «Pagada» y el pago aparece en MercadoPago."),
                item(3, "K3", "Quién ya pagó, en la agenda", "S", ["K2"],
                     "## Qué\nUna etiqueta «Pagada» en cada cita de la agenda.\n\n**Listo cuando:** la etiqueta sale en la agenda del día."),
                item(4, "K4", "Reembolso al cancelar con 24 h", "M", ["K2"],
                     "## Qué\nSi el cliente cancela con 24 h o más, se le devuelve el pago.\n\n**Listo cuando:** cancelar una cita de prueba regresa el pago."),
            ])
    }

    static func demoThread(_ id: Int) -> FactoryThread? {
        guard let p = demoPending.first(where: { $0.threadId == id }) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        func msg(_ i: Int, _ body: String, live: Bool = false, ask: FactoryThread.Ask? = nil) -> FactoryThread.Message {
            .init(id: id * 10 + i, from: "agent", handle: "plan", name: "Arqui", body: body, at: now - 300 + i * 20, live: live, ask: ask)
        }
        func person(_ i: Int, _ text: String) -> FactoryThread.Message {
            .init(id: id * 10 + i, from: "person", handle: nil, name: "Tú", body: text, at: now - 200, live: false, ask: nil)
        }
        let root = FactoryThread.Message(id: id, from: "person", handle: nil, name: "Tú", body: "@plan \(p.text)", at: now - 400, live: false, ask: nil)
        let tools = { (s: String) in "```gt-tools\n{\"tools\":[{\"label\":\"Github: list issues\",\"status\":\"done\"},{\"label\":\"Leí el código de la agenda\",\"status\":\"done\",\"detail\":\"app/routes/agenda.tsx\"},\(s)]}\n```\n" }
        switch id {
        case 9005:
            return .init(channel: p.room, root: root, messages: [
                msg(1, tools("{\"label\":\"Buscando dónde se arma el recordatorio\",\"status\":\"running\",\"detail\":\"grep recordatorio\"}"), live: true),
            ], run: nil, sprint: nil, working: true)
        case 9004:
            let q = FactoryThread.Ask(question: "¿El recordatorio va por WhatsApp o por correo?", options: ["WhatsApp", "Correo", "Los dos"], answered: demoAnswers[id])
            var m = [msg(1, tools("{\"label\":\"Factory: context\",\"status\":\"done\"}") + "Ya vi dónde se agenda. Antes de armar el plan: ¿por dónde le llega el recordatorio al cliente?", ask: q)]
            if let a = demoAnswers[id] {
                m.append(person(2, "@plan \(a)"))
                m.append(msg(3, "```gt-tools\n{\"tools\":[{\"label\":\"Factory: plan submit\",\"status\":\"done\"}]}\n```\nVa por \(a). Te dejé el plan para firmar."))
                return .init(channel: p.room, root: root, messages: m, run: .init(id: 42, status: "plan_review", title: "Recordatorio por WhatsApp un día antes de la cita"), sprint: nil, working: false)
            }
            return .init(channel: p.room, root: root, messages: m, run: nil, sprint: nil, working: false)
        case 9002:
            return .init(channel: p.room, root: root, messages: [
                msg(1, tools("{\"label\":\"Factory: sprint submit\",\"status\":\"done\"}") + "No cabe en un pedido: te propuse un sprint de 4 tickets. Quita los que no quieras y créalo."),
            ], run: nil, sprint: demoSprint, working: false)
        case 9003:
            let asks = """
            ```gt-asks
            {"roomSlug":"agenda","items":[{"size":"chico","title":"Recordatorio por WhatsApp","ask":"Manda un recordatorio por WhatsApp un día antes de cada cita.","why":"La mitad de las faltas son olvidos."},{"size":"mediano","title":"Reagendar desde el link","ask":"Que el cliente pueda reagendar desde el link del recordatorio.","why":"Hoy tiene que llamar."},{"size":"grande","title":"Cobro por adelantado","ask":"Cobrar las citas al reservar con MercadoPago.","why":"Baja las faltas y adelanta el dinero."}]}
            ```
            """
            return .init(channel: p.room, root: root, messages: [
                msg(1, tools("{\"label\":\"Factory: suggest\",\"status\":\"done\"}") + "Revisé el repo y los issues. Esto es lo que más vende, de lo más chico a lo más grande:\n" + asks),
            ], run: nil, sprint: nil, working: false)
        default:
            return nil
        }
    }

    /// Una acción sobre el sprint de la demo, sin red.
    static func demoSprintAct(_ a: FactoryAPI.SprintAction) -> FactorySprint {
        let s = demoSprint
        var items = s.items
        var status = s.status
        switch a {
        case .approve:
            status = "active"
            if let i = items.firstIndex(where: \.included) {
                let it = items[i]
                items[i] = .init(id: it.id, idx: it.idx, key: it.key, title: it.title, size: it.size, dependsOn: it.dependsOn, bodyMd: it.bodyMd,
                                 included: true, status: "active", runId: 43, prUrl: nil, issueUrl: nil, issueNumber: nil, stage: "@plan")
            }
        case let .edit(itemId, included, title, bodyMd):
            if let i = items.firstIndex(where: { $0.id == itemId }) {
                let it = items[i]
                items[i] = .init(id: it.id, idx: it.idx, key: it.key, title: title ?? it.title, size: it.size, dependsOn: it.dependsOn,
                                 bodyMd: bodyMd ?? it.bodyMd, included: included ?? it.included, status: it.status, runId: it.runId,
                                 prUrl: it.prUrl, issueUrl: it.issueUrl, issueNumber: it.issueNumber, stage: it.stage)
            }
        default: break
        }
        let out = FactorySprint(id: s.id, title: s.title, goal: s.goal, repo: s.repo, status: status, version: s.version,
                                canEdit: s.canEdit, change: s.change, items: items)
        demoSprintState = out
        return out
    }
}
