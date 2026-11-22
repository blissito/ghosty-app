import SwiftUI

/// Un pendiente abierto: encabezado (fase, deploy sólo tras el merge, etapas) y cuatro pestañas.
/// La caja «Dile al agente qué ajustar…» está en toda fase viva; Merge sólo se activa en «listo».
struct DevRunView: View {
    let id: String
    @State private var store = DevStore.shared
    // Gancho: `GHOSTY_DEV_TAB=changes|checks|activity` abre esa pestaña.
    @State private var tab: Tab = Tab.allCases.first { "\($0)" == Gancho.valor("GHOSTY_DEV_TAB") } ?? .chat
    @State private var note = ""
    @State private var sending = false
    @State private var notice: String?
    @State private var confirmStop = false
    @Environment(\.openURL) private var openURL

    enum Tab: String, CaseIterable { case chat = "Conversación", changes = "Cambios", checks = "Verificación", activity = "Actividad" }

    private var run: DevRun? { store.full[id] ?? store.runs.first { $0.id == id } }
    private var detail: DevDetail? { store.details[id] }

    var body: some View {
        Group {
            if let run {
                // Los datos del pendiente y las pestañas quedan fijos arriba; sólo se desplaza el contenido.
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        header(run)
                        Picker("Vista", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, Theme.Space.screenH)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                switch tab {
                                case .chat: chatTab(run)
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
                        // Como un chat: la conversación abre en lo último, no en el primer mensaje.
                        .onChange(of: store.messages[id]?.count ?? 0, initial: true) { _, _ in scrollToEnd(proxy) }
                        .onChange(of: tab) { _, t in if t == .chat { scrollToEnd(proxy) } }
                    }
                }
                .safeAreaInset(edge: .bottom) { bottomBar(run) }
            } else {
                FlameLoading().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.gBg.ignoresSafeArea())
        .navigationTitle(run?.pr.map { "PR #\($0)" } ?? "Pendiente")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let run {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let u = run.prURL { Button("Abrir el PR en GitHub", systemImage: "arrow.up.right.square") { openURL(u) } }
                        if let u = detail?.previewURL, detail?.previewPhase == "ready" { Button("Ver la vista previa", systemImage: "safari") { openURL(u) } }
                        if run.isLive { Button("Detener", systemImage: "stop.circle", role: .destructive) { confirmStop = true } }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .confirmationDialog("¿Detener este pendiente?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Detener", role: .destructive) { Task { await act("stop") } }
        } message: { Text("El agente deja de trabajar en él. El PR se queda como está.") }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK", role: .cancel) {} }
        .task(id: id) {
            await store.loadDetail(id)
            // Mientras esté vivo, se refresca solo (como la web): cada 15 s.
            while !Task.isCancelled, run?.isLive == true {
                try? await Task.sleep(for: .seconds(15))
                await store.loadDetail(id)
            }
        }
    }

    // MARK: Encabezado

