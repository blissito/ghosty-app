#if os(iOS)
import SwiftUI
import UIKit

// POC de subagentes nativos (2026-10-07) DENTRO del chat oficial: una barra encima del
// compositor («3 agentes trabajando · 1:20») que abre la lista viva, el detalle de cada uno y
// Detener. El chat es el de siempre —suspensión, reenganche, steer, clavar arriba—; esto sólo
// MIRA la lista y le habla al subagente con el `send` normal del hilo.
// Desde AG-UI (gs-agui 1, §0.5) la lista es `state.subagents.tasks` del stream del chat
// (STATE_SNAPSHOT/STATE_DELTA); fuera de un run se pide reconectando, y detener uno es
// `forwardedProps.stopSubagent`. Ficha: ghosty-studio/docs/claude/subagentes-tipo-claude-code.md §9.

struct LiveSubagent: Identifiable, Equatable {
    let id: String
    var title: String
    var status: String
    var startedAt: Date
    var endedAt: Date?
    var tokens: Int = 0
    var toolUses: Int = 0
    var lastTool: String?
    var summary: String?
    /// Con qué corre el hijo (id completo, p.ej. `claude-haiku-5-5`) y su effort.
    var model: String?
    var effort: String?
    /// ¿El padre ya tiene su resultado? (gs: el padre lo recogió con `load` o ya salió en un
    /// remate). `nil` = gs viejo que no lo manda.
    var delivered: Bool?

    /// «Haiku · xhigh»: nombre corto del modelo y effort en minúsculas; nil si no llegó nada.
    var engineLabel: String? {
        let short = model.map { m -> String in
            let l = m.lowercased()
            for name in ["haiku", "sonnet", "opus", "fable"] where l.contains(name) { return name.capitalized }
            return m
        }
        let parts = [short, effort?.lowercased()].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var isLive: Bool { status == "running" || status == "paused" }
    func elapsed(_ now: Date) -> TimeInterval { (endedAt ?? now).timeIntervalSince(startedAt) }
}

struct SubagentStep: Identifiable {
    let id = UUID()
    /// `tool` | `text` (del subagente) | `yo` (lo que le escribiste desde su detalle).
    let kind: String
    let text: String
    /// La clase de un paso `tool` (`web_search`, `read`…, como los `kind` de gs): elige el ícono.
    var toolClass: String? = nil
}

@MainActor @Observable
final class SubagentsLayer {
    /// Respaldo para un gs que todavía no manda `subagentesNativos`: sólo PowerGhosty.
    private static let fallbackAgents: Set<String> = ["cmuio5hq80001gb17mi7tki0c"]

    /// ¿Este agente tiene subagentes nativos? Lo dice gs por agente y por app (`/me/agents`).
    static func hasSubagents(_ agentID: String) -> Bool {
        if let flag = LiveAgentStore.compartido.nativeSubagents(of: agentID) { return flag }
        return fallbackAgents.contains(agentID)
    }

    /// Una para toda la app, creada una vez (ver el aviso de `SubagentesLab`: un `init` con
    /// efectos dentro de un `@State` re-evaluado trabó la app el 7-oct).
    static let shared = SubagentsLayer()
    private init() {
        // Todo `state` que traigan los streams del chat pasa por aquí; sólo cuenta el del hilo mirado.
        ClienteGS.alCambiarState = { agent, session, state in
            nonisolated(unsafe) let state = state
            Task { @MainActor in SubagentsLayer.shared.applyState(agent: agent, session: session, state) }
        }
    }

    private(set) var tasks: [String: LiveSubagent] = [:]
    private(set) var steps: [String: [SubagentStep]] = [:]
    private(set) var connected = false
    /// Ya llegó el snapshot de esta conversación. Antes, la barra enseña «Cargando…» si el hilo
    /// dice que el agente delegó (el esqueleto: se pinta lo que ya se sabe).
    private(set) var snapshotReceived = false
    /// gs contestó 403/404: este agente (o esta conversación) no tiene subagentes. La barra
    /// no se queda en «Cargando…» esperando un snapshot que no va a llegar.
    private(set) var unavailable = false
    /// Fallidos o detenidos que quitaste con la `x` (como en Claude Code).
    private(set) var dismissed: Set<String> = []

