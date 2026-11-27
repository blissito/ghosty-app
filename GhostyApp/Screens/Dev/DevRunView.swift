import SwiftUI

/// Un pendiente abierto: encabezado (fase, deploy sólo tras el merge, etapas) y cuatro pestañas.
/// La caja «Dile al agente qué ajustar…» está en toda fase viva; Merge sólo se activa en «listo».
struct DevRunView: View {
    let id: String
    @State private var store = DevStore.shared
    // Gancho: `GHOSTY_DEV_TAB=changes|checks|activity` abre esa pestaña.
    @State private var tab: Tab = Tab.allCases.first { "\($0)" == Gancho.valor("GHOSTY_DEV_TAB") } ?? .chat
    @State private var sending = false
    @State private var notice: String?
    @State private var confirmStop = false
    /// Una acción del servidor con `confirm`, esperando el sí de la persona.
    @State private var pendingAction: DevAction?
    @State private var formAction: DevAction?
    @State private var readText: DevReadText?
    @State private var runningID: String?
    /// PR sin DevRun: el merge y el cierre son irreversibles, piden confirmación.
    @State private var confirmMerge = false
    @State private var confirmClose = false
    /// Lo que se está escribiendo para el agente de la terminal (hilo del PR).
    @State private var draft = ""
    @State private var envOpen = false
    @State private var shareOpen = false
    @State private var busyOp: String?
    @State private var confirmOp: String?
    @State private var chats = LiveAgentStore.compartido
    /// El hilo `dev:<id>` enfocado en el store de chats; al salir se regresa a lo de antes.
    @State private var devFocus: LiveAgentStore.DevFocus?
    @Environment(\.openURL) private var openURL

    enum Tab: String, CaseIterable { case chat = "Conversación", changes = "Cambios", checks = "Verificación", activity = "Actividad" }

    private var run: DevRun? { store.full[id] ?? store.row(id) }
    /// El turno del escritor sigue vivo (el mismo dato que pinta ■ en el chat).
    private var writerBusy: Bool { devFocus?.devThread.trabajando == true }
    private var detail: DevDetail? { store.details[id] }

