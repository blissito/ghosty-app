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
        framed
        .confirmationDialog("¿Detener este pendiente?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Detener", role: .destructive) { Task { await act("stop") } }
        } message: { Text("El agente deja de trabajar en él. El PR se queda como está.") }
        .alert(notice ?? "", isPresented: noticeShown) { Button("OK", role: .cancel) {} }
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
                if let u = run.prURL { Button(run.isPR && run.readyToMerge ? "Hacer merge en GitHub" : "Abrir el PR en GitHub", systemImage: "arrow.up.right.square") { openURL(u) } }
                if let sh = detail?.sheet, sh.previewState == "ready", let u = sh.previewURL { Button("Ver la vista previa", systemImage: "safari") { openURL(u) } }
                if run.isLive, !run.isPR { Button("Detener", systemImage: "stop.circle", role: .destructive) { confirmStop = true } }
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
                .lineLimit(compact ? 1 : 2)
            HStack(spacing: 8) {
                DevPhaseChip(run: run, writerBusy: writerBusy)
                if run.isLive, run.rounds > 0 { Text("vuelta \(run.rounds) de 3").gMeta().foregroundStyle(Color.gInk3) }
                // El deploy existe sólo después del merge.
                if run.phase == "merged", let d = detail?.deployLabel { deployPill(d) }
                Spacer(minLength: 0)
                if run.isBlocked { pillButton("Seguir sin esperar") { Task { await act("resume") } } }
                else if run.canReopen { pillButton("Reabrir") { Task { await act("reopen") } } }
                else if run.isLive, run.pr != nil { if run.isPR { githubMergeButton(run) } else { mergeButton(run) } }
            }
            linkChips(run)
            DevStageBar(run: run, compact: compact).padding(.top, compact ? 0 : 4)
            if let why = mergeBlocker(run) { Text(why).gCaption().foregroundStyle(Color.gInk3).lineLimit(1) }
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

    /// Por qué Merge está apagado, dicho una vez bajo las etapas (`nil` = nada que explicar).
    private func mergeBlocker(_ run: DevRun) -> String? {
        if run.isBlocked { return run.blockedBy.map { "Esperando el PR #\($0). «Seguir sin esperar» no lo cierra." } ?? "Esperando a otro PR." }
        guard run.isLive, run.pr != nil, !run.canMerge, !run.isPR else { return nil }
        // Lo que de verdad frena el merge: un check del commit en rojo o corriendo (antes decía «te preguntó algo»).
        if let blocking = detail?.checks.filter({ ["failure", "error", "pending"].contains($0.state) }), !blocking.isEmpty {
            let names = blocking.prefix(2).map(\.name).joined(separator: ", ")
            return "Merge espera a los checks: \(names)\(blocking.count > 2 ? " y \(blocking.count - 2) más" : "")."
        }
        if writerBusy, run.tone == .working { return "El agente sigue trabajando; el CI corre mientras." }
        if run.tone == .needsYou { return tab == .chat ? "El agente te preguntó algo: contéstale aquí abajo." : "El agente te preguntó algo: contéstale en Conversación." }
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
            ScrollView { commentsTab.padding(.horizontal, Theme.Space.screenH).padding(.bottom, 24) }
                .scrollIndicators(.hidden)
                .refreshable { await store.loadDetail(id) }
        } else if devFocus != nil {
            ConversationView(store: chats, onOpenSheet: {}, embedded: true, placeholder: "Dile al agente qué ajustar…",
                             readOnlyNote: run.isLive ? nil : "El pendiente ya cerró: aquí sólo se lee lo que habló el agente.")
        } else {
            Text(detail == nil ? "Cargando…" : "Esta conversación es de un agente que no está en tu cuenta.")
                .gBody().foregroundStyle(Color.gInk3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Un PR sin DevRun no tiene chat con un agente: aquí van sus comentarios (revisión de Ghosty, personas, bots).
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
        statusGrid(run)
        if let smoke { smokeCard(smoke, run: run) }
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
        let preview: (String, Bool?) = switch previewCheck == "neutral" || previewCheck == "skipped" ? "na" : sh.previewState {
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
                    if run.isLive {
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
        Button { Task { await act("merge") } } label: {
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

    /// PR sin DevRun: gs no hace su merge; listo, el botón lleva a GitHub.
    @ViewBuilder private func githubMergeButton(_ run: DevRun) -> some View {
        if run.readyToMerge, let u = run.prURL {
            Button { openURL(u) } label: {
                Label("Merge en GitHub", systemImage: "arrow.up.right").font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .foregroundStyle(.white).background(Color.gPrimary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Acciones

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
