import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Un pedido de la fábrica: la versión nativa de la tarjeta de Teams. Etapa y barra de pasos,
/// quién trabaja, el plan (para firmarlo), lo que encontró @check si escaló, la bitácora y las
/// decisiones que te tocan. Nada se decide sin confirmar.
struct FactoryRunView: View {
    let slug: String
    let id: Int

    @Environment(\.openURL) private var openURL
    @State private var detail: FactoryRunDetail?
    @State private var error: String?
    @State private var busy = false
    @State private var notice: String?
    @State private var planOpen = false
    @State private var confirm: Pending?
    @State private var asking: AskKind?
    @State private var mergeWithoutPreview = false
    @State private var mergeError: String?
    /// Ráfaga de confeti tras un merge (cambia el id para repetirla).
    @State private var confetti: UUID?
    /// «¿Qué hago?» abierto (la hoja pide la recomendación al aparecer).
    @State private var advising = false
    /// Lo que hace ahora cada rol (gs `…/live`); nil con una caja vieja o mientras llega.
    @State private var live: FactoryLive?
    /// La hoja de las variables de la preview (un escalado bloqueado que las pide).
    @State private var envOpen = false
    /// Guardadas las variables, al cerrarse su hoja se ofrece que @check revise.
    @State private var offerRecheck = false

    private enum Pending: Identifiable {
        case approve(Int), anotherLoop, recheck, merge
        var id: String {
            switch self {
            case .approve(let v): "approve-\(v)"
            case .anotherLoop: "loop"
            case .recheck: "recheck"
            case .merge: "merge"
            }
        }
    }

    enum AskKind: String, Identifiable {
        case changes, replan
        var id: String { rawValue }
    }