    private var title: String {
        if let pr = run?.pr { return "PR #\(pr)" }
        if let issue = run?.issue, issue > 0 { return "Issue #\(issue)" }
        return "Pendiente"
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    var body: some View {
        core.alert(notice ?? "", isPresented: noticeShown) { Button("OK", role: .cancel) {} }
    }

    /// Los modales de las operaciones de PR (variables, compartir, confirmar), aparte del cuerpo para no ahogar al compilador.
    private var prModals: some View {
        framed
        .confirmationDialog(opCopy(confirmOp).title, isPresented: Binding(get: { confirmOp != nil }, set: { if !$0 { confirmOp = nil } }), titleVisibility: .visible) {
            Button(opCopy(confirmOp).button) { if let o = confirmOp { Task { await runPROp(o) } } }
        }
        .sheet(isPresented: $envOpen) {
            FactoryEnvSheet(repo: run?.repo, names: detail?.missingEnv ?? []) { dotenv in
                let err = await store.saveEnv(repo: run?.repo ?? "", dotenv: dotenv)
                if err == nil { _ = await store.prOp(id, "preview"); notice = "Variables guardadas: rearmando la vista previa." }
                return err
            }
        }
        .sheet(isPresented: $shareOpen) { DevShareSheet(id: id, store: store) }
        .sheet(item: $formAction) { a in
            DevActionFormSheet(action: a) { v in
                guard let run else { return "No encontré el pendiente." }
                switch await store.perform(a, repo: run.repo, issue: run.issue, pr: run.pr, runID: id, values: v) {
                case .failed(let m): return m
                default: notice = "Listo: \(a.label.lowercased())."; return nil
                }
            }
        }
        .sheet(item: $readText) { DevReadSheet(item: $0) }
    }

    @ViewBuilder private var core: some View {
        prModals
        .confirmationDialog("¿Detener este pendiente?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Detener", role: .destructive) { Task { await act("stop") } }
        } message: { Text("El agente deja de trabajar en él. El PR se queda como está.") }
        .confirmationDialog(pendingAction?.confirm ?? "", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            if let a = pendingAction { Button(a.label, role: a.destructive ? .destructive : nil) { Task { await runAction(a) } } }
        }
        .confirmationDialog("¿Hacer merge de este PR?", isPresented: $confirmMerge, titleVisibility: .visible) {
            Button("Merge") { Task { await act("merge") } }
        } message: { Text("Entra a la rama base. No se puede deshacer desde la app.") }
        .confirmationDialog("¿Cerrar el PR sin merge?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Cerrar sin merge", role: .destructive) { Task { await act("close") } }
        } message: { Text("Se cierra el PR sin hacer merge.") }
        .task(id: detail?.writerSessionID) { focusWriter() }
        .onDisappear { releaseWriter() }
        .task(id: id) {
            await store.loadDetail(id)
            // Mientras esté vivo, se refresca solo (como la web): cada 15 s.
            while !Task.isCancelled, run?.isLive == true {
                try? await Task.sleep(for: .seconds(15))
                await store.loadDetail(id)
            }
        }
    }

    private var framed: some View {
        content
            .background(Color.gBg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { moreMenu } }
    }

    @ViewBuilder private var moreMenu: some View {
        if let run {
            Menu {
                // Con `actions` de gs, el menú es lo que el servidor dejó (menos la principal, que va en el encabezado).
                if let acts = run.actions {
                    ForEach(acts.filter { $0.id != headerAction(run)?.id }) { a in
                        Button(a.label, role: a.destructive ? .destructive : nil) { tap(a) }.disabled(a.isDisabled || sending)
                    }
                }
                if run.actions == nil, let u = run.prURL { Button(run.isPR && run.readyToMerge ? "Hacer merge en GitHub" : "Abrir el PR en GitHub", systemImage: "arrow.up.right.square") { openURL(u) } }
                if let sh = detail?.sheet, sh.previewState == "ready", let u = sh.previewURL { Button("Ver la vista previa", systemImage: "safari") { openURL(u) } }
                if run.actions == nil, run.isLive, !run.isPR { Button("Detener", systemImage: "stop.circle", role: .destructive) { confirmStop = true } }
                // Respaldo (gs sin `actions`): un PR sin run se opera por su ruta de PR.
                if run.actions == nil, run.isPR, run.isLive {
                    Button("Rearmar la vista previa", systemImage: "arrow.clockwise") { Task { await act("preview") } }
                    Button("Pedir revisión de Ghosty", systemImage: "checkmark.shield") { Task { await act("review") } }
                    Button("Cerrar sin merge", systemImage: "xmark.circle", role: .destructive) { confirmClose = true }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private func focusWriter() {
        guard devFocus == nil, let a = detail?.writerAgentID, let sid = detail?.writerSessionID else { return }
        devFocus = chats.focusDevThread(agent: a, session: sid)
    }

    private func releaseWriter() {
        guard let f = devFocus else { return }
        chats.releaseDevThread(f)
        devFocus = nil
    }

    @ViewBuilder private var content: some View {
        if let run {
            // Los datos del pendiente y las pestañas quedan fijos arriba; sólo se desplaza el contenido.
            VStack(alignment: .leading, spacing: 12) {
                pinnedTop(run)
                if tab == .chat { chatTab(run) } else { scrollingTab(run) }
            }
        } else {
            FlameLoading().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pinnedTop(_ run: DevRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(run)
            Picker("Vista", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0 == .chat && run.isPR ? "Comentarios" : $0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, Theme.Space.screenH)
    }

    private func scrollingTab(_ run: DevRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch tab {
                case .chat: EmptyView()
                case .changes: changesTab
                case .checks: checksTab(run)
                case .activity: activityTab(run)
                }
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.loadDetail(id) }
    }

    // MARK: Encabezado

    /// En Conversación el encabezado se compacta (título en una línea, sin nota): ahí lo que importa es el hilo.
    @ViewBuilder private func header(_ run: DevRun) -> some View {
        let compact = tab == .chat
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if !compact { Text(run.repo).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.gInk3) }
            Text(run.title).font(.system(size: compact ? 17 : 20, weight: .bold)).foregroundStyle(Color.gInk)
                .lineLimit(compact ? 2 : 3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                DevPhaseChip(run: run, writerBusy: writerBusy)
                if run.isLive, run.rounds > 0 { Text("vuelta \(run.rounds) de 3").gMeta().foregroundStyle(Color.gInk3) }
                // El deploy existe sólo después del merge.
                if run.phase == "merged", let d = detail?.deployLabel { deployPill(d) }
                Spacer(minLength: 0)
                if run.actions != nil { if let a = headerAction(run) { actionPill(a) } }
                else if run.isBlocked { pillButton("Seguir sin esperar") { Task { await act("resume") } } }
                else if run.canReopen { pillButton("Reabrir") { Task { await act("reopen") } } }
                else if run.isLive, run.pr != nil { mergeButton(run) }
            }
            linkChips(run)
            DevStageBar(run: run, compact: compact).padding(.top, compact ? 0 : 4)
            if let ask = run.asked { askCard(ask, run: run) }
            if run.asked == nil, let why = mergeBlocker(run) { Text(why).gCaption().foregroundStyle(Color.gInk3).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
            if !compact, let n = run.note, run.isLive { Text(n).gMeta().foregroundStyle(Color.gInk2).lineLimit(2) }
        }
        .padding(.top, 2)
    }

    /// Issue, PR y vista previa a la vista (antes sólo estaban en el menú ⋯).
    @ViewBuilder private func linkChips(_ run: DevRun) -> some View {
        let preview: URL? = detail?.sheet?.previewState == "ready" ? detail?.sheet?.previewURL : nil
        let links: [(String, String, URL)] = [
            run.issue.flatMap { n in run.issueURL.map { ("Issue #\(n)", "exclamationmark.circle", $0) } },
            run.pr.flatMap { n in run.prURL.map { ("PR #\(n)", "arrow.triangle.pull", $0) } },
            preview.map { ("Vista previa", "safari", $0) },
        ].compactMap { $0 }
        if !links.isEmpty {
            HStack(spacing: 8) {
                ForEach(links, id: \.0) { l in
                    Button { openURL(l.2) } label: {
                        Label(l.0, systemImage: l.1).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.gInk2)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Color.gFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// La pregunta del escritor: con opciones, un botón por opción (una línea cada uno); tocar = contestarla.
    private func askCard(_ ask: DevAsk, run: DevRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ask.question).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gInk)
                .lineLimit(tab == .chat ? 3 : 6).fixedSize(horizontal: false, vertical: true)
            if !ask.options.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(ask.options, id: \.self) { o in
                        Button { Task { await send(o) } } label: {
                            Text(o).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .foregroundStyle(Color.gPrimaryPressed)
                                .background(Color.gPrimaryTint, in: Capsule())
                                .overlay(Capsule().stroke(Color.gPrimaryLight, lineWidth: 1))
                        }
                        .buttonStyle(.plain).disabled(sending)
                    }
                }
            }
            // Como la web: dejar que el agente decida, o cerrar el pendiente.
            HStack(spacing: 14) {
                Button { Task { await send(DevAsk.decideForMe) } } label: {
                    Text("Decide tú").font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize().foregroundStyle(Color.gInk2)
                }
                .buttonStyle(.plain).disabled(sending).accessibilityIdentifier("dev-ask-decide")
                if run.isLive, !run.isPR, run.actions == nil || run.action("stop") != nil {
                    Button { confirmStop = true } label: {
                        Text("Cerrar").font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize().foregroundStyle(Color.gDangerInk)
                    }
                    .buttonStyle(.plain).disabled(sending).accessibilityIdentifier("dev-ask-close")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gAmberTint, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("dev-ask")
    }

    /// Por qué Merge está apagado, dicho una vez bajo las etapas (`nil` = nada que explicar).
    private func mergeBlocker(_ run: DevRun) -> String? {
        // Con acciones del servidor, el porqué de una acción apagada lo dice gs (`disabled.why`).
        if run.actions != nil { return headerAction(run).flatMap { $0.isDisabled ? $0.disabledWhy : nil } }
        if run.isBlocked { return run.blockedBy.map { "Esperando el PR #\($0). «Seguir sin esperar» no lo cierra." } ?? "Esperando a otro PR." }
        guard run.isLive, run.pr != nil, !run.canMerge else { return nil }
        // gs ya dice por qué no (conflicto, borrador, CI, revisión o evidencia pendiente): se enseña tal cual.
        if let why = run.mergeBlock { return why }
        // Lo que de verdad frena el merge: un check del commit en rojo o corriendo (antes decía «te preguntó algo»).
        if let blocking = detail?.checks.filter({ ["failure", "error", "pending"].contains($0.state) }), !blocking.isEmpty {
            let names = blocking.prefix(2).map(\.name).joined(separator: ", ")
            return "Merge espera a los checks: \(names)\(blocking.count > 2 ? " y \(blocking.count - 2) más" : "")."
        }
        if writerBusy, run.tone == .working { return "El agente sigue trabajando; el CI corre mientras." }
        if run.asked != nil { return tab == .chat ? "El agente te preguntó algo: contéstale aquí abajo." : "El agente te preguntó algo: contéstale en Conversación." }
        return "Merge se activa con CI y revisión en verde."
    }

    private func deployPill(_ d: (text: String, ok: Bool?)) -> some View {
        let ink: Color = d.ok == true ? .gGreenInk : d.ok == false ? .gDangerInk : .gPrimaryPressed
        let tint: Color = d.ok == true ? .gGreenTint : d.ok == false ? .gDangerTint : .gPrimaryTint
        return Label(d.text, systemImage: d.ok == true ? "checkmark.circle.fill" : d.ok == false ? "xmark.circle.fill" : "arrow.triangle.2.circlepath")
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
            .padding(.horizontal, 10).padding(.vertical, 4).background(tint, in: Capsule())
    }

    // MARK: Conversación

    /// El MISMO chat de la app (`ConversationView`): scroll, botón para bajar, adjuntos, voz. Escribir ahí
    /// es decirle algo al pendiente: gs lo pasa por `tell` (`onPersonMessage`).
    @ViewBuilder private func chatTab(_ run: DevRun) -> some View {
        if run.isPR {
            VStack(spacing: 0) {
                ScrollView { commentsTab.padding(.horizontal, Theme.Space.screenH).padding(.bottom, 24) }
                    .scrollIndicators(.hidden)
                    .refreshable { await store.loadDetail(id) }
                // PR con pendiente de terminal: el campo lo manda gs (`compose`) y dice a dónde llega el mensaje.
                if let c = run.compose {
                    DevComposeBar(compose: c, repo: run.repo) { text in
                        let r = await store.sendMessage(repo: run.repo, issue: run.issue, pr: run.pr, content: text)
                        await store.loadDetail(id)
                        return r
                    }
                    .padding(.horizontal, Theme.Space.screenH).padding(.bottom, 8)
                } else if run.actions == nil, run.isLive {
                    // Respaldo con gs viejo: pedido como comentario del PR (`thread/messages`).
                    prComposer
                }
            }
        } else if devFocus != nil {
            ConversationView(store: chats, onOpenSheet: {}, embedded: true, placeholder: "Dile al agente qué ajustar…",
                             readOnlyNote: run.isLive ? nil : "El pendiente ya cerró: aquí sólo se lee lo que habló el agente.")
        } else {
            Text(detail == nil ? "Cargando…" : "Esta conversación es de un agente que no está en tu cuenta.")
                .gBody().foregroundStyle(Color.gInk3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Escribirle al agente de la terminal: gs lo publica como pedido en el PR (`thread/messages`).
    private var prComposer: some View {
        HStack(spacing: 8) {
            TextField("Pídele un cambio al agente…", text: $draft, axis: .vertical)
                .lineLimit(1...4).font(.system(size: 16))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.gBg, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.gSeparator, lineWidth: 1.5))
                .accessibilityIdentifier("pr-composer")
            Button {
                let t = draft
                Task { await send(t); if notice == nil { draft = "" } }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    // Vacío se queda en lila suave (se lee como botón); gris se lee como «desactivado».
                    .foregroundStyle(Color.gPrimary.opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending ? 0.4 : 1))
            }
            .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            .accessibilityIdentifier("pr-composer-send")
        }
        .padding(.horizontal, Theme.Space.screenH).padding(.vertical, 8)
        .background(Color.gBg)
    }

    /// Un PR sin DevRun no tiene chat en vivo con un agente: aquí van sus comentarios (revisión de Ghosty, personas, bots).
    @ViewBuilder private var commentsTab: some View {
        if let d = detail, !d.thread.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(d.thread) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(c.by.replacingOccurrences(of: "[bot]", with: "")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.gInk2)
                            Spacer()
                            if let at = c.at { Text(DevDate.ago(at)).gMeta().foregroundStyle(Color.gInk3) }
                        }
                        GhostyMarkdown(markdown: Self.plainComment(c.text))
                    }
                    .padding(Theme.Space.cardH)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ghostyCard()
                }
            }
        } else {
            Text(detail == nil ? "Cargando…" : "El PR no tiene comentarios.").gBody().foregroundStyle(Color.gInk3).padding(.vertical, 20)
        }
    }

    /// Los comentarios de GitHub traen HTML que el markdown no pinta: marcas ocultas (`<!-- … -->`) y
    /// plegables (`<details><summary>`). Se quitan las marcas y el plegable queda como texto normal.
    static func plainComment(_ t: String) -> String {
        var s = t.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<summary>([\\s\\S]*?)</summary>", with: "**$1**", options: .regularExpression)
        s = s.replacingOccurrences(of: "</?(details|sub|sup|br|p|div)[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Cambios

    @ViewBuilder private var changesTab: some View {
        if let d = detail, !d.files.isEmpty {
            HStack {
                Text("\(d.files.count) archivos").gSectionTitle()
                Spacer()
                Text("+\(d.additions)").foregroundStyle(Color.gGreenInk)
                Text("−\(d.deletions)").foregroundStyle(Color.gDangerInk)
            }
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            VStack(spacing: 0) {
                ForEach(d.files) { f in
                    DisclosureGroup {
                        if let p = f.patch {
                            ScrollView(.horizontal) { Text(p).gCode().foregroundStyle(Color.gInk2).padding(8) }
                                .background(Color.gCardSunken, in: RoundedRectangle(cornerRadius: 10))
                        }
                    } label: {
                        HStack {
                            Text(f.file).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Color.gInk).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text("+\(f.additions) −\(f.deletions)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.gInk3)
                        }
                    }
                    .padding(.horizontal, Theme.Space.cardH).padding(.vertical, 10)
                    if f.id != d.files.last?.id { Divider().overlay(Color.gHairline) }
                }
            }
            .ghostyCard()
        } else {
            Text(detail == nil ? "Cargando…" : "Todavía no hay cambios en el PR.").gBody().foregroundStyle(Color.gInk3).padding(.vertical, 20)
        }
    }

    // MARK: Verificación

    @ViewBuilder private func checksTab(_ run: DevRun) -> some View {
        let smoke = DevSmoke.latest(in: run.events)
        if let lh = smoke?.lighthouse { lighthouseCard(lh) }
        if run.isPR, let names = detail?.missingEnv, !names.isEmpty { missingEnvCard(names) }
        statusGrid(run)
        if run.isPR, run.isLive, let u = detail?.sheet?.previewURL {
            HStack(spacing: 8) {
                Button { openURL(u) } label: {
                    Label("Abrir vista previa", systemImage: "arrow.up.right.square").font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).padding(.vertical, 10).foregroundStyle(.white).background(Color.gInk, in: Capsule())
                }
                .buttonStyle(.plain)
                Button { shareOpen = true } label: {
                    Label("Compartir", systemImage: "square.and.arrow.up").font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10).foregroundStyle(Color.gInk).background(Color.gFill, in: Capsule())
                }
                .buttonStyle(.plain).accessibilityIdentifier("dev-share")
            }
        }
        if let smoke { smokeCard(smoke, run: run) }
        if run.isPR, run.isLive { prOpsCard(smoke) }
        if let d = detail, !d.checks.isEmpty { checksCard(d) }
        if run.phase == "merged", let d = detail, let dep = d.deployLabel {
            card("Producción") {
                HStack {
                    deployPill(dep)
                    Spacer()
                    if let u = (d.deploy?["url"] as? String).flatMap(URL.init(string:)) { Button("Ver el run") { openURL(u) }.font(.system(size: 14, weight: .semibold)) }
                }
            }
        }
        if let d = detail, d.networkMode != nil { networkCard(d) }
    }

    private func missingEnvCard(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Falta\(names.count == 1 ? " 1 variable necesaria" : "n \(names.count) variables necesarias") para probar este PR: \(names.prefix(4).joined(separator: ", "))\(names.count > 4 ? "…" : "")")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gAmberInk)
            Text("La vista previa no las tiene: lo que las use falla aunque las páginas abran. Agrégalas y se rearma sola.")
                .gMeta().foregroundStyle(Color.gInk2)
            Button { envOpen = true } label: {
                Label("Agregar variables", systemImage: "key.fill").font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9).foregroundStyle(.white).background(Color.gPrimary, in: Capsule())
            }
            .buttonStyle(.plain).accessibilityIdentifier("dev-add-env")
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(Color.gAmberTint, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Lo que la web ofrece bajo la prueba en vivo: pedir arreglo, crear pendiente aparte, volver a correrla.
    private func prOpsCard(_ smoke: DevSmoke?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let st = smoke?.steps, !st.isEmpty {
                ForEach(st) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: step.ok ? "checkmark" : step.soft ? "exclamationmark.circle" : "xmark.circle")
                            .foregroundStyle(step.ok ? Color.gGreen : step.soft ? Color.gAmber : Color.gDanger).frame(width: 16)
                        Text(step.method).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Color.gInk3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.path).font(.system(size: 14, design: .monospaced)).foregroundStyle(Color.gInk)
                            if !step.ok, !step.why.isEmpty { Text(step.why).gMeta().foregroundStyle(Color.gInk3) }
                        }
                        Spacer(minLength: 0)
                        if let c = step.status { Text("\(c)").gMeta().foregroundStyle(Color.gInk3) }
                    }
                }
            }
            if smoke?.brokenImages != nil || smoke?.layoutIssues != nil || smoke?.contrastFails != nil {
                HStack(spacing: 8) {
                    counter(smoke?.brokenImages, "Imágenes rotas")
                    counter(smoke?.layoutIssues, "Desbordes")
                    counter(smoke?.contrastFails, "Contraste")
                }
            }
            opButton("Pedir arreglo en este PR", "fix", prominent: true)
            HStack(spacing: 8) {
                opButton("Crear pendiente aparte", "new-issue")
                opButton("Volver a correr la prueba", "smoke")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14).ghostyCard()
    }

    private func counter(_ n: Int?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(n.map(String.init) ?? "—").font(.system(size: 18, weight: .bold).monospacedDigit()).foregroundStyle(Color.gInk)
            Text(label).font(.system(size: 11)).foregroundStyle(Color.gInk3).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8).background(Color.gFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private func opButton(_ label: String, _ op: String, prominent: Bool = false) -> some View {
        Button { confirmOp = op } label: {
            Text(busyOp == op ? "…" : label).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(prominent ? Color.white : Color.gInk)
                .background(prominent ? Color.gPrimary : Color.gFill, in: Capsule())
        }
        .buttonStyle(.plain).disabled(busyOp != nil).accessibilityIdentifier("dev-op-\(op)")
    }

    private func opCopy(_ op: String?) -> (title: String, button: String) {
        switch op {
        case "fix": ("¿Pedir el arreglo en este PR?", "Pedir arreglo")
        case "new-issue": ("¿Crear un pendiente aparte con lo que encontró la prueba?", "Crear pendiente")
        default: ("¿Volver a correr la prueba en vivo?", "Volver a correr")
        }
    }

    private func runPROp(_ op: String) async {
        busyOp = op; defer { busyOp = nil }
        var note: String?
        var what: String?
        if op == "fix" || op == "new-issue" {
            let probs = DevSmoke.latest(in: run?.events ?? [])?.problems ?? []
            note = probs.isEmpty ? "Revisa la prueba en vivo de este PR." : "Arregla lo que encontró la prueba en vivo:\n" + probs.prefix(10).map { "- \($0)" }.joined(separator: "\n")
            what = "Arreglo de la prueba en vivo"
        }
        let r = await store.prOp(id, op, note: note, what: op == "fix" ? what : nil)
        if let e = r.error { notice = e } else if let u = r.created { openURL(u) } else { notice = r.note ?? "Listo." }
    }

    private func lighthouseCard(_ lh: DevDetail.Lighthouse) -> some View {
        card("Lighthouse") {
            HStack {
                ring(lh.performance, "Rendimiento")
                ring(lh.accessibility, "Accesibilidad")
                ring(lh.bestPractices, "Prácticas")
                ring(lh.seo, "SEO")
            }
        }
    }

    private func ring(_ v: Double?, _ label: String) -> some View {
        let n = Int(((v ?? 0) * 100).rounded())
        let color: Color = v == nil ? .gInk4 : n >= 90 ? .gGreen : n >= 50 ? .gAmber : .gDanger
        return VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.gFillStrong, lineWidth: 5)
                Circle().trim(from: 0, to: v ?? 0).stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(v == nil ? "—" : "\(n)").font(.system(size: 16, weight: .bold).monospacedDigit()).foregroundStyle(Color.gInk)
            }
            .frame(width: 54, height: 54)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.gInk3).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    /// Los cuatro estados salen de la ficha de gs (`detail.sheet`), nunca de deducir eventos aquí.
    private func statusGrid(_ run: DevRun) -> some View {
        let sh = detail?.sheet ?? DevDetail.Sheet()
        let findings = detail?.findings ?? run.events.last(where: { $0.kind == "review_findings" }).flatMap { ($0.data["findings"] as? [Any])?.count }
        let repoChecks = (detail?.checks ?? []).filter { !$0.ghosty && $0.state != "neutral" && $0.state != "skipped" }
        let ciState = repoChecks.contains { $0.state == "failure" || $0.state == "error" } ? "bad"
            : repoChecks.contains { $0.state == "pending" } ? "running" : sh.ci
        let ci: (String, Bool?) = switch ciState {
        case "ok": ("En verde", true)
        case "bad": ("En rojo", false)
        case "running": ("Corriendo", nil)
        default: (run.pr == nil ? "Sin PR todavía" : "Sin correr", nil)
        }
        let review: (String, Bool?) = switch sh.review {
        case "ok": ("Sin hallazgos", true)
        case "bad": ("\(findings ?? 1) \(findings == 1 ? "hallazgo" : "hallazgos")", false)
        case "running": ("Revisando", nil)
        default: ("Todavía no se revisa", nil)
        }
        // Los checks del commit actual mandan sobre la ficha: que nada diga verde/rojo contra ellos
        // (#76 de Formmy, 22-nov: «evidencia en el PR» con la puerta corriendo, «falló» con Preview neutral).
        let checks = detail?.checks ?? []
        let gate = checks.first { $0.name == "ghosty-dev/evidencia" }?.state
        let previewCheck = checks.first { $0.name == "Ghosty · Preview" }?.state
        let evidence: (String, Bool?) = switch gate {
        case "failure": ("Evidencia en rojo", false)
        case "success": ("En el PR", true)
        case .some: ("Falta la evidencia", nil)
        case nil: sh.evidence ? ("En el PR", true) : ("Aún no se publica", nil)
        }
        // Una vista previa con liga existe aunque el check de Ghosty salga neutral (#139 de mailmask): ahí manda la liga.
        let preview: (String, Bool?) = switch (previewCheck == "neutral" || previewCheck == "skipped") && sh.previewURL == nil ? "na" : sh.previewState {
        case "na": ("No aplica", nil)
        case "ready": ("Lista", true)
        case "failed": ("Falló", false)
        case "building": ("Armándose", nil)
        default: ("Sin vista previa", nil)
        }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            statusTile("CI", ci)
            statusTile("Revisión", review)
            statusTile("Evidencia", evidence)
            statusTile("Vista previa", preview)
        }
    }

    private func statusTile(_ title: String, _ s: (String, Bool?)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: s.1 == true ? "checkmark.circle.fill" : s.1 == false ? "exclamationmark.circle.fill" : "circle.dashed")
                .font(.system(size: 20)).foregroundStyle(s.1 == true ? Color.gGreen : s.1 == false ? Color.gAmber : Color.gInk4)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gInk)
                Text(s.0).gMeta().foregroundStyle(Color.gInk3).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .ghostyCard()
    }

    private func smokeCard(_ s: DevSmoke, run: DevRun) -> some View {
        let problems = s.problems
        return card("Ghosty · Smoke", badge: problems.isEmpty ? nil : ("\(problems.count) \(problems.count == 1 ? "falla" : "fallas")", .gDangerInk, .gDangerTint)) {
            if problems.isEmpty {
                Label("La vista previa respondió bien.", systemImage: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Color.gGreenInk)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(problems.prefix(6).enumerated()), id: \.offset) { _, p in
                        Label(p, systemImage: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(Color.gInk2)
                            .labelStyle(.titleAndIcon).symbolRenderingMode(.multicolor)
                    }
                    if problems.count > 6 { Text("+\(problems.count - 6) más").gMeta().foregroundStyle(Color.gInk3) }
                    // Un PR sin DevRun no tiene escritor: la web tampoco ofrece el arreglo ahí (gs daba 404).
                    if run.isLive, !run.isPR {
                        Button {
                            Task { await send("Arregla lo que encontró el smoke en la vista previa:\n" + problems.prefix(10).map { "- \($0)" }.joined(separator: "\n")) }
                        } label: {
                            Text("Pedir arreglo al agente").font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity).padding(.vertical, 11)
                                .foregroundStyle(.white).background(Color.gPrimary, in: Capsule())
                        }
                        .buttonStyle(.plain).disabled(sending).padding(.top, 4)
                    }
                }
            }
        }
    }

    private func checksCard(_ d: DevDetail) -> some View {
        let groups: [(String, [DevDetail.Check])] = [("De Ghosty", d.checks.filter(\.ghosty)), ("CI del repo", d.checks.filter { !$0.ghosty })]
        return card("Checks") {
            VStack(spacing: 0) {
                ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { g in
                    let counted = g.1.filter { $0.state != "neutral" && $0.state != "skipped" }
                    let ok = counted.filter { $0.state == "success" }.count
                    let failed = counted.contains { $0.state == "failure" }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(g.1) { c in
                                Button { if let u = c.url { openURL(u) } } label: {
                                    HStack {
                                        checkIcon(c.state)
                                        Text(c.name).font(.system(size: 13)).foregroundStyle(Color.gInk2).lineLimit(1)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack {
                            checkIcon(failed ? "failure" : ok == counted.count ? "success" : "pending")
                            Text(g.0).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk)
                            Spacer()
                            Text("\(ok)/\(counted.count)").font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(Color.gInk3)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder private func checkIcon(_ state: String) -> some View {
        switch state {
        case "success": Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.gGreen)
        case "failure": Image(systemName: "xmark.circle.fill").foregroundStyle(Color.gDanger)
        case "pending": Image(systemName: "circle.dotted").foregroundStyle(Color.gAmber)
        default: Image(systemName: "circle.dashed").foregroundStyle(Color.gInk4)
        }
    }

    private func networkCard(_ d: DevDetail) -> some View {
        card("Red de la caja") {
            VStack(alignment: .leading, spacing: 8) {
                Text(d.networkMode == "enforce" ? "Bloqueando lo que no está en la lista" : "Modo auditoría").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gInk)
                if d.denied.isEmpty {
                    Text("Nada fuera de la lista.").gMeta().foregroundStyle(Color.gInk3)
                } else {
                    Text(d.networkMode == "enforce" ? "Se bloquearon:" : "Se habrían bloqueado:").gMeta().foregroundStyle(Color.gInk3)
                    FlowChips(items: d.denied.map(\.host))
                }
            }
        }
    }

    // MARK: Actividad

    @ViewBuilder private func activityTab(_ run: DevRun) -> some View {
        if run.events.isEmpty {
            Text("Sin actividad todavía.").gBody().foregroundStyle(Color.gInk3).padding(.vertical, 20)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(DevEvent.grouped(run.events.reversed())) { g in
                    let e = g.event
                    HStack(alignment: .firstTextBaseline) {
                        Text(e.label).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gInk)
                        if g.count > 1 { Text("×\(g.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.gInk3) }
                        if let c = e.commit { Text(String(c.prefix(7))).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.gInk3) }
                        Spacer()
                        Text(DevDate.ago(e.at)).gMeta().foregroundStyle(Color.gInk3)
                    }
                    .padding(.vertical, 10)
                    Divider().overlay(Color.gHairline)
                }
            }
            .padding(.horizontal, Theme.Space.cardH)
            .ghostyCard()
        }
    }

    // MARK: Abajo: la caja y Merge

    /// Merge sólo con `canMerge` de gs; apagado dice por qué.
    private func mergeButton(_ run: DevRun) -> some View {
        Button { if run.isPR { confirmMerge = true } else { Task { await act("merge") } } } label: {
            Text("Merge").font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 7)
                .foregroundStyle(run.canMerge ? Color.white : Color.gInk3)
                .background(run.canMerge ? Color.gPrimary : Color.clear, in: Capsule())
                // Apagado se lee como botón (borde), no como mancha gris; el porqué va bajo las etapas.
                .overlay(Capsule().stroke(run.canMerge ? Color.clear : Color.gSeparator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!run.canMerge || sending)
        .accessibilityHint(run.canMerge ? "" : "Se activa con CI y revisión en verde")
    }

    private func pillButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(.white).background(Color.gPrimary, in: Capsule())
        }
        .buttonStyle(.plain).disabled(sending)
    }

    // MARK: Acciones

    /// La acción que va en el encabezado: la `primary` de gs, o `merge` (apagado también se ve, con su porqué).
    private func headerAction(_ run: DevRun) -> DevAction? {
        run.actions?.first { $0.primary } ?? run.action("merge")
    }

    private func actionPill(_ a: DevAction) -> some View {
        Button { tap(a) } label: {
            HStack(spacing: 6) {
                if runningID == a.id { ProgressView().controlSize(.mini).tint(a.primary ? .white : .gInk2) }
                Text(a.label)
            }
            .font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
                .padding(.horizontal, 16).padding(.vertical, 7)
                .foregroundStyle(a.isDisabled ? Color.gInk3 : a.primary ? Color.white : a.destructive ? Color.gDangerInk : Color.gInk)
                .background(!a.isDisabled && a.primary ? Color.gPrimary : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(!a.isDisabled && a.primary ? Color.clear : Color.gSeparator, lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(a.isDisabled || sending)
        .accessibilityIdentifier("dev-action-\(a.id)")
    }

    private func tap(_ a: DevAction) {
        if !a.fields.isEmpty { formAction = a }
        else if let c = a.confirm, !c.isEmpty { pendingAction = a } else { Task { await runAction(a) } }
    }

    /// Ejecuta lo que gs dejó hacer; una acción que no se conoce igual corre por su `op` o su `href`.
    private func runAction(_ a: DevAction) async {
        guard let run else { return }
        sending = true
        runningID = a.id
        defer { sending = false; runningID = nil }
        switch await store.perform(a, repo: run.repo, issue: run.issue, pr: run.pr, runID: id) {
        case .done:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            notice = "Listo: \(a.label.lowercased())."

        case .open(let u): openURL(u)
        case .text(let t): readText = DevReadText(title: a.label, text: t)
        case .failed(let m): notice = m
        }
    }

    private func send(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Con el chat montado, el pedido va por el MISMO envío que escribir a mano: tu mensaje sale en la
        // conversación al instante (optimista) y gs lo pasa al escritor. Por `tell` directo no se veía nada
        // hasta que el escritor lo recogía, y eso tarda (bliss, 22-nov).
        if let f = devFocus {
            tab = .chat
            await chats.send(t, a: f.devAgentID)
            return
        }
        sending = true
        defer { sending = false }
        // Un PR sin DevRun: el pedido es un comentario del PR que lee el agente de la terminal.
        if run?.isPR == true {
            if let err = await store.say(id, t) { notice = err } else { tab = .chat }
            return
        }
        // `tell`: la entrada única de gs (decide qué hacer según la fase). Mientras no esté en prod, `resume`.
        var err = await store.act(id, op: "tell", note: t)
        if let e = err, e.contains("op:") || e.contains("bad_request") { err = await store.act(id, op: "resume", note: t) }
        if let err { notice = err } else { tab = .chat }
    }

    private func act(_ op: String) async {
        sending = true
        defer { sending = false }
        if let err = await store.act(id, op: op) { notice = err }
    }

    // MARK: Piezas

    private func card<C: View>(_ title: String, badge: (String, Color, Color)? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).gSectionTitle().foregroundStyle(Color.gInk)
                Spacer()
                if let b = badge { Text(b.0).gChip().foregroundStyle(b.1).padding(.horizontal, 10).padding(.vertical, 3).background(b.2, in: Capsule()) }
            }
            content()
        }
        .padding(Theme.Space.cardH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostyCard()
    }
}

/// Pastillas grises que se acomodan en renglones.
struct FlowChips: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { h in
                Text(h).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.gInk2)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Color.gFill, in: Capsule())
            }
        }
    }
}


/// «Compartir» la vista previa de un PR: lee la liga y, sólo si la persona lo pide, crea la pública.
struct DevShareSheet: View {
    let id: String
    let store: DevStore
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var shared = false
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compartir la vista previa").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.gInk)
            if loading { ProgressView() }
            else if let error { Text(error).foregroundStyle(Color.gDangerInk) }
            else if shared, let url {
                Text("Cualquiera con la liga la ve, sin cuenta.").gMeta()
                ShareLink(item: url) { Label("Compartir liga", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 12).foregroundStyle(.white).background(Color.gPrimary, in: Capsule()) }
            } else {
                Text("Hoy sólo la ve quien tiene acceso al repo.").gMeta()
                Button("Crear liga para cualquiera") { Task { await make() } }.buttonStyle(.borderedProminent).tint(Color.gPrimary)
            }
            Spacer()
        }
        .padding(20)
        .presentationDetents([.height(260)]).presentationBackground(Color.gBg)
        .task { let r = await store.shareState(id); url = r.url; shared = r.shared; error = r.error; loading = false }
    }

    private func make() async {
        loading = true
        let r = await store.shareState(id, create: true)
        url = r.url; shared = r.shared; error = r.error; loading = false
    }
}
