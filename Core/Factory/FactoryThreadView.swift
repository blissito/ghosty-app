import SwiftUI

/// Un pedido mientras está con @plan: una conversación corta que termina en algo que se firma con el
/// pulgar. @plan no siempre arma un plan (bliss, 19-oct: «se manda el pedido pero nada regresa»):
///
/// - **plan** → nace el run: tarjeta «Plan listo para firmar» y, si llegó mientras mirabas, la
///   pantalla pasa sola al pedido para firmarlo;
/// - **sprint** (objetivo grande) → la tarjeta del sprint, que se revisa y se crea con una firma;
/// - **ideas** (`gt-asks`) → tarjetas con «Pedir», cada una un pedido nuevo;
/// - **pregunta** (`ask-user` o texto) → sus opciones como botones y el compositor abajo.
///
/// Mientras trabaja se ven sus pasos en vivo, igual que en el chat. Se repregunta cada 3 s mientras
/// @plan trabaja o no ha contestado; si no, cada 12 s.
struct FactoryThreadView: View {
    let slug: String
    let room: String
    let threadId: Int
    @Binding var path: [FactoryRoute]

    @State private var thread: FactoryThread?
    @State private var error: String?
    @State private var draft = ""
    @State private var sending = false
    /// Lo que mandé y todavía no regresa del servidor (se ve al instante).
    @State private var echo: [String] = []
    @State private var asked: Set<String> = []
    @State private var arrived = 0
    @FocusState private var composing: Bool

