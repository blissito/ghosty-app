import SwiftUI

/// Una línea de «Actividad»: algo que pasó mientras no mirabas.
struct ActivityItem: Identifiable {
    enum Kind { case permission, reply, delivery }
    let id: String
    let kind: Kind
    let agent: Agent
    let sessionID: String?
    let title: String
    let detail: String
    let date: Date
    /// El icono de la entrega (SF Symbol); las demás llevan la cara del agente.
    var symbol: String?
}

/// Lo que va en «Actividad», sacado del estado que YA tiene el teléfono.
///
/// ⚠️ `/me/events` sólo avisa «algo cambió» y no guarda nada, así que aquí no hay
/// historial: es una foto de ahora — permisos esperando, respuestas sin ver y lo que los
/// agentes entregaron en la última semana. Sale de las mismas filas que pinta Chats
/// (`ChatsView.rows`) para que las dos pantallas nunca se contradigan.
@MainActor
enum ActivityFeed {
    /// Hasta dónde mirar las entregas hacia atrás.
    static let deliveryWindow: TimeInterval = 7 * 86_400

    struct Sections {
        var waiting: [ActivityItem] = []
        var replies: [ActivityItem] = []
        var deliveries: [ActivityItem] = []
        var isEmpty: Bool { waiting.isEmpty && replies.isEmpty && deliveries.isEmpty }
        /// Lo que pide atención: el punto de la campanita. Las entregas no cuentan, no
        /// tienen «leído».
        var needsAttention: Bool { !waiting.isEmpty || !replies.isEmpty }
    }

    static func sections(_ store: LiveAgentStore, now: Date = Date()) -> Sections {
        var s = Sections()
        for row in ChatsView.rows(store) {
            if let ask = permission(row) {
                s.waiting.append(ActivityItem(id: "p-\(row.id)", kind: .permission, agent: row.agent,
                                              sessionID: row.session, title: row.title, detail: ask, date: row.date))
            } else if row.unreadCount > 0 {
                let text = row.preview.map { $0.fromUser ? "Tú: \($0.text)" : $0.text } ?? "Te contestó"
                s.replies.append(ActivityItem(id: "r-\(row.id)", kind: .reply, agent: row.agent,
                                              sessionID: row.session, title: row.title, detail: text, date: row.date))
            }
        }
        s.waiting.sort { $0.date > $1.date }
        s.replies.sort { $0.date > $1.date }

        let agents = Dictionary(store.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Lo que llegó en vivo y lo de la cuenta pueden ser LA MISMA entrega con dos ids
        // distintos (la de la cuenta trae el id del archivo): se juntan por agente,
        // conversación y título.
        var seen = Set<String>()
        let recent = (store.deliveries.deliveries + store.accountFiles)
            .filter { $0.isGenerated && now.timeIntervalSince($0.receivedAt) < deliveryWindow }
            .sorted { $0.receivedAt > $1.receivedAt }
        for d in recent {
            guard let agent = agents[d.agentID],
                  seen.insert("\(d.agentID)/\(d.sessionID ?? "")/\(d.title)").inserted else { continue }
            s.deliveries.append(ActivityItem(id: "d-\(d.id)", kind: .delivery, agent: agent,
                                             sessionID: d.sessionID, title: d.title,
                                             detail: "\(d.label) · \(agent.name)", date: d.receivedAt,
                                             symbol: d.icon))
        }
        return s
    }

    private static func permission(_ row: ChatsView.ChatRow) -> String? {
        switch row.kind {
        case .open(let thread):
            return thread.pendingPermission.map { $0.question.isEmpty ? "Espera tu permiso" : $0.question }
        case .saved(let session):
            return session.pendingPermission
        }
    }
}

/// La campanita de Chats. Sin número: un punto de la marca cuando algo te espera.
struct ActivityBell: View {
    let store: LiveAgentStore
    @Binding var isPresented: Bool

    var body: some View {
        let attention = ActivityFeed.sections(store).needsAttention
        Button { isPresented = true } label: {
            Image(systemName: "bell")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.gInk)
                .symbolEffect(.bounce, value: attention)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .cristalCircular()
                .overlay(alignment: .topTrailing) {
                    if attention {
                        Circle()
                            .fill(Color.gPrimary)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.gBg, lineWidth: 1.5))
                            .offset(x: -9, y: 9)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: attention)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attention ? "Actividad, hay algo nuevo" : "Actividad")
        .accessibilityIdentifier("chats-actividad")
    }
}

/// «Actividad»: permisos que esperan, respuestas sin ver y entregas recientes. Tocar una
/// línea cierra la hoja y abre su conversación; abrir la hoja no marca nada como leído.
struct ActivitySheet: View {
    let store: LiveAgentStore
    /// Se eligió una línea: quien presenta cierra la hoja y entra al hilo.
    var onOpen: (ActivityItem) -> Void

    var body: some View {
        let s = ActivityFeed.sections(store)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Actividad")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.gInk)
                    .padding(.top, 18)
                if s.isEmpty {
                    emptyState
                } else {
                    section("Te espera", s.waiting)
                    section("Nuevo", s.replies)
                    section("Entregas", s.deliveries)
                }
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color.gBg)
        .accessibilityIdentifier("hoja-actividad")
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ActivityItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.gInk3)
                    .padding(.bottom, 4)
                ForEach(items) { item in
                    Button { onOpen(item) } label: { row(item) }
                        .buttonStyle(.plain)
                        .disabled(item.sessionID == nil)
                        .accessibilityIdentifier("actividad-\(item.id)")
                }
            }
        }
    }

    private func row(_ item: ActivityItem) -> some View {
        HStack(spacing: 12) {
            leading(item)
                .frame(width: 36, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                Text(item.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(item.kind == .permission ? Color.gDangerInk : Color.gInk3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.date > .distantPast {
                Text(ChatsView.timeLabel(item.date))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.gInk3)
                    .fixedSize()
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func leading(_ item: ActivityItem) -> some View {
        if let symbol = item.symbol {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.gPrimary)
                .frame(width: 36, height: 36)
                .background(Color.gPrimaryRing, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            GhostyMascot(tone: item.agent.tone, height: 36)
                .overlay(alignment: .bottomTrailing) {
                    if item.kind == .permission {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background(Color.gDangerInk, in: Circle())
                            .overlay(Circle().stroke(Color.gBg, lineWidth: 1.5))
                    }
                }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.gInk3)
            Text("Todo al día")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.gInk)
            Text("Aquí verás lo que tus agentes te pidan o te entreguen.")
                .font(.system(size: 14))
                .foregroundStyle(Color.gInk3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