    @ViewBuilder private func header(_ run: DevRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(run.repo).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.gInk3)
            Text(run.title).font(.system(size: 20, weight: .bold)).foregroundStyle(Color.gInk).lineLimit(2)
            HStack(spacing: 8) {
                DevPhaseChip(run: run)
                if run.isLive, run.rounds > 0 { Text("vuelta \(run.rounds) de 3").gMeta().foregroundStyle(Color.gInk3) }
                // El deploy existe sólo después del merge.
                if run.phase == "merged", let d = detail?.deployLabel { deployPill(d) }
            }
            DevStageBar(run: run).padding(.top, 4)
            if let n = run.note, run.isLive { Text(n).gMeta().foregroundStyle(Color.gInk2) }
        }
        .padding(.top, 2)
    }

    private func deployPill(_ d: (text: String, ok: Bool?)) -> some View {
        let ink: Color = d.ok == true ? .gGreenInk : d.ok == false ? .gDangerInk : .gPrimaryPressed
        let tint: Color = d.ok == true ? .gGreenTint : d.ok == false ? .gDangerTint : .gPrimaryTint
        return Label(d.text, systemImage: d.ok == true ? "checkmark.circle.fill" : d.ok == false ? "xmark.circle.fill" : "arrow.triangle.2.circlepath")
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
            .padding(.horizontal, 10).padding(.vertical, 4).background(tint, in: Capsule())
    }

    // MARK: Conversación

    @ViewBuilder private func chatTab(_ run: DevRun) -> some View {
        let msgs = store.messages[id] ?? []
        if msgs.isEmpty {
            Text(detail == nil ? "Cargando…" : "El agente todavía no ha escrito nada.").gBody().foregroundStyle(Color.gInk3).padding(.vertical, 20)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(msgs.suffix(40)) { m in bubble(m) }
            }
        }
        Color.clear.frame(height: 1).id("chat-end")
        if !run.isLive {
            Text("El pendiente ya cerró: aquí sólo se lee lo que habló el agente.").gCaption().foregroundStyle(Color.gInk3)
                .frame(maxWidth: .infinity).padding(.top, 8)
        }
    }

    private func bubble(_ m: DevMessage) -> some View {
        HStack {
            if !m.fromAgent { Spacer(minLength: 40) }
            Text(LocalizedStringKey(m.text))
                .gBody().foregroundStyle(Color.gInkBody)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(m.fromAgent ? Color.gBubbleAgent : Color.gBubbleUser, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble))
                .textSelection(.enabled)
            if m.fromAgent { Spacer(minLength: 40) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard tab == .chat, !(store.messages[id] ?? []).isEmpty else { return }
        // Un respiro para que el contenido se mida antes de bajar.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            proxy.scrollTo("chat-end", anchor: .bottom)
        }
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

    private func statusGrid(_ run: DevRun) -> some View {
        let kinds = run.events.map(\.kind)
        let lastPush = kinds.lastIndex(of: "pushed") ?? -1
        let after = Array(kinds.dropFirst(lastPush + 1))
        let ci: (String, Bool?) = after.contains("ci_red") ? ("En rojo", false) : after.contains("ci_green") ? ("En verde", true) : run.pr == nil ? ("Sin PR todavía", nil) : ("Corriendo", nil)
        let findings = run.events.last(where: { $0.kind == "review_findings" }).flatMap { ($0.data["findings"] as? [Any])?.count }
        let review: (String, Bool?) = after.contains("review_findings") ? ("\(findings ?? 1) \(findings == 1 ? "hallazgo" : "hallazgos")", false) : after.contains("review_clean") ? ("Sin hallazgos", true) : ("Todavía no se revisa", nil)
        let evidence: (String, Bool?) = kinds.contains("evidence") ? ("En el PR", true) : ("Aún no se publica", nil)
        let preview: (String, Bool?) = switch detail?.previewPhase {
        case "ready": ("Lista", true)
        case "failed": ("Falló", false)
        case .some: ("Armándose", nil)
        case nil: ("Sin vista previa", nil)
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
        let problems = s.failedSteps + s.issues.map(\.what)
        return card("Ghosty · Smoke", badge: problems.isEmpty ? nil : ("\(problems.count) \(problems.count == 1 ? "falla" : "fallas")", .gDangerInk, .gDangerTint)) {
            if problems.isEmpty {
                Label("La vista previa respondió bien.", systemImage: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Color.gGreenInk)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(problems.prefix(6).enumerated()), id: \.offset) { _, p in
                        Label(p, systemImage: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(Color.gInk2)
                            .labelStyle(.titleAndIcon).symbolRenderingMode(.multicolor)
                    }
                    if run.isLive {
                        Button {
                            Task { await send("Arregla lo que encontró el smoke en la vista previa:\n" + problems.prefix(10).map { "- \($0)" }.joined(separator: "\n")) }
                        } label: {
                            Text("Pedir arreglo al agente").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 11)
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
                ForEach(run.events.reversed()) { e in
                    HStack(alignment: .firstTextBaseline) {
                        Text(e.label).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gInk)
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

    @ViewBuilder private func bottomBar(_ run: DevRun) -> some View {
        if run.isLive {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Dile al agente qué ajustar…", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.system(size: 16))
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    Button { Task { await send(note) } } label: {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 38, height: 38).background(note.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gInk4 : Color.gPrimary, in: Circle())
                    }
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                    .padding(.trailing, 6)
                }
                .background(Color.gCard, in: RoundedRectangle(cornerRadius: Theme.Radius.pill))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.pill).stroke(Color.gSeparator, lineWidth: 1))
                if run.pr != nil {
                    Button { Task { await act("merge") } } label: {
                        Text("Merge").font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .foregroundStyle(run.canMerge ? Color.white : Color.gInk4)
                            .background(run.canMerge ? Color.gPrimary : Color.gFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!run.canMerge || sending)
                    if !run.canMerge { Text("Se activa con CI y revisión en verde").gCaption().foregroundStyle(Color.gInk3) }
                }
            }
            .padding(.horizontal, Theme.Space.screenH).padding(.top, 8).padding(.bottom, 6)
            .background(Color.gBg)
        }
    }

    // MARK: Acciones

    private func send(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sending = true
        defer { sending = false }
        // `tell`: la entrada única de gs (decide qué hacer según la fase). Mientras no esté en prod, `resume`.
        var err = await store.act(id, op: "tell", note: t)
        if let e = err, e.contains("op:") || e.contains("bad_request") { err = await store.act(id, op: "resume", note: t) }
        if let err { notice = err } else { note = ""; tab = .chat }
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