    private var cached: FactoryRun? { FactoryStore.shared.cached(slug, id) }
    private var stage: FactoryStage { detail?.stage ?? cached?.stage ?? .unknown }
    private var mergeQueued: Bool { detail?.mergeQueued ?? false }
    /// También con el merge en cola: se repregunta hasta que entre (la etapa pasa a «Terminado»).
    private var working: Bool { stage.working || !(detail?.running.isEmpty ?? true) || mergeQueued }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleBlock
                statusCard
                if let notice { noticeBanner(notice) }
                if let error { errorBanner(error) }
                if stage == .escalated { escalationCard }
                if let plan = detail?.plan { planCard(plan) }
                linksRow
                if let events = detail?.events, !events.isEmpty { logCard(events) }
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 6)
            .padding(.bottom, 28)
            .animation(.snappy(duration: 0.3), value: detail?.status)
        }
        .scrollIndicators(.hidden)
        .background(Color.gBg.ignoresSafeArea())
        .refreshable { await load() }
        .safeAreaInset(edge: .bottom) { if stage.needsYou { actionBar } }
        .overlay { if let confetti { ConfettiBurst().id(confetti) } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.gBg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Pedido #\(id)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk)
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        .task { await load() }
        // Mientras alguien trabaja, se repregunta cada 10 s (la etapa cambia sola).
        .task(id: working) {
            guard working else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { await load() }
            }
        }
        .sheet(item: $confirm) { p in
            FactoryConfirmSheet(title: confirmTitle(p), message: confirmMessage(p), action: confirmAction(p),
                                identifier: "confirmar-\(p.id)") {
                Task {
                    switch p {
                    case .approve(let v): await act(.approve, version: v)
                    case .anotherLoop: await act(.approve)
                    case .recheck: await act(.recheck)
                    case .merge: await act(.merge)
                    }
                }
            }
        }
        .alert("No se pudo mergear", isPresented: $mergeWithoutPreview) {
            Button("Mergear sin preview") { Task { await act(.merge, skipPreview: true) } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text(mergeError ?? "") }
        .sheet(item: $asking) { kind in
            FactoryNoteSheet(kind: kind) { note in
                Task { await act(.changes, note: note) }
            }
        }
        .sheet(isPresented: $envOpen, onDismiss: {
            if offerRecheck { offerRecheck = false; confirm = .recheck }
        }) {
            FactoryEnvSheet(repo: detail?.repo, names: detail?.missingEnv ?? []) { dotenv in
                await saveEnv(dotenv)
            }
        }
        .sheet(isPresented: $advising) {
            FactoryAdviceSheet(slug: slug, id: id) { advice, note, scope in
                Task { await act(advice.fix ? .approve : .changes, note: note, checkScope: advice.fix ? scope : nil) }
            }
        }
    }

    // MARK: - Bloques

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let repo = detail?.repo ?? cached?.repo {
                    Label(repo, systemImage: "chevron.left.forwardslash.chevron.right")
                        .labelStyle(FactoryMetaLabelStyle())
                }
                if (detail?.kind ?? cached?.kind) == "dependabot" {
                    Text("Dependabot").gChip().foregroundStyle(Color.gInk2)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.gFill, in: Capsule())
                }
            }
            Text(detail?.title ?? cached?.title ?? "Pedido #\(id)")
                .font(.system(size: 26, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(Color.gInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("pedido-titulo")
        }
    }

    private var statusLine: String {
        switch stage {
        case .planReview: "Te toca firmar el plan v\(detail?.planVersion ?? cached?.planVersion ?? 1)"
        case .escalated: "Te toca decidir"
        case .prReview where mergeQueued: "Merge en cola: esperando el CI"
        case .prReview: "Te toca revisar el PR"
        case .planning, .building, .checking:
            FactoryFormat.working(detail?.running.first?.role ?? ["planning": "plan", "building": "build", "checking": "check"][stage.rawValue])
        case .done: "Terminado: PR mergeado"
        case .cancelled: "Cancelado"
        case .unknown: "Cargando…"
        }
    }

    private var statusExtra: String? {
        let loops = detail?.loops ?? cached?.loops ?? 0
        let parts = [
            loops > 0 ? "Vueltas de check: \(loops)" : nil,
            detail?.room.map { "#\($0)" },
            FactoryFormat.ago(FactoryAPI.date(detail?.updatedAt ?? cached?.updatedAt)).map { "movido \($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var statusCard: some View {
        let tone = FactoryTone.of(stage)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                FactoryProgressRing(stage: stage)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusLine)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(tone.ink)
                        .contentTransition(.opacity)
                    if let statusExtra { Text(statusExtra).gMeta() }
                }
                Spacer(minLength: 0)
            }
            FactoryStepBar(stage: stage, dependabot: (detail?.kind ?? cached?.kind) == "dependabot")
            if let running = detail?.running, !running.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(running, id: \.self) { r in
                        FactoryLiveRole(role: r.role, since: r.since, live: live?.role(r.role))
                    }
                }
            }
        }
        .padding(16)
        .ghostyCard()
    }

    private var escalationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(Color.gAmber)
                Text("Lo que encontró @check").gCardTitle()
            }
            Text(detail?.blocked == true
                 ? "@check no pudo revisar: falta algo que sólo tú puedes dar. Cuando lo resuelvas, que @check vuelva a revisar el mismo PR, sin otra vuelta de @build."
                 : (detail?.loops ?? 0) >= 3
                 ? "@check frenó \(detail?.loops ?? 0) veces. Si los puntos caben en el plan, que @build los arregle."
                 : "Falta algo que @build no puede resolver con sus herramientas: dalo tú, o rehaz el plan.")
                .gMeta()
                .fixedSize(horizontal: false, vertical: true)
            if let findings = detail?.findings {
                GhostyMarkdown(markdown: findings)
                    .padding(.top, 2)
                    .accessibilityIdentifier("hallazgos")
            }
            if let names = detail?.missingEnv, !names.isEmpty {
                // Las variables viven en la compu (el .env, el gestor de contraseñas): se las pide
                // al agente de terminal. El portapapeles universal de Apple lo deja en la Mac.
                Text("Faltan \(names.count == 1 ? "1 variable" : "\(names.count) variables") de la preview. Están en tu compu: pídeselas a tu agente de terminal (Claude Code, Codex).")
                    .gMeta()
                    .fixedSize(horizontal: false, vertical: true)
                Button { copyForTerminal() } label: {
                    Label("Copiar para mi agente de terminal", systemImage: "terminal.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
                .buttonStyle(.gPressPrimary)
                .disabled(detail == nil)
                .accessibilityIdentifier("copiar-para-terminal")
                Button { envOpen = true } label: {
                    Label("O pégalas aquí", systemImage: "key")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
                .disabled(busy || detail == nil)
                .accessibilityIdentifier("dar-variables")
            }
            Button { advising = true } label: {
                Label("¿Qué hago?", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.gPrimary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.gPrimaryTint, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.gPressPrimary)
            .disabled(busy || detail == nil)
            .accessibilityIdentifier("que-hago")
        }
        .padding(16)
        .background(Color.gAmberTint.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.gAmber.opacity(0.35), lineWidth: 1))
    }

    private func planCard(_ plan: FactoryRunDetail.Plan) -> some View {
        let open = planOpen || stage == .planReview
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.3)) { planOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(Color.gInk2)
                    Text("Plan v\(plan.version)").gCardTitle()
                    decisionChip(plan.decision)
                    Spacer()
                    if stage != .planReview {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.gChevron)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(stage == .planReview)
            .accessibilityIdentifier("plan-encabezado")
            if open {
                Rectangle().fill(Color.gHairline).frame(height: 1)
                GhostyMarkdown(markdown: plan.markdown)
                    .accessibilityIdentifier("plan-texto")
                    .transition(.opacity)
                if let plans = detail?.plans, plans.count > 1 {
                    Text(plans.map { "v\($0.version) \(decisionText($0.decision) ?? "por firmar")" }.joined(separator: " · "))
                        .gCaption()
                }
            }
        }
        .padding(16)
        .ghostyCard()
    }

    private func decisionText(_ d: String?) -> String? {
        switch d {
        case "approve": "firmado"
        case "changes": "con cambios"
        default: nil
        }
    }

    @ViewBuilder
    private func decisionChip(_ d: String?) -> some View {
        let (text, ink, bg): (String, Color, Color) = switch d {
        case "approve": ("Firmado", .gGreenInk, .gGreenTint)
        case "changes": ("Con cambios", .gInk2, .gFill)
        default: ("Por firmar", .gAmberInk, .gAmberTint)
        }
        Text(text).gChip().foregroundStyle(ink)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(bg, in: Capsule())
    }

    @ViewBuilder
    private var linksRow: some View {
        let pr = (detail?.pr ?? cached?.pr).flatMap(URL.init(string:))
        let preview = (detail?.preview ?? cached?.preview).flatMap(URL.init(string:))
        let teams = FactoryAPI.teamsURL(slug, room: detail?.room ?? cached?.room, thread: detail?.thread ?? cached?.thread)
        if pr != nil || preview != nil || teams != nil {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if let pr { linkPill("Ver PR \(cached?.prNumber ?? "")", "arrow.triangle.pull", pr) }
                    if let preview { linkPill("Ver preview", "eye", preview) }
                    if let teams { linkPill("Abrir el hilo", "bubble.left.and.bubble.right", teams) }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func linkPill(_ title: String, _ icon: String, _ url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title.trimmingCharacters(in: .whitespaces)).font(.system(size: 14, weight: .semibold))
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.gInk3)
            }
            .foregroundStyle(Color.gInk)
            .padding(.horizontal, 14).frame(height: 36)
            .background(Color.gFill, in: Capsule())
        }
        .buttonStyle(.gPressPill)
    }

    private func logCard(_ all: [FactoryRunDetail.Event]) -> some View {
        // La nota que deja la firma ya se ve debajo de «Firmaste»: no se repite como renglón.
        let events = FactoryFormat.withoutEchoedNotes(all)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Bitácora").gSectionCaps().padding(.bottom, 10)
            ForEach(Array(events.enumerated()), id: \.offset) { i, e in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle().fill(i == 0 ? FactoryTone.of(stage).accent : Color.gFillStrong).frame(width: 9, height: 9)
                            .padding(.top, 5)
                        if i < events.count - 1 { Rectangle().fill(Color.gHairline).frame(width: 1.5).frame(maxHeight: .infinity) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        FactoryFormat.logLine(e)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.gInk)
                            .fixedSize(horizontal: false, vertical: true)
                        // Lo que mandaste al firmar: la nota para @build y lo único que revisa @check.
                        if ["approve", "changes"].contains(e.type) {
                            FactoryDecisionNote(note: e.data?["note"]?.string, scope: e.data?["checkScope"]?.string)
                        }
                        if let d = FactoryAPI.date(e.at) {
                            Text(d.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "es_MX"))))
                                .gCaption()
                        }
                    }
                    .padding(.bottom, 12)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .ghostyCard()
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.gGreen)
            Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gInk)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.gGreenTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("aviso-pedido")
        .transition(.gIn)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.gDanger)
            Text(text).font(.system(size: 14)).foregroundStyle(Color.gDangerInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.gDangerTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Decisiones

    private var actionBar: some View {
        let version = detail?.planVersion ?? cached?.planVersion ?? 1
        return HStack(spacing: 10) {
            switch stage {
            case .planReview:
                barButton("Pedir cambios", primary: false, id: "pedir-cambios") { asking = .changes }
                barButton("Firmar plan v\(version)", primary: true, id: "firmar-plan") { confirm = .approve(version) }
            case .escalated where detail?.blocked == true:
                // @build no puede dar lo que falta: otra vuelta sólo gasta tokens (#125, 20-oct).
                barButton("Rehacer el plan", primary: false, id: "replanear") { asking = .replan }
                barButton("Que @check revise", primary: true, id: "volver-a-revisar", icon: "checkmark.shield") { confirm = .recheck }
            case .escalated:
                barButton("Rehacer el plan", primary: false, id: "replanear") { asking = .replan }
                barButton("Que @build lo arregle", primary: true, id: "otra-vuelta") { confirm = .anotherLoop }
            case .prReview where mergeQueued:
                // Ya se pidió: un segundo toque no hace nada útil. Al entrar, la etapa pasa a «Terminado».
                HStack(spacing: 8) {
                    ProgressView()
                    Text("En cola: entra en cuanto pase el CI").gButtonLabel()
                }
                .foregroundStyle(Color.gInk2)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .accessibilityIdentifier("merge-en-cola")
            case .prReview:
                barButton("Merge", primary: true, id: "merge", icon: "arrow.triangle.merge") { confirm = .merge }
            default:
                EmptyView()
            }
        }
        .disabled(busy || detail == nil)
        .padding(.horizontal, Theme.Space.screenH)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.gBg.overlay(alignment: .top) { Rectangle().fill(Color.gHairline).frame(height: 1) }.ignoresSafeArea())
    }

    private func barButton(_ title: String, primary: Bool, id: String, icon: String? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy && primary { ProgressView().tint(.white) }
                else if let icon { Image(systemName: icon).font(.system(size: 14, weight: .bold)) }
                Text(title).gButtonLabel()
            }
            .foregroundStyle(primary ? Color.white : Color.gInk)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(primary ? Color.gPrimary : Color.gFill,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .shadow(color: primary ? Color.gPrimary.opacity(0.3) : .clear, radius: 8, y: 4)
        }
        .buttonStyle(.gPressPrimary)
        .accessibilityIdentifier(id)
    }

    private func confirmTitle(_ p: Pending) -> String {
        switch p {
        case .approve(let v): "¿Firmar el plan v\(v)?"
        case .anotherLoop: "¿Que @build lo arregle?"
        case .recheck: "¿Que @check revise otra vez?"
        case .merge: "¿Mergear el PR?"
        }
    }

    private func confirmMessage(_ p: Pending) -> String {
        switch p {
        case .approve: "Pedido #\(id). @build empieza a construir en cuanto firmes."
        case .anotherLoop: "Pedido #\(id). @build vuelve a intentarlo con lo que encontró @check."
        case .recheck: "Pedido #\(id). @check revisa el mismo PR con lo que resolviste; @build no da otra vuelta."
        case .merge: "Pedido #\(id). " + (detail?.pr.map { "Se mergea \($0.replacingOccurrences(of: "https://github.com/", with: ""))." } ?? "Se mergea el PR.")
        }
    }

    private func confirmAction(_ p: Pending) -> String {
        switch p {
        case .approve(let v): "Firmar plan v\(v)"
        case .anotherLoop: "Que @build lo arregle"
        case .recheck: "Que @check revise"
        case .merge: "Merge"
        }
    }

    /// El pedido para el agente de terminal: qué repo, qué falta y los comandos exactos. Valores de
    /// prueba, nunca de producción (la preview corre el código del repo).
    private func copyForTerminal() {
        guard let d = detail else { return }
        let repo = d.repo ?? "DUEÑO/REPO"
        let text = """
        Pon las variables de entorno de la fábrica de Ghosty para \(repo) (pedido #\(id), espacio \(slug)). \
        Faltan: \(d.missingEnv.joined(separator: ", ")). \
        Mira qué falta con `ghosty factory env ls \(repo) --workspace \(slug)`, usa valores DESECHABLES (base de prueba, llaves nuevas; nunca los de producción) \
        y súbelas con `ghosty factory env push \(repo) <archivo> [--gen LLAVE,LLAVE] --workspace \(slug)`. \
        Luego `ghosty factory runs recheck \(id) --workspace \(slug)` para que @check revise otra vez.
        """
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        withAnimation(.snappy) { notice = "Copiado. En tu Mac ya puedes pegarlo en tu agente de terminal." }
    }

    /// Guarda las variables de la preview del repo del pedido. Sólo el dueño del espacio (gs
    /// contesta 403 a los demás). Al guardarlas, ofrece de una que @check vuelva a revisar.
    private func saveEnv(_ dotenv: String) async -> String? {
        if DemoData.encendido {
            withAnimation(.snappy) { notice = "Guardé las variables. La preview se reconstruye con ellas." }
            offerRecheck = true
            return nil
        }
        do {
            let r = try await FactoryAPI.act(slug, id, .env, dotenv: dotenv)
            let n = r.keys.count
            withAnimation(.snappy) {
                notice = "Guardé \(n == 1 ? "1 variable" : "\(n) variables"). La preview se reconstruye con ellas."
                error = nil
            }
            offerRecheck = true
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func load() async {
        if DemoData.encendido {
            detail = FactoryStore.demoDetail(id)
            live = FactoryStore.demoLive(id)
            #if !GHOSTY_EXTENSION
            if let detail { FactoryLiveActivity.sync(slug: slug, run: detail, live: live) }
            #endif
            return
        }
        do {
            let d = try await FactoryAPI.run(slug, id)
            withAnimation(.snappy(duration: 0.3)) { detail = d; error = nil }
        } catch {
            if detail == nil { self.error = error.localizedDescription }
        }
        // Los pasos sólo con alguien trabajando; si falla, la tarjeta se queda con el reloj.
        if detail?.running.isEmpty == false {
            let l = try? await FactoryAPI.live(slug, id)
            withAnimation(.easeOut(duration: 0.3)) { live = l }
        } else {
            live = nil
        }
        #if !GHOSTY_EXTENSION
        if let detail { FactoryLiveActivity.sync(slug: slug, run: detail, live: live) }
        #endif
    }

    private func act(_ action: FactoryAPI.Action, version: Int? = nil, note: String? = nil, checkScope: String? = nil,
                     skipPreview: Bool = false) async {
        busy = true
        defer { busy = false }
        if DemoData.encendido {
            withAnimation { notice = action == .merge ? "Mergeado." : "Listo (demo)" }
            if action == .merge { confetti = UUID() }
            return
        }
        do {
            let r = try await FactoryAPI.act(slug, id, action, version: version, note: note, checkScope: checkScope,
                                             skipPreview: skipPreview)
            let msg: String = switch action {
            case .approve: stage == .escalated ? "@build ya lo está arreglando." : "Firmado: @build empieza a construir."
            case .changes: stage == .escalated ? "@plan ya está rehaciendo el plan." : "Cambios pedidos: @plan prepara otra versión."
            case .recheck: "@check ya está revisando otra vez."
            case .env: "Variables guardadas."
            case .merge: r.queued ? "Merge en cola: entra en cuanto pase el CI." : "Mergeado."
            case .card: "Tarjeta enviada al hilo."
            }
            withAnimation(.snappy) { notice = msg; error = nil }
            if action == .merge { confetti = UUID() }
            await load()
            await FactoryStore.shared.refresh(space: slug)
        } catch let e as FactoryAPI.Failure where action == .merge && !skipPreview && e.message.localizedCaseInsensitiveContains("preview") {
            mergeError = e.message
            mergeWithoutPreview = true
        } catch {
            withAnimation(.snappy) { self.error = error.localizedDescription; notice = nil }
        }
    }

    private var moreMenu: some View {
        Menu {
            if let pr = (detail?.pr ?? cached?.pr).flatMap(URL.init(string:)) {
                Button { openURL(pr) } label: { Label("Ver el PR en GitHub", systemImage: "arrow.triangle.pull") }
            }
            if let t = FactoryAPI.teamsURL(slug, room: detail?.room ?? cached?.room, thread: detail?.thread ?? cached?.thread) {
                Button { openURL(t) } label: { Label("Abrir el hilo en Teams", systemImage: "bubble.left.and.bubble.right") }
            }
            if detail?.blocked == true {
                // La salida de siempre, por si de verdad era de código.
                Button { confirm = .anotherLoop } label: { Label("Que @build lo intente", systemImage: "hammer") }
            }
            Button { Task { await act(.card) } } label: { Label("Mandar la tarjeta al hilo", systemImage: "rectangle.portrait.on.rectangle.portrait") }
            Button { Task { await load() } } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
        } label: {
            TintedIcon(systemName: "ellipsis", tint: .gInk, background: .gFill, size: 34)
        }
        .accessibilityIdentifier("pedido-mas")
    }
}

/// «¿Qué hago?»: la recomendación para un pedido escalado, con la nota para @build y el alcance de
/// @check editables. «Aplicar» decide con ellos; nunca se aplica sola.
struct FactoryAdviceSheet: View {
    let slug: String
    let id: Int
    var onApply: (FactoryAdvice, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var advice: FactoryAdvice?
    @State private var error: String?
    @State private var note = ""
    @State private var scope = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("¿Qué hago?").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.gInk)
                    Spacer()
                    Button { dismiss() } label: { TintedIcon(systemName: "xmark", tint: .gInk, background: .gFill, size: 32) }
                        .buttonStyle(.gPressIcon)
                }
                if let advice {
                    content(advice)
                } else if let error {
                    Text(error).font(.system(size: 15)).foregroundStyle(Color.gDangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Intentar otra vez") { Task { await load() } }
                        .font(.system(size: 15, weight: .semibold))
                } else {
                    HStack(spacing: 10) {
                        GhostySpinner(size: 16)
                        Text("Comparando lo que encontró @check con el plan firmado…").gMeta()
                    }
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("analizando")
                }
            }
            .padding(Theme.Space.screenH)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Color.gBg)
        .task { await load() }
    }

    @ViewBuilder
    private func content(_ a: FactoryAdvice) -> some View {
        Text(a.fix ? "Que @build lo arregle" : "Rehacer el plan")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(a.fix ? Color.gGreenInk : Color.gAmberInk)
            .accessibilityIdentifier("recomendacion")
        Text(a.why).font(.system(size: 15)).foregroundStyle(Color.gInk).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(a.buildNote.enumerated()), id: \.offset) { i, p in
                VStack(alignment: .leading, spacing: 2) {
                    // `LocalizedStringKey`: el `código` de la nota sale como código, no con sus comillas.
                    Text(LocalizedStringKey("\(i + 1). \(p.point)")).font(.system(size: 14)).foregroundStyle(Color.gInk)
                    Text(LocalizedStringKey(p.cites)).gCaption()
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        Text(a.fix ? "Nota para @build" : "Qué cambiar en el plan").gSectionCaps().padding(.top, 4)
        TextEditor(text: $note)
            .font(.system(size: 15))
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: 120)
            .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .accessibilityIdentifier("nota-recomendada")
        if a.fix {
            Text("@check revisa sólo").gSectionCaps()
            TextField("Alcance de la siguiente revisión", text: $scope, axis: .vertical)
                .font(.system(size: 15))
                .padding(10)
                .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .accessibilityIdentifier("alcance-check")
        }
        Button {
            onApply(a, note.trimmingCharacters(in: .whitespacesAndNewlines), scope.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } label: {
            Text("Aplicar").gButtonLabel().foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.gPressPrimary)
        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("aplicar")
        Text("No se aplica sola: revisa la nota antes.").gCaption()
    }

    private func load() async {
        error = nil
        if DemoData.encendido {
            show(FactoryStore.demoAdvice)
            return
        }
        do {
            show(try await FactoryAPI.advise(slug, id))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func show(_ a: FactoryAdvice) {
        withAnimation(.snappy(duration: 0.3)) {
            advice = a
            note = a.note
            scope = a.checkScope
        }
    }
}

/// «Pedir cambios» / «Rehacer el plan»: lo que la persona quiere distinto, para @plan.
struct FactoryNoteSheet: View {
    let kind: FactoryRunView.AskKind
    var onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(kind == .changes ? "Pedir cambios" : "Rehacer el plan").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.gInk)
                Spacer()
                Button { dismiss() } label: { TintedIcon(systemName: "xmark", tint: .gInk, background: .gFill, size: 32) }
                    .buttonStyle(.gPressIcon)
            }
            Text(kind == .changes ? "Dile a @plan qué quieres distinto en el plan." : "@plan rehace el plan con lo que le digas.")
                .gMeta()
            TextEditor(text: $note)
                .focused($focused)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 140)
                .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .accessibilityIdentifier("nota-cambios")
            Button {
                onSend(note.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } label: {
                Text("Mandar a @plan").gButtonLabel().foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.gPressPrimary)
            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            .opacity(note.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 ? 0.5 : 1)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.screenH)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Color.gBg)
        .onAppear { focused = true }
    }
}

