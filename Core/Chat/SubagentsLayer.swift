#if os(iOS)
import SwiftUI
import UIKit

// POC de subagentes nativos (2026-10-07) DENTRO del chat oficial: una barra encima del
// compositor («3 agentes trabajando · 1:20») que abre la lista viva, el detalle de cada uno y
// Detener. El chat es el de siempre —suspensión, reenganche, steer, clavar arriba—; esto sólo
// MIRA la lista que manda la caja por gs (`…/conversations/:id/subagents`, staff) y le habla al
// subagente con el `send` normal del hilo. Sólo en Debug y sólo con los agentes cuya caja trae
// el POC. Ficha: ghosty-studio/docs/claude/subagentes-tipo-claude-code.md §9.

/// Lo que el vigilante de silencio mira del lector del stream.
@MainActor private final class StreamWatch {
    var lastData = Date()
    var ended = false
}

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
    private init() {}

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

    /// Mirar ESTA conversación. Cambiar de hilo vacía la lista y reengancha.
    func watch(agent: String, session: String?) {
        let key = session.map { "\(agent)/\($0)" }
        guard key != watching else { return }
        watching = key
        listener?.cancel()
        tasks = [:]; steps = [:]; connected = false; snapshotReceived = false; dismissed = []; unavailable = false
        guard let session, Self.hasSubagents(agent) else { return }
        listener = Task { [weak self] in await self?.listen(agent: agent, session: session) }
    }

    /// Volver del fondo: la conexión murió con la suspensión, se reabre (el snapshot del
    /// servidor pone la lista al día; nada se reconstruye a mano).
    func reconnect() {
        guard let m = watching else { return }
        let parts = m.split(separator: "/", maxSplits: 1).map(String.init)
        watching = nil
        // Lo que se ve se queda hasta que llegue el snapshot, que lo REEMPLAZA entero.
        let previous = (tasks, steps)
        watch(agent: parts[0], session: parts[1])
        (tasks, steps) = previous
    }

    /// Salir del chat (o de este agente): se deja de escuchar. Antes la conexión seguía viva y
    /// reintentando cada 1.5 s para siempre aunque ya nadie mirara (auditoría 7-oct, punto 8).
    func release() {
        listener?.cancel()
        listener = nil
        watching = nil
        connected = false
    }

    private static let httpSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 24 * 3600
        c.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        return URLSession(configuration: c)
    }()

    private func request(_ agent: String, _ session: String, _ suffix: String, method: String = "GET") async throws -> URLRequest {
        var r = URLRequest(url: Session.base.appendingPathComponent("api/v2/me/agents/\(agent)/conversations/\(session)/subagents\(suffix)"))
        r.httpMethod = method
        r.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        r.assumesHTTP3Capable = false
        return r
    }

    /// Quien mira el chat engancha aquí la recarga del hilo: el remate del agente lo guarda gs
    /// como un mensaje más y hay que traerlo.
    @ObservationIgnored var onThreadGrew: (() -> Void)?

    /// La lista como la da Claude Code: al conectarse, el SNAPSHOT completo desde gs (que la
    /// guarda; reemplaza lo que hubiera) y después los EVENTOS en vivo. Se reabre al volver del
    /// fondo (`reconnect`) y con espera creciente si se cae. Antes era la memoria de la caja y
    /// cada suspensión, reconexión o reinicio la dejaba tarde, vacía o «trabajando» para siempre.
    private func listen(agent: String, session: String) async {
        var delay = 1.0
        while !Task.isCancelled {
            do {
                let (bytes, resp) = try await Self.httpSession.bytes(for: try await request(agent, session, ""))
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                // 401/403/404 no se arreglan reintentando (no eres staff, no es tu conversación).
                if [401, 403, 404].contains(status) { connected = false; unavailable = true; return }
                if status == 200 {
                    connected = true
                    delay = 1.0
                    // ⚠️ Vigilante de silencio. Al volver de la suspensión la conexión puede quedar
                    // medio muerta: sin error y sin datos, y la lista se congelaba hasta reabrir la
                    // app (7-oct). gs manda un latido cada 15 s; 45 s sin nada = muerta, se reabre
                    // y el snapshot pone todo al día.
                    let watch = StreamWatch()
                    let reader = Task { @MainActor in
                        defer { watch.ended = true }
                        for try await line in bytes.lines {
                            watch.lastData = Date()
                            guard line.hasPrefix("data: "),
                                  let d = line.dropFirst(6).data(using: .utf8),
                                  let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                            apply(ev)
                        }
                    }
                    // Termina si el lector acabó (el servidor cerró) o si se quedó mudo.
                    while !Task.isCancelled, !watch.ended, Date().timeIntervalSince(watch.lastData) < 45 {
                        try? await Task.sleep(for: .seconds(5))
                    }
                    reader.cancel()
                }
            } catch {}
            connected = false
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
    }

    private func apply(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "snapshot":
            applyList((ev["tasks"] as? [[String: Any]]) ?? [])
            snapshotReceived = true
            #if DEBUG
            // Gancho del simulador: abre la hoja de subagentes en cuanto llega la lista.
            if ProcessInfo.processInfo.environment["GHOSTY_SUBAGENTES"] == "1", !tasks.isEmpty { isSheetOpen = true }
            #endif
        case "task":
            guard let t = ev["task"] as? [String: Any] else { return }
            upsert(t)
        case "thread": onThreadGrew?()
        default: break
        }
    }

    /// Un subagente cambió: se actualiza ése y nada más.
    private func upsert(_ t: [String: Any]) {
        guard let task = Self.task(t) else { return }
        let before = tasks[task.id]?.status
        #if canImport(UIKit)
        if before == "running" && task.status != "running" {
            UINotificationFeedbackGenerator().notificationOccurred(task.status == "completed" ? .success : .warning)
        } else if before == nil {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        #endif
        tasks[task.id] = task
        let fromServer = ((t["steps"] as? [[String: Any]]) ?? []).map {
            SubagentStep(kind: $0["kind"] as? String ?? "tool", text: $0["text"] as? String ?? "")
        }
        steps[task.id] = fromServer + (steps[task.id] ?? []).filter { $0.kind == "yo" }
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
                SubagentStep(kind: $0["kind"] as? String ?? "tool", text: $0["text"] as? String ?? "")
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
            model: t["model"] as? String, effort: t["effort"] as? String
        )
    }

    func stop(_ t: LiveSubagent) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
        guard let m = watching else { return }
        let parts = m.split(separator: "/", maxSplits: 1).map(String.init)
        Task {
            guard let r = try? await request(parts[0], parts[1], "/\(t.id)/stop", method: "POST") else { return }
            _ = try? await Self.httpSession.data(for: r)
        }
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

    func mode(at now: Date) -> SubagentsBarMode? {
        let running = layer.running
        if !running.isEmpty { return .running(count: running.count) }
        let recent = layer.finished.filter { now.timeIntervalSince($0.endedAt ?? now) < Self.finishedGrace }
        let problems = recent.filter { ($0.status == "failed" || $0.status == "stopped") && !layer.dismissed.contains($0.id) }
        if !problems.isEmpty { return .problems(ids: problems.map(\.id)) }
        let done = recent.filter { $0.status == "completed" && now.timeIntervalSince($0.endedAt ?? now) < Self.doneGrace }
        if !done.isEmpty { return .done(count: done.count) }
        if !layer.snapshotReceived, !layer.unavailable, delegatedInThread { return .loading }
        return nil
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
                                Label(s.text, systemImage: "wrench.and.screwdriver")
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