    private var waiting: Bool {
        guard let thread else { return true }
        return thread.working || thread.lastReply == nil || !echo.isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    request
                    if let thread {
                        ForEach(thread.messages) { m in
                            if m.byAgent { agentMessage(m) } else { personBubble(FactoryAPI.withoutPlanMention(m.body)) }
                        }
                    }
                    ForEach(echo, id: \.self) { personBubble($0).opacity(0.7) }
                    if waiting, thread?.messages.last?.live != true { thinking }
                    if let run = thread?.run { runCard(run) }
                    if let sprint = thread?.sprint { sprintCard(sprint) }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Color.gDangerInk) }
                    Color.clear.frame(height: 1).id("fin")
                }
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread?.messages.count) { _, _ in withAnimation(.snappy) { proxy.scrollTo("fin", anchor: .bottom) } }
            .onChange(of: echo.count) { _, _ in withAnimation(.snappy) { proxy.scrollTo("fin", anchor: .bottom) } }
        }
        .background(Color.gBg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("#\(room)")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: arrived)
        .task { await poll() }
        .accessibilityIdentifier("hilo-pedido")
    }

    // MARK: - Piezas

    private var request: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tu pedido").gSectionCaps()
            Text(FactoryAPI.withoutPlanMention(thread?.root.body ?? FactoryStore.shared.pendingThreads.first { $0.threadId == threadId }?.text ?? ""))
                .font(.system(size: 16, weight: .medium)).foregroundStyle(Color.gInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostyCard()
    }

    private func personBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 50)
            Text(text).font(.system(size: 15)).foregroundStyle(Color.gInk)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(Color.gPrimaryTint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func planHeader(live: Bool) -> some View {
        HStack(spacing: 8) {
            TintedIcon(systemName: "doc.text", tint: .gPrimary, background: .gPrimaryTint, size: 26)
            Text("@plan").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.gInk)
            if live { PulsingDot(color: .gPrimary, active: true, size: 6) }
        }
    }

    @ViewBuilder
    private func agentMessage(_ m: FactoryThread.Message) -> some View {
        let r = FactoryReply(m.body)
        VStack(alignment: .leading, spacing: 10) {
            planHeader(live: m.live)
            if !r.tools.isEmpty { steps(r.tools, live: m.live) }
            if !r.text.isEmpty {
                GhostyMarkdown(markdown: r.text)
                    .accessibilityIdentifier("respuesta-plan")
            }
            if let ask = m.ask { askOptions(ask) }
            if !r.ideas.isEmpty { ideas(r.ideas, room: r.ideasRoom ?? room) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gIn()
    }

    /// Los pasos: los últimos 3 a la vista; con más, «N pasos antes» arriba.
    private func steps(_ tools: [Herramienta], live: Bool) -> some View {
        let shown = Array(tools.suffix(3))
        return VStack(alignment: .leading, spacing: 7) {
            if tools.count > shown.count {
                Text("\(tools.count - shown.count) pasos antes").gCaption()
            }
            ForEach(shown) { FilaDePaso(h: $0) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(live ? "pasos-en-vivo" : "pasos")
    }

    private func askOptions(_ ask: FactoryThread.Ask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let answered = ask.answered ?? echo.first(where: { ask.options.contains($0) }) {
                Label(answered, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gGreenInk)
            } else {
                FlowRow(spacing: 8) {
                    ForEach(ask.options, id: \.self) { o in
                        Button { Task { await send(o) } } label: {
                            Text(o).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gPrimary)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(Color.gPrimaryTint, in: Capsule())
                        }
                        .buttonStyle(.gPressPill)
                        .disabled(sending)
                        .accessibilityIdentifier("opcion-\(o)")
                    }
                }
            }
        }
    }

    private func ideas(_ items: [FactoryReply.Idea], room: String) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, idea in
                let done = asked.contains(idea.ask)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if let size = idea.size { sizePill(size) }
                        Text(idea.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk)
                        Spacer(minLength: 0)
                    }
                    Text(idea.ask).font(.system(size: 14)).foregroundStyle(Color.gInk2).fixedSize(horizontal: false, vertical: true)
                    if let why = idea.why { Text(why).gCaption() }
                    Button { Task { await request(idea, room: room) } } label: {
                        Label(done ? "Pedido" : "Pedir", systemImage: done ? "checkmark" : "arrow.up.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(done ? Color.gGreenInk : .white)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(done ? Color.gGreenTint : Color.gPrimary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.gPressPrimary)
                    .disabled(done || sending)
                    .accessibilityIdentifier("pedir-idea-\(i)")
                }
                .padding(14)
                .ghostyCard()
            }
        }
    }

    private func sizePill(_ s: String) -> some View {
        let label = ["chico": "Chico", "mediano": "Mediano", "grande": "Grande", "S": "S", "M": "M", "L": "L"][s] ?? s
        let tone: (Color, Color) = s == "grande" || s == "L" ? (.gAmberInk, .gAmberTint) : s == "mediano" || s == "M" ? (.gPrimaryPressed, .gPrimaryTint) : (.gGreenInk, .gGreenTint)
        return Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(tone.0)
            .padding(.horizontal, 7).frame(height: 20)
            .background(tone.1, in: Capsule())
    }

    /// @plan todavía no dice nada: que se note que alguien trabaja, no una pantalla muerta.
    private var thinking: some View {
        HStack(spacing: 10) {
            planHeader(live: true)
            Text(thread?.lastReply == nil ? "está leyendo tu repo…" : "está trabajando…")
                .font(.system(size: 14)).foregroundStyle(Color.gInk3)
                .phaseAnimator([0.45, 1]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.9) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hilo-trabajando")
    }

    private func runCard(_ run: FactoryThread.Run) -> some View {
        let ready = run.status == "plan_review"
        return Button { path.append(FactoryRoute(slug: slug, id: run.id)) } label: {
            HStack(spacing: 12) {
                TintedIcon(systemName: ready ? "signature" : "shippingbox", tint: ready ? .gAmberInk : .gPrimary,
                           background: ready ? .gAmberTint : .gPrimaryTint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ready ? "Plan listo para firmar" : "Pedido #\(run.id)").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.gInk)
                    Text(run.title ?? "Ábrelo para ver en qué va").gMeta().lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.gInk4)
            }
            .padding(14)
            .ghostyCard()
        }
        .buttonStyle(.gPressRow)
        .accessibilityIdentifier("plan-listo")
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private func sprintCard(_ s: FactorySprint) -> some View {
        Button { path.append(FactoryRoute(slug: slug, target: .sprint(s.id))) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TintedIcon(systemName: "square.stack.3d.up", tint: .gPrimary, background: .gPrimaryTint, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.isDraft ? "Sprint propuesto" : "Sprint en marcha").gSectionCaps()
                        Text(s.title).font(.system(size: 16, weight: .bold)).foregroundStyle(Color.gInk).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(s.items.prefix(4)) { it in
                        HStack(spacing: 8) {
                            Text(it.key).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Color.gInk3).frame(width: 24, alignment: .leading)
                            Text(it.title).font(.system(size: 14)).foregroundStyle(it.included ? Color.gInk : Color.gInk4).strikethrough(!it.included).lineLimit(1)
                        }
                    }
                    if s.items.count > 4 { Text("y \(s.items.count - 4) más").gCaption() }
                }
                Text(s.isDraft ? "Revisar y crear · \(s.included.count) tickets" : "\(s.merged) de \(s.included.count) con merge")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(14)
            .ghostyCard()
        }
        .buttonStyle(.gPressRow)
        .accessibilityIdentifier("abrir-sprint")
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Contéstale a @plan", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composing)
                .font(.system(size: 16))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.gFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityIdentifier("contestar-plan")
            Button { let t = draft; draft = ""; Task { await send(t) } } label: {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.gPrimary, in: Circle())
            }
            .buttonStyle(.gPressIcon)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            .accessibilityIdentifier("mandar-respuesta")
        }
        .padding(.horizontal, Theme.Space.screenH).padding(.vertical, 8)
        .background(Color.gBg)
    }

    // MARK: - Datos

    private func load() async {
        let before = thread
        let t: FactoryThread?
        if DemoData.encendido {
            t = FactoryStore.demoThread(threadId)
        } else {
            do { t = try await FactoryAPI.thread(slug, room: room, id: threadId); error = nil }
            catch { self.error = error.localizedDescription; return }
        }
        guard let t else { return }
        FactoryStore.shared.noteThread(t, id: threadId)
        // Lo que mandé ya está en el hilo: se quita el eco.
        echo.removeAll { e in t.messages.contains { !$0.byAgent && FactoryAPI.withoutPlanMention($0.body) == e } }
        withAnimation(.snappy(duration: 0.3)) { thread = t }
        // Contestó (o nació el plan) mientras mirabas.
        if let before, (before.lastReply?.id != t.lastReply?.id && t.lastReply?.live == false) || (before.run == nil && t.run != nil) || (before.sprint == nil && t.sprint != nil) {
            arrived += 1
        }
        // El plan nació mientras mirabas: a firmarlo. Si ya estaba, se queda la tarjeta.
        if let before, before.run == nil, let run = t.run, run.status == "plan_review", path.last?.target == .thread(room: room, id: threadId) {
            try? await Task.sleep(for: .seconds(1.2))
            path.append(FactoryRoute(slug: slug, id: run.id))
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(waiting ? 3 : 12))
        }
    }

    private func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        withAnimation(.snappy) { echo.append(text) }
        if DemoData.encendido {
            FactoryStore.demoAnswers[threadId] = text
            try? await Task.sleep(for: .seconds(1.5))
            await load()
            return
        }
        do {
            try await FactoryAPI.reply(slug, room: room, id: threadId, text: text)
            await load()
        } catch {
            echo.removeAll { $0 == text }
            draft = text
            self.error = error.localizedDescription
        }
    }

    /// «Pedir» una idea: un pedido nuevo en su propio hilo, que se abre encima.
    private func request(_ idea: FactoryReply.Idea, room: String) async {
        sending = true
        defer { sending = false }
        let text = (idea.repo.map { "(repo \($0)) " } ?? "") + idea.ask
        do {
            let r: FactoryAPI.NewRun = DemoData.encendido
                ? .init(room: room, threadId: 9005, url: nil)
                : try await FactoryAPI.create(slug, room: room, repo: nil, text: text)
            asked.insert(idea.ask)
            FactoryStore.shared.addPending(slug: slug, room: r.room, threadId: r.threadId, text: idea.ask)
            path.append(FactoryRoute(slug: slug, target: .thread(room: r.room, id: r.threadId)))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension FactoryAPI {
    /// «@plan arma…» → «arma…»: la mención es para Teams, no para leerla.
    static func withoutPlanMention(_ s: String) -> String {
        s.replacingOccurrences(of: #"^\s*@plan\b\s*"#, with: "", options: .regularExpression)
    }
}

/// Botones que se acomodan en renglones (las opciones de una pregunta).
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > 0, x + d.width > width { y += row + spacing; x = 0; row = 0 }
            x += d.width + spacing
            row = max(row, d.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + d.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(d))
            x += d.width + spacing
            row = max(row, d.height)
        }
    }
}