/// «Nuevo pedido»: room (o repo) + qué quieres. Publica «@plan …» en el room del espacio.
struct FactoryNewRunSheet: View {
    let space: FactorySpace
    /// El room ya escogido (viene de «Pide el primer cambio» al conectar un repo).
    var initialRoom: String? = nil
    /// «+ Conectar repo» al final de los rooms.
    var onConnectRepo: (() -> Void)? = nil
    var onCreated: (FactoryAPI.NewRun) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var room: String?
    @State private var factoryRooms: [FactoryRooms.Room] = []
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @State private var done: FactoryAPI.NewRun?

    /// Los rooms de fábrica del espacio (gs `…/factory/rooms`), más los que ya tienen pedidos y el
    /// recién conectado, aunque la lista todavía no lo traiga.
    private var rooms: [(room: String, repo: String?)] {
        var seen = Set<String>()
        var out: [(room: String, repo: String?)] = []
        if let initialRoom, seen.insert(initialRoom).inserted { out.append((initialRoom, nil)) }
        for r in factoryRooms where r.factory && seen.insert(r.slug).inserted { out.append((r.slug, r.repos.first)) }
        for r in space.runs {
            if let room = r.room, seen.insert(room).inserted { out.append((room, r.repo)) }
        }
        return out
    }

