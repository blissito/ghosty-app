import SwiftUI

/// Una línea de «Actividad»: algo que pasó mientras no mirabas.
struct ActivityItem: Identifiable {
    enum Kind { case permission, reply, delivery, factory, notice }
    let id: String
    let kind: Kind
    /// `nil` sólo en los pedidos de la Fábrica: son del espacio, no de un agente.
    let agent: Agent?
    let sessionID: String?
    let title: String
    let detail: String
    let date: Date
    /// El icono de la entrega (SF Symbol); las demás llevan la cara del agente.
    var symbol: String?
    /// El pedido de la Fábrica que espera tu decisión (firmar, decidir, mergear).
    var factoryRoute: FactoryRoute?
    /// El aviso guardado en gs (historial de push). Tocarlo hace lo mismo que tocar el push.
    var notice: NoticeItem?
    /// Pendiente según gs (ventas urgentes sin atender): va arriba con su marca.
    var pending = false
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
        /// Los push de los últimos 30 días que ya no esperan nada (`NoticeHistory`).
        var history: [ActivityItem] = []
        /// Cuántos avisos de gs siguen pendientes, sin contar permisos (ésos ya están en `waiting`).
        var serverPending = 0
        var isEmpty: Bool { waiting.isEmpty && replies.isEmpty && deliveries.isEmpty && history.isEmpty }
        /// El número de la campanita: lo que te espera en vivo + lo pendiente en gs. Las
        /// entregas y el historial no cuentan, no tienen «leído».
        var attentionCount: Int { waiting.filter { !$0.pending }.count + replies.count + serverPending }
        var needsAttention: Bool { attentionCount > 0 }
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
        // Los pedidos de la Fábrica que te toca decidir también te esperan.
        for space in FactoryStore.shared.spaces {
            for run in space.runs where run.needsYou {
                s.waiting.append(ActivityItem(id: "f-\(space.slug)-\(run.id)", kind: .factory, agent: nil,
                                              sessionID: nil, title: run.title, detail: factoryAsk(run),
                                              date: run.updated ?? .distantPast,
                                              factoryRoute: FactoryRoute(slug: space.slug, id: run.id)))
            }
        }
        s.waiting.sort { $0.date > $1.date }
        s.replies.sort { $0.date > $1.date }

        let agents = Dictionary(store.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // El historial de push de gs. Lo pendiente sube a «Te espera», debajo de lo vivo;
        // los permisos pendientes NO se repiten: el feed en vivo ya los trae.
        let history = NoticeHistory.shared
        s.serverPending = history.pendingNonPermission
        for n in history.items {
            let agent = n.agentID.flatMap { agents[$0] }
            let item = ActivityItem(id: "n-\(n.id)", kind: .notice, agent: agent, sessionID: n.sessionID,
                                    title: n.title, detail: n.body.isEmpty ? (agent?.name ?? "") : n.body,
                                    date: n.date,
                                    // Una respuesta de un agente conocido lleva su cara; lo demás, su símbolo.
                                    symbol: n.kind == "reply" && agent != nil ? nil : n.symbol,
                                    notice: n, pending: n.pending)
            if n.pending {
                if n.kind != "permission" { s.waiting.append(item) }
            } else {
                s.history.append(item)
            }
        }
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

    /// Lo que el pedido te pide, en una línea.
    static func factoryAsk(_ run: FactoryRun) -> String {
        switch run.stage {
        case .planReview: "Firma el plan v\(run.planVersion)"
        case .escalated: "@check frenó: toca decidir (¿Qué hago?)"
        case .prReview: run.prNumber.map { "Mergea el PR \($0)" } ?? "Mergea el PR"
        default: run.stage.label
        }
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

/// La campanita de Chats: el número de lo que te espera (en vivo + pendiente en gs).
struct ActivityBell: View {
    let store: LiveAgentStore
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = ActivityFeed.sections(store).attentionCount
        let attention = count > 0
        Button { isPresented = true } label: {
            Image(systemName: "bell")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.gInk)
                .symbolEffect(.bounce, value: reduceMotion ? false : attention)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .cristalCircular()
                .overlay(alignment: .topTrailing) {
                    if attention {
                        Text(count > 99 ? "99+" : "\(count)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color.gPrimary, in: Capsule())
                            .overlay(Capsule().stroke(Color.gBg, lineWidth: 1.5))
                            .offset(x: -4, y: 5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: count)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attention ? "Avisos, \(count) pendientes" : "Avisos")
        .accessibilityIdentifier("chats-actividad")
        // El número sale de gs desde que se pinta Chats, no sólo al abrir la hoja.
        .task { await NoticeHistory.shared.refresh() }
    }
}

/// «Avisos»: permisos y ventas que esperan, respuestas sin ver, entregas recientes y el
/// historial de push de 30 días. Tocar una línea cierra la hoja y la abre igual que el push;
/// abrir la hoja no marca nada como leído.
struct ActivitySheet: View {
    let store: LiveAgentStore
    /// Se eligió una línea: quien presenta cierra la hoja y entra al hilo.
    var onOpen: (ActivityItem) -> Void

    var body: some View {
        let s = ActivityFeed.sections(store)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Avisos")
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
                    section("Últimos 30 días", s.history)
                }
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color.gBg)
        .accessibilityIdentifier("hoja-actividad")
        .task { await NoticeHistory.shared.refresh() }
        .refreshable { await NoticeHistory.shared.refresh() }
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
                        .disabled(item.sessionID == nil && item.factoryRoute == nil && item.notice == nil)
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
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                        .lineLimit(1)
                    if item.pending {
                        Text("Pendiente")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.gAmberInk)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.gAmberTint, in: Capsule())
                            .fixedSize()
                    }
                }
                Text(item.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(item.kind == .permission ? Color.gDangerInk
                                     : item.kind == .factory || item.notice?.urgent == true ? Color.gAmberInk
                                     : Color.gInk3)
                    .lineLimit(item.kind == .notice ? 2 : 1)
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
            // Lo urgente de ventas, en el ámbar de «te toca»; lo demás, en la marca.
            let urgent = item.pending || item.notice?.urgent == true
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(urgent ? Color.gAmberInk : Color.gPrimary)
                .frame(width: 36, height: 36)
                .background(urgent ? Color.gAmberTint : Color.gPrimaryRing,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if item.kind == .factory {
            // El ícono de la pestaña Fábrica, en el ámbar de «te toca».
            GhostyIcons.fabrica.dibujo(.gAmberInk, size: 20)
                .frame(width: 36, height: 36)
                .background(Color.gAmberTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let agent = item.agent {
            GhostyMascot(tone: agent.tone, height: 36)
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
            Text("Aquí verás cada aviso de los últimos 30 días: lo que tus agentes te pidan, te entreguen o te avisen de ventas.")
                .font(.system(size: 14))
                .foregroundStyle(Color.gInk3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
