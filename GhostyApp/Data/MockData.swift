import Foundation

/// Los datos de las cinco pantallas, tomados literal de los mockups aprobados.
/// Nombres ficticios a propósito: ningún cliente real aparece aquí.
enum MockData {

    static let agents: [Agent] = [
        Agent(id: "goose",  name: "Goose",  tone: .durazno,
              status: .working(task: "Revisando el PR #204"), engine: "Sonnet 5"),
        Agent(id: "ghosty", name: "Ghosty", tone: .lila,
              status: .awaitingApproval, engine: "Sonnet 5"),
        Agent(id: "blue",   name: "Blue",   tone: .azul,
              status: .idle(since: "hace 3 h"), engine: "DeepSeek V4"),
    ]

    static let messages: [Message] = [
        Message(id: "m1", kind: .user("Revisa el PR 204 y dime si lo mergeo")),
        Message(id: "m2", kind: .agent(
            text: "Lo revisé. Toca tres archivos y la CI está verde, pero hay un detalle que sí frena el merge.",
            tools: ToolRun(count: 4, summary: "GitHub: leer PR · leer diff · log del job · buscar en el repo"),
            trailing: "El bloqueante: `resolveTicket` ya no valida el workspace. Un ticket firmado para un tenant abre la sesión de otro."
        )),
        Message(id: "m3", kind: .prCard(PullRequestCard(
            reference: "PR #204",
            title: "ticket por workspace",
            chips: [
                .init(text: "CI verde", tone: .green),
                .init(text: "1 bloqueante", tone: .red),
                .init(text: "3 archivos", tone: .neutral),
            ]
        ))),
        Message(id: "m4", kind: .user("Pide cambios y deja el comentario en esa línea")),
        Message(id: "typing", kind: .typing),
    ]

    static let currentTurn = TurnActivity(
        id: "t1",
        title: "Revisar el PR #204",
        detail: "Leyendo el diff de ticket.ts",
        step: 4, totalSteps: 6,
        elapsed: "1:42"
    )

    static let log: [LogEntry] = [
        LogEntry(id: "l1", icon: .document, title: "Cotización para Aralia",
                 detail: "Entregó un documento de 3 páginas", time: "14:08"),
        LogEntry(id: "l2", icon: .web, title: "Precios de insumos",
                 detail: "Comparó 4 proveedores", time: "11:20"),
        LogEntry(id: "l3", icon: .calendar, title: "Agenda de la semana",
                 detail: "Sin cambios que reportar", time: "9:02", muted: true),
    ]

    static let pendingPermission = PermissionRequest(
        id: "p1",
        kind: .email,
        agentName: "Ghosty",
        question: "¿Dejas que Ghosty envíe este correo?",
        detail: "Manda la cotización de septiembre a compras@aralia.mx con el PDF de 3 páginas. Total: $48,900 MXN.",
        attachment: .init(filename: "cotizacion-aralia.pdf", meta: "3 páginas · 184 KB")
    )

    static let permissionHistory: [PermissionRecord] = [
        PermissionRecord(id: "h1", icon: .cart,
                         title: "Comprar insumos de limpieza",
                         detail: "3 cajas de guantes de nitrilo · $1,240",
                         outcome: "Permitido para esa tarea · 15:34"),
        PermissionRecord(id: "h2", icon: .branch,
                         title: "Empujar una rama a GitHub",
                         detail: "fix/ticket-workspace en ghosty-teams",
                         outcome: "Permitido esta vez · 11:07"),
    ]

    static let artifacts: [Artifact] = [
        Artifact(id: "a1", kind: .document, title: "Cotización · Aralia",      area: "Ventas"),
        Artifact(id: "a2", kind: .board,    title: "Precios de insumos",       area: "Compras"),
        Artifact(id: "a3", kind: .page,     title: "Landing de septiembre",    area: "Marketing"),
        Artifact(id: "a4", kind: .sheet,    title: "Rutas de limpieza",        area: "Operación"),
        Artifact(id: "a5", kind: .mail,     title: "Seguimiento a Nordia",     area: "Ventas"),
        Artifact(id: "a6", kind: .document, title: "Contrato marco 2027",      area: "Legal"),
    ]

    static let deliveredToday: [Artifact] = [artifacts[0], artifacts[1]]
}