    private var valid: Bool { room != nil && text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 15 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Nuevo pedido").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.gInk)
                Spacer()
                Button { dismiss() } label: { TintedIcon(systemName: "xmark", tint: .gInk, background: .gFill, size: 32) }
                    .buttonStyle(.gPressIcon)
            }
            if let done {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Listo: @plan ya lo está leyendo en #\(done.room).", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Color.gGreenInk)
                    Text("En unos minutos aparece aquí para que firmes el plan.").gMeta()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gGreenTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Text("¿En qué room?").gSectionCaps()
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(rooms, id: \.room) { r in
                            let on = room == r.room
                            Button { room = r.room } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("#\(r.room)").font(.system(size: 14, weight: .semibold))
                                    if let repo = r.repo { Text(repo).font(.system(size: 11)).opacity(0.75) }
                                }
                                .foregroundStyle(on ? Color.white : Color.gInk)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(on ? Color.gDark : Color.gFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.gPressPill)
                            .accessibilityIdentifier("nuevo-room-\(r.room)")
                            .accessibilityValue(on ? "escogido" : "")
                        }
                        if let onConnectRepo {
                            Button(action: onConnectRepo) {
                                Label("Conectar repo", systemImage: "plus")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gPrimary)
                                    .padding(.horizontal, 12).frame(maxHeight: .infinity)
                                    .background(Color.gPrimaryTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.gPressPill)
                            .accessibilityIdentifier("nuevo-conectar-repo")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .scrollIndicators(.hidden)
                Text("¿Qué quieres?").gSectionCaps()
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 130)
                    .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Qué quieres, por qué y cómo se sabe que quedó.")
                                .font(.system(size: 16)).foregroundStyle(Color.gInk4)
                                .padding(.horizontal, 15).padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }
                if let error { Text(error).font(.system(size: 13)).foregroundStyle(Color.gDangerInk) }
                Button { Task { await send() } } label: {
                    HStack(spacing: 6) {
                        if sending { ProgressView().tint(.white) }
                        Text("Mandar a @plan").gButtonLabel()
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
                .buttonStyle(.gPressPrimary)
                .disabled(!valid || sending)
                .opacity(valid ? 1 : 0.5)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.screenH)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Color.gBg)
        .onAppear { if room == nil { room = initialRoom ?? rooms.first?.room } }
        .task {
            if DemoData.encendido { factoryRooms = FactoryStore.demoRooms; return }
            if let r = try? await FactoryAPI.rooms(space.slug) {
                factoryRooms = r.rooms
                if room == nil { room = rooms.first?.room }
            }
        }
    }

    private func send() async {
        guard let room else { return }
        sending = true
        defer { sending = false }
        do {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let r = DemoData.encendido
                ? FactoryAPI.NewRun(room: room, threadId: 9005, url: nil)
                : try await FactoryAPI.create(space.slug, room: room, repo: nil, text: clean)
            // No se queda diciendo «Listo»: @plan puede contestar con un plan, un sprint, ideas o una
            // pregunta. Se abre el hilo del pedido y ahí se ve qué hizo.
            FactoryStore.shared.addPending(slug: space.slug, room: r.room, threadId: r.threadId, text: clean)
            error = nil
            dismiss()
            onCreated(r)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Confirmar una decisión (firmar, otra vuelta, merge): hoja corta de fondo sólido, no el action
/// sheet del sistema. El botón dice exactamente lo que va a pasar.
struct FactoryConfirmSheet: View {
    let title: String
    let message: String
    let action: String
    var identifier = "confirmar"
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 22, weight: .heavy)).foregroundStyle(Color.gInk)
            Text(message).gBody().foregroundStyle(Color.gInk2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                dismiss()
                onConfirm()
            } label: {
                Text(action).gButtonLabel().foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.gPressPrimary)
            .accessibilityIdentifier(identifier)
            Button { dismiss() } label: {
                Text("Cancelar").gButtonLabel().foregroundStyle(Color.gInk)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.gPressRow)
            .accessibilityIdentifier("confirmar-cancelar")
        }
        .padding(.horizontal, Theme.Space.screenH)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Color.gBg)
    }
}