    @ObservationIgnored private var watching: String?
    @ObservationIgnored private var listener: Task<Void, Never>?

    var sorted: [LiveSubagent] { tasks.values.sorted { $0.startedAt > $1.startedAt } }
    var running: [LiveSubagent] { sorted.filter(\.isLive) }
    var finished: [LiveSubagent] { sorted.filter { !$0.isLive } }

    /// Mirar ESTA conversación. Cambiar de hilo vacía la lista y pide su estado.
    func watch(agent: String, session: String?) {
        let key = session.map { "\(agent)/\($0)" }
        guard key != watching else { return }
        watching = key
        listener?.cancel()
        tasks = [:]; steps = [:]; connected = false; snapshotReceived = false; dismissed = []; unavailable = false
        guard session != nil, Self.hasSubagents(agent) else { return }
        refresh()
    }

    /// Volver del fondo (o `/me/events` avisó que la conversación cambió): se pide el estado otra
    /// vez. Lo que se ve se queda hasta que llegue, que lo REEMPLAZA entero.
    func reconnect() { refresh() }

    /// `/me/events` avisó de esa conversación: un subagente pudo avanzar después del run (§0.5).
    func poke(agent: String, session: String) {
        if watching == "\(agent)/\(session)" { refresh() }
    }

    /// Salir del chat (o de este agente): se deja de mirar.
    func release() {
        listener?.cancel()
        listener = nil
        watching = nil
        connected = false
    }

    /// Reconectar (POST sin mensaje) y leer hasta el `STATE_SNAPSHOT`. Cortar después no detiene
    /// nada; lo que siga en vivo llega por el stream del chat (`STATE_DELTA`).
    private func refresh() {
        guard let m = watching else { return }
        let parts = m.split(separator: "/", maxSplits: 1).map(String.init)
        listener?.cancel()
        listener = Task { [weak self] in
            do {
                guard let state = try await ClienteGS(agentID: parts[0]).estado(de: parts[1]) else { return }
                nonisolated(unsafe) let s = state
                guard !Task.isCancelled else { return }
                self?.applyState(agent: parts[0], session: parts[1], s)
            } catch {
                // 403/404 no se arreglan reintentando (no es tu conversación, o no existe).
                if case ACPClient.Fallo.remoto = error { self?.unavailable = true }
                self?.connected = false
            }
        }
    }

    /// Quien mira el chat engancha aquí la recarga del hilo: el remate del agente lo guarda gs
    /// como un mensaje más y hay que traerlo.
    @ObservationIgnored var onThreadGrew: (() -> Void)?