/// Las variables que pide la preview, una por renglón con su nombre ya puesto: la persona sólo
/// pega el valor. Van a la bóveda de gs (`env-set`) y nunca regresan; quien escribe los valores es
/// la persona, nunca un agente.
struct FactoryEnvSheet: View {
    let repo: String?
    let names: [String]
    /// Regresa el error para enseñarlo, o nil si se guardó (y la hoja se cierra).
    var onSave: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var reveal = false
    @State private var saving = false
    @State private var error: String?

    private var filled: [String] {
        names.filter { !(values[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Variables de la preview").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.gInk)
                    Spacer()
                    Button { dismiss() } label: { TintedIcon(systemName: "xmark", tint: .gInk, background: .gFill, size: 32) }
                        .buttonStyle(.gPressIcon)
                }
                Text("Las pide la preview\(repo.map { " de \($0)" } ?? ""). Se guardan cifradas y nadie las vuelve a ver, ni los agentes en el chat. Sólo el dueño del espacio puede guardarlas.")
                    .gMeta()
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    ForEach(names, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Color.gInk2)
                            Group {
                                if reveal {
                                    TextField("Valor", text: binding(name))
                                } else {
                                    SecureField("Valor", text: binding(name))
                                }
                            }
                            .font(.system(size: 15, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .padding(10)
                            .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .accessibilityIdentifier("valor-\(name)")
                        }
                    }
                }
                Toggle("Mostrar los valores", isOn: $reveal).font(.system(size: 15)).tint(Color.gPrimary)
                if let error {
                    Text(error).font(.system(size: 14)).foregroundStyle(Color.gDangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if saving { ProgressView().tint(.white) } else { Image(systemName: "lock.fill") }
                        Text(filled.count == names.count ? "Guardar" : "Guardar \(filled.count) de \(names.count)").gButtonLabel()
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
                .buttonStyle(.gPressPrimary)
                .disabled(filled.isEmpty || saving)
                .opacity(filled.isEmpty ? 0.5 : 1)
                .accessibilityIdentifier("guardar-variables")
            }
            .padding(Theme.Space.screenH)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Color.gBg)
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func save() async {
        saving = true
        defer { saving = false }
        // Formato .env de gs (`parseDotenv`): las comillas protegen espacios y `#`, sin escapes.
        let dotenv = filled.map { name -> String in
            let v = (values[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let q = v.contains("\"") ? "'" : "\""
            return "\(name)=\(v.contains(where: { " #\"'".contains($0) }) ? q + v + q : v)"
        }.joined(separator: "\n")
        if let e = await onSave(dotenv) {
            withAnimation(.snappy) { error = e }
        } else {
            dismiss()
        }
    }
}