    /// `state.subagents.tasks` (§0.5) de la conversación mirada: la lista ENTERA, que reemplaza a
    /// la que hay. Un subagente que termina suena como antes.
    func applyState(agent: String, session: String, _ state: [String: Any]) {
        guard watching == "\(agent)/\(session)" else { return }
        connected = true
        guard let sub = state["subagents"] as? [String: Any] else { return }
        let list = sub["tasks"] as? [[String: Any]] ?? []
        let before = tasks
        let hadSnapshot = snapshotReceived
        applyList(list)
        snapshotReceived = true
        #if canImport(UIKit)
        if hadSnapshot {
            for t in tasks.values {
                let was = before[t.id]?.status
                if was == "running" && t.status != "running" {
                    UINotificationFeedbackGenerator().notificationOccurred(t.status == "completed" ? .success : .warning)
                } else if was == nil {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
        #endif
        // El remate del padre llega como mensaje nuevo cuando un subagente termina.
        if before.values.contains(where: \.isLive), !tasks.values.contains(where: \.isLive) { onThreadGrew?() }
        #if DEBUG
        // Gancho del simulador: abre la hoja de subagentes en cuanto llega la lista.
        if ProcessInfo.processInfo.environment["GHOSTY_SUBAGENTES"] == "1", !tasks.isEmpty { isSheetOpen = true }
        #endif
    }

    /// La lista de gs REEMPLAZA a la que hay: es la verdad. Lo único local que se conserva es
    /// lo que le escribiste a cada uno desde su detalle.
    private func applyList(_ list: [[String: Any]]) {
        var fresh: [String: LiveSubagent] = [:]
        var freshSteps: [String: [SubagentStep]] = [:]
        for t in list {
            guard let task = Self.task(t) else { continue }
            fresh[task.id] = task
            let fromServer = ((t["steps"] as? [[String: Any]]) ?? []).map {
                SubagentStep(kind: $0["kind"] as? String ?? "tool", text: $0["text"] as? String ?? "",
                         toolClass: $0["class"] as? String)
            }
            freshSteps[task.id] = fromServer + (steps[task.id] ?? []).filter { $0.kind == "yo" }
        }
        tasks = fresh
        steps = freshSteps
    }

    private static func task(_ t: [String: Any]) -> LiveSubagent? {
        guard let id = t["id"] as? String else { return nil }
        let ms = { (k: String) -> Date? in (t[k] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
        let u = t["usage"] as? [String: Any]
        return LiveSubagent(
            id: id, title: t["title"] as? String ?? "Agente", status: t["status"] as? String ?? "running",
            startedAt: ms("startedAt") ?? .now, endedAt: ms("endedAt"),
            tokens: u?["tokens"] as? Int ?? 0, toolUses: u?["toolUses"] as? Int ?? 0,
            lastTool: t["lastTool"] as? String, summary: t["summary"] as? String,
            model: t["model"] as? String, effort: t["effort"] as? String,
            delivered: t["delivered"] as? Bool
        )
    }

    func stop(_ t: LiveSubagent) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
        guard let m = watching else { return }
        let parts = m.split(separator: "/", maxSplits: 1).map(String.init)
        Task { await ClienteGS(agentID: parts[0]).detenerSubagente(t.id, en: parts[1]) }
    }

    func dismiss(_ ids: [String]) { dismissed.formUnion(ids) }

    /// La hoja con la lista (el historial). La abren la barra y el botón de la cabecera.
    var isSheetOpen = false

    /// Lo que escribiste en su detalle, para verlo ahí mismo (al agente le llega por el hilo).
    func noteMine(_ t: LiveSubagent, _ texto: String) {
        steps[t.id, default: []].append(SubagentStep(kind: "yo", text: texto))
    }

    static func clock(_ s: TimeInterval) -> String {
        let n = max(0, Int(s)); return "\(n / 60):\(String(format: "%02d", n % 60))"
    }
}

// MARK: - Barra encima del compositor

struct SubagentsBar: View {
    let store: LiveAgentStore
    @State private var layer = SubagentsLayer.shared
    @Environment(\.scenePhase) private var phase
    /// Cuándo terminó el último y cuántos mensajes tenía el hilo entonces: si no ha llegado nada
    /// nuevo, el remate está en camino.
    @State private var finishedAt: (date: Date, messages: Int)?

    var body: some View {
        // ⚠️ VStack con un `Color.clear` de alto cero, NO un `Group`: un `Group` vacío no se
        // pinta y su `.task` NUNCA corre, así que la lista no se conectaba y la barra no salía
        // jamás (7-oct, «se perdió el drawer de agentes»).
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                if let mode = mode(at: ctx.date) {
                    bar(mode, now: ctx.date)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        // ⚠️ Entre que terminan y entra el remate pasaban ~30 s sin nada en pantalla: la barra
        // ya se había ido y se sentía colgado (bliss, 8-oct). Se anota ese momento.
        .onChange(of: layer.running.isEmpty) { _, idle in
            finishedAt = idle && !layer.finished.isEmpty ? (Date(), store.messages.count) : nil
        }
        .animation(.snappy, value: layer.tasks.count)
        .animation(.snappy, value: layer.snapshotReceived)
        .task(id: "\(store.selectedAgentID)/\(store.hiloActivo?.sesionID ?? "")") {
            let agent = store.selectedAgentID, session = store.hiloActivo?.sesionID
            // Llegó el remate (gs lo guardó en el hilo): se trae como trae un push. Nunca con un
            // turno en curso: ése lo pinta su propio stream.
            layer.onThreadGrew = { [store] in
                guard let session, store.currentTurn == nil else { return }
                Task { _ = await store.recogerYa(agente: agent, sesion: session) }
            }
            layer.watch(agent: agent, session: session)
        }
        .onChange(of: phase) { _, newPhase in if newPhase == .active { layer.reconnect() } }
        .onDisappear { layer.release() }
        .sheet(isPresented: $layer.isSheetOpen) {
            SubagentsSheet(layer: layer, store: store)
                // Nunca transparente (regla de Brenda, 7-oct).
                .presentationBackground(Color.gBg)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// Lo que dice la barra, como Claude Code: los que trabajan; los que terminaron BIEN se van y
/// queda «N listos» 30 s; los fallidos o detenidos se quedan 30 s con `x`; y mientras llega la
/// lista, «Cargando…» si el hilo dice que el agente delegó.
enum SubagentsBarMode: Equatable {
    case loading
    case running(count: Int)
    case problems(ids: [String])
    case done(count: Int)
    /// Ya terminaron y el remate todavía no entra al hilo (gs lo arma con un turno aparte).
    case wrapping(count: Int)
}

extension SubagentRow {
    /// «listo · 1,240 tokens · 3 herramientas», sin los ceros: «0 tokens · 0 herramientas» se
    /// leía como algo roto (bliss, 8-oct).
    static func rowDetail(_ t: LiveSubagent) -> String {
        var parts = [stateLabel(t.status)]
        if t.tokens > 0 { parts.append("\(thousands(t.tokens)) tokens") }
        if t.toolUses > 0 { parts.append("\(t.toolUses) \(t.toolUses == 1 ? "herramienta" : "herramientas")") }
        return parts.joined(separator: " · ")
    }
}

extension SubagentsBar {
    /// Cuánto se quedan a la vista los que fallaron o se detuvieron: piden atención (30 s, con ✕).
    static let finishedGrace: TimeInterval = 30
    /// Los que terminaron bien se van rápido (bliss, 8-oct; igual que Android `DONE_GRACE_MS`).
    static let doneGrace: TimeInterval = 5
    /// Lo más que se espera el remate con el aviso puesto (gs lo arma en ~20–40 s; si el padre
    /// ya lo entregó, gs no manda nada y el aviso se va solo).
    static let wrapGrace: TimeInterval = 60

    /// ¿Ya entró el remate desde que terminaron? Lo anuncia la línea del despertador («⏰ … ghostyllos»,
    /// que aquí es `.sistema`) o el mensaje con el encabezado de ayudantes.
    /// ⚠️ No se mira «cuándo cierra el turno»: el remate llega con un turno propio cuya burbuja en vivo
    /// aún no trae el encabezado, y la barra se quedaba trabada en «Juntando…» (bliss, 8-oct).
    func wrapArrived(after count: Int) -> Bool {
        store.messages.dropFirst(count).contains { m in
            switch m.kind {
            case .sistema: return true
            case .agent(let t, _, _): return HelpersHeader.split(t) != nil
            default: return false
            }
        }
    }

    func mode(at now: Date) -> SubagentsBarMode? {
        let running = layer.running
        if !running.isEmpty { return .running(count: running.count) }
        let recent = layer.finished.filter { now.timeIntervalSince($0.endedAt ?? now) < Self.finishedGrace }
        let problems = recent.filter { ($0.status == "failed" || $0.status == "stopped") && !layer.dismissed.contains($0.id) }
        if !problems.isEmpty { return .problems(ids: problems.map(\.id)) }
        // El remate todavía no entra: lo mismo que «listo», pero diciendo que se está armando.
        // Fuente de verdad: gs dice por hijo si el padre ya tiene su resultado (`delivered`: lo
        // recogió con `load` o ya salió en el remate). «Juntando…» = terminados que el padre aún
        // no tiene; cuando gs los marca, la barra se va sola. Sin mirar el hilo ni relojes.
        // ⚠️ Pero `delivered` puede quedarse en false para siempre (gs no lo marcó tras el remate):
        // la barra seguía en «Juntando…» seis horas después, con el remate ya en el hilo (bliss,
        // 8-oct). Por eso también se va si el último mensaje del agente ya es el remate o si pasó
        // el tope desde que terminaron.
        if layer.finished.contains(where: { $0.delivered != nil }) {
            let pending = layer.finished.filter {
                $0.delivered == false && $0.status == "completed"
                    && now.timeIntervalSince($0.endedAt ?? now) < Self.wrapGrace
            }.count
            if pending > 0, store.currentTurn == nil, !lastIsWrap,
               finishedAt.map({ !wrapArrived(after: $0.messages) }) ?? true {
                return .wrapping(count: pending)
            }
        } else if let f = finishedAt, store.currentTurn == nil, !wrapArrived(after: f.messages),
                  now.timeIntervalSince(f.date) < Self.wrapGrace {
            // gs que todavía no manda `delivered`: se infiere por el hilo, con tope.
            let n = layer.finished.filter { now.timeIntervalSince($0.endedAt ?? now) < Self.wrapGrace }.count
            if n > 0 { return .wrapping(count: n) }
        }
        let done = recent.filter { $0.status == "completed" && now.timeIntervalSince($0.endedAt ?? now) < Self.doneGrace }
        if !done.isEmpty { return .done(count: done.count) }
        if !layer.snapshotReceived, !layer.unavailable, delegatedInThread { return .loading }
        return nil
    }

    /// ¿El último mensaje del agente ya es el remate (trae el encabezado de ayudantes)? Sirve al
    /// reabrir la conversación, cuando no hay `finishedAt` con qué comparar.
    private var lastIsWrap: Bool {
        guard let m = store.messages.last(where: { if case .agent = $0.kind { return true }; return false }),
              case .agent(let t, _, _) = m.kind else { return false }
        return HelpersHeader.split(t) != nil
    }

    /// ¿El hilo dice que el agente lanzó subagentes? (la tool `Agent`, ver `Herramienta.isDelegation`).
    private var delegatedInThread: Bool {
        store.messages.suffix(8).contains { m in
            if case .agent(_, let tools, _) = m.kind { return tools?.herramientas.contains(where: \.isDelegation) == true }
            return false
        }
    }

    @ViewBuilder
    func bar(_ mode: SubagentsBarMode, now: Date) -> some View {
        HStack(spacing: 10) {
            switch mode {
            case .loading:
                ProgressView().controlSize(.small).tint(.white)
                label("Cargando agentes…")
            case .running(let n):
                SubagentStatusDot(status: "running")
                label("\(n) agente\(n == 1 ? "" : "s") trabajando")
                Spacer()
                if let longest = layer.running.map({ $0.elapsed(now) }).max() {
                    Text(SubagentsLayer.clock(longest))
                        .font(.system(size: 14).monospacedDigit()).foregroundStyle(Color.gDarkInk2)
                }
            case .problems(let ids):
                SubagentStatusDot(status: "stopped")
                label("\(ids.count) sin terminar")
                Spacer()
                Button { withAnimation(.snappy) { layer.dismiss(ids) } } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.gDarkInk2)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quitar")
            case .done(let n):
                SubagentStatusDot(status: "completed")
                label("\(n) listo\(n == 1 ? "" : "s") · ver")
            case .wrapping(let n):
                ProgressView().controlSize(.small).tint(.white)
                label(n == 1 ? "Juntando lo que trajo tu ghostyllo…" : "Juntando lo que trajeron tus \(n) ghostyllos…")
            }
            if case .running = mode {} else { Spacer() }
            Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.gDarkInk2)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.gDark, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if mode != .loading { layer.isSheetOpen = true } }
        .accessibilityIdentifier("barra-subagentes")
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
    }
}

struct SubagentStatusDot: View {
    let status: String
    var body: some View {
        let color: Color = switch status {
        case "running": .gPrimaryLight
        case "completed": .gGreen
        case "failed": .gDanger
        default: .gBird
        }
        Image(systemName: "circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: status == "running")
    }
}

// MARK: - Hoja con la lista

private struct SubagentsSheet: View {
    let layer: SubagentsLayer
    let store: LiveAgentStore

    var body: some View {
        NavigationStack {
            List {
                if !layer.running.isEmpty {
                    Section("Trabajando") { ForEach(layer.running) { row($0) } }
                }
                if !layer.finished.isEmpty {
                    Section("Terminados") { ForEach(layer.finished) { row($0) } }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.gBg)
            .navigationTitle("Agentes")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in SubagentDetail(layer: layer, store: store, id: id) }
            .animation(.snappy, value: layer.sorted)
        }
    }

    private func row(_ t: LiveSubagent) -> some View {
        NavigationLink(value: t.id) { SubagentRow(t: t) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if t.isLive {
                    Button(role: .destructive) { layer.stop(t) } label: { Label("Detener", systemImage: "stop.fill") }
                }
            }
    }

    static func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

private struct SubagentRow: View {
    let t: LiveSubagent
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(alignment: .top, spacing: 12) {
                SubagentStatusDot(status: t.status).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(t.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.gInk).lineLimit(1)
                        Spacer()
                        // Sutil, junto al reloj: con qué modelo y effort corre.
                        if let engine = t.engineLabel {
                            Text(engine).font(.system(size: 12)).foregroundStyle(Color.gInk3).lineLimit(1).layoutPriority(1)
                        }
                        Text(SubagentsLayer.clock(t.elapsed(ctx.date)))
                            .font(.system(size: 13).monospacedDigit()).foregroundStyle(Color.gInk3)
                    }
                    if let sub = (t.isLive ? (t.summary ?? t.lastTool) : t.lastTool) {
                        Text(sub).font(.system(size: 13)).foregroundStyle(Color.gInk2).lineLimit(1)
                    }
                    Text(Self.rowDetail(t))
                        .font(.system(size: 12)).foregroundStyle(Color.gInk3)
                }
            }
            .padding(.vertical, 4)
        }
    }

    static func stateLabel(_ s: String) -> String {
        ["running": "trabajando", "completed": "listo", "failed": "falló", "stopped": "detenido", "paused": "en pausa"][s] ?? s
    }
    static func thousands(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
}

// MARK: - Detalle: pasos en vivo, hablarle y detener

private struct SubagentDetail: View {
    let layer: SubagentsLayer
    let store: LiveAgentStore
    let id: String
    @State private var draft = ""

    var body: some View {
        let t = layer.tasks[id]
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let t { SubagentRow(t: t).padding(.bottom, 6) }
                        ForEach(layer.steps[id] ?? []) { s in
                            if s.kind == "yo" {
                                Text(s.text).font(.system(size: 15)).foregroundStyle(Color.gInk)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Color.gBubbleUser, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            } else if s.kind == "tool" {
                                Label(s.text, systemImage: Herramienta.Clase(s.toolClass).icono)
                                    .font(.system(size: 13)).foregroundStyle(Color.gInk3).lineLimit(2)
                            } else {
                                Text(s.text).font(.system(size: 15)).foregroundStyle(Color.gInkBody)
                            }
                        }
                        if let t, !t.isLive, let s = t.summary {
                            Text(SubagentsSheet.md(s)).font(.system(size: 15)).foregroundStyle(Color.gInk)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.gFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        Color.clear.frame(height: 1).id("fin")
                    }
                    .padding(16)
                }
                .onChange(of: layer.steps[id]?.count) { _, _ in withAnimation { proxy.scrollTo("fin") } }
            }
            if let t, t.isLive {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Escríbele a este agente…", text: $draft)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color.gFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        Button("Enviar") {
                            let v = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !v.isEmpty else { return }
                            draft = ""
                            layer.noteMine(t, v)
                            // Por el hilo, con el envío de siempre (steer si el agente trabaja):
                            // el principal se lo pasa con SendMessage (lo pide su prompt).
                            Task { await store.send("Para «\(t.title)»: \(v)", adjuntos: []) }
                        }
                        .font(.system(size: 15, weight: .semibold))
                    }
                    Button(role: .destructive) { layer.stop(t) } label: {
                        Text("Detener").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.gDangerTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(Color.gDangerInk)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
            }
        }
        .background(Color.gBg)
        .navigationTitle(t?.title ?? "Agente")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#endif
