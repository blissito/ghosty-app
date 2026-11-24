import SwiftUI

// La pestaña «Dev»: tus pendientes en la nube (gs `/c/desarrollo`). Lista → detalle con
// Conversación, Cambios, Verificación y Actividad. Bocetos aprobados el 22-nov
// (`bocetos/desarrollo-nov22/`).

extension DevRun.Tone {
    var ink: Color {
        switch self {
        case .working: .gPrimaryPressed
        case .needsYou: .gAmberInk
        case .ready: .gGreenInk
        case .merged: .gPrimaryPressed
        case .failed: .gDangerInk
        case .closed: .gInk3
        }
    }
    var accent: Color {
        switch self {
        case .working: .gPrimary
        case .needsYou: .gAmber
        case .ready: .gGreen
        case .merged: .gPrimaryLight
        case .failed: .gDanger
        case .closed: .gInk4
        }
    }
    var tint: Color {
        switch self {
        case .working, .merged: .gPrimaryTint
        case .needsYou: .gAmberTint
        case .ready: .gGreenTint
        case .failed: .gDangerTint
        case .closed: .gFill
        }
    }
}

/// La pastilla de fase: punto (late si va trabajando o te necesita) + nombre.
struct DevPhaseChip: View {
    let run: DevRun
    /// El turno del escritor sigue vivo. gs pasa a «Esperando el CI» al subir el commit aunque el agente
    /// siga trabajando (PR #139, 22-nov): mientras su turno no cierre, la pastilla dice «Trabajando».
    var writerBusy = false
    var body: some View {
        let t = run.tone
        HStack(spacing: 2) {
            PulsingDot(color: t.accent, active: t == .working || t == .needsYou, size: 6).padding(.leading, -2)
            Text(writerBusy && t == .working ? "Trabajando" : run.phaseLabel).gChip().foregroundStyle(t.ink)
        }
        .padding(.trailing, 10).padding(.leading, 4).padding(.vertical, 3)
        .background(t.tint, in: Capsule())
        .fixedSize()
    }
}

/// Código → CI → Revisión → Merge, como la web: lo hecho en verde, lo actual en el tono de la fase,
/// lo que falta en gris; con el merge hecho, toda la barra en lila.
struct DevStageBar: View {
    let run: DevRun
    /// Sin etiquetas: sólo las barras (encabezado de Conversación).
    var compact = false
    var body: some View {
        let at = run.stage.rawValue
        let merged = run.phase == "merged"
        HStack(alignment: .top, spacing: 5) {
            ForEach(DevStage.allCases, id: \.rawValue) { s in
                let i = s.rawValue
                let done = merged || i < at || (run.readyToMerge && i < 3)
                let now = !merged && i == at
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(merged ? Color.gPrimaryLight : done ? Color.gGreen : now ? run.tone.accent : Color.gFillStrong)
                        .frame(height: 6)
                    if !compact { Text(s.label)
                        .font(.system(size: 11, weight: now ? .bold : .medium))
                        .foregroundStyle(now ? run.tone.ink : done ? Color.gInk2 : Color.gInk4)
                        .lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Etapa: \(run.stage.label)")
    }
}

struct DevRunRow: View {
    let run: DevRun
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Label(run.repo, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.gInk3).lineLimit(1)
                Spacer(minLength: 8)
                DevPhaseChip(run: run)
            }
            Text(run.title).gCardTitle().foregroundStyle(Color.gInk).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if let n = run.issue, n > 0 { refChip("Issue #\(n)", "exclamationmark.circle") }
                if let pr = run.pr { refChip("PR #\(pr)", "arrow.triangle.pull") }
                Text(subtitle).gMeta().foregroundStyle(Color.gInk3).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            if let q = run.asked?.question { Text(q).font(.system(size: 13)).foregroundStyle(Color.gAmberInk).lineLimit(1) }
            DevStageBar(run: run).padding(.top, 2)
        }
        .padding(Theme.Space.cardH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostyCard()
    }

    private func refChip(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.gInk2)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 4).background(Color.gFill, in: Capsule())
    }

    private var subtitle: String {
        var parts: [String] = []
        if run.isLive, run.rounds > 0 { parts.append("vuelta \(run.rounds) de 3") }
        if run.phase == "merged" { parts.append("Merge \(DevDate.ago(run.updatedAt))") }
        else { parts.append(DevDate.ago(run.updatedAt)) }
        return parts.joined(separator: " · ")
    }
}

/// Fila de un pendiente que alguien trabaja en su terminal: misma tarjeta, sin etapas (gs no las conoce).
struct DevLocalRunRow: View {
    let run: DevLocalRun
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Label(run.repo, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.gInk3).lineLimit(1)
                Spacer(minLength: 8)
                Label(run.phaseLabel, systemImage: "terminal")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.gInk2)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.gFill, in: Capsule())
            }
            Text(run.title).gCardTitle().foregroundStyle(Color.gInk).multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                Text(subtitle).gMeta().foregroundStyle(Color.gInk3).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: run.pr == nil ? "arrow.up.right" : "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.gInk3)
            }
        }
        .padding(Theme.Space.cardH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostyCard()
    }

    private var subtitle: String {
        var parts = [run.pr.map { "PR #\($0)" } ?? "Issue #\(run.issue)"]
        parts.append(run.writer.map { "en su terminal · @\($0)" } ?? "en una terminal")
        parts.append(DevDate.ago(run.updatedAt))
        return parts.joined(separator: " · ")
    }
}

struct DevHomeView: View {
    /// Hay un pendiente abierto: `RootView` esconde la barra.
    @Binding var inRun: Bool
    @State private var store = DevStore.shared
    @State private var path: [String] = []
    @State private var showClosed = false
    @State private var onlyNeedsYou = false
    /// Repo elegido (`nil` = todos), como el selector de la web.
    @State private var repo: String?
    @Environment(\.openURL) private var openURL

    /// Los de la nube y los PRs (de terminal o de una persona) juntos, lo más reciente arriba, como la web.
    private var visible: [DevRun] {
        (store.runs + store.prs).filter { (showClosed || $0.isOnBoard) && (!onlyNeedsYou || $0.tone == .needsYou) && !$0.isHiddenHistory && (repo == nil || $0.repoName == repo) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    /// Los de terminal que ya tienen PR salen como su tarjeta de PR; aquí quedan sólo los que todavía no lo abren.
    private var localOnly: [DevLocalRun] {
        let shown = Set(store.prs.map(\.id))
        return store.local.filter { ($0.prID.map { !shown.contains($0) } ?? true) && (repo == nil || $0.repoName == repo) && !["ghosty-studio", "easybits"].contains($0.repoName) }
    }
    private var repos: [String] {
        Set((store.runs + store.prs).filter { !$0.isHiddenHistory }.map(\.repoName) + store.local.map(\.repoName).filter { !["ghosty-studio", "easybits"].contains($0) }).sorted()
    }
    /// Las columnas del tablero que manda gs (`column`) como secciones, sin recalcular fases aquí. Con «Todos» entran Hecho y Detenidos.
    /// Una columna que esta versión no conoce va al final como «Otros»: nunca se esconde una tarjeta.
    private var groups: [(String?, [DevRun])] {
        var order: [(String, String)] = [
            ("ready", "Listo para revisar"), ("review", "En revisión"), ("writing", "Escribiendo"), ("todo", "Pendientes"),
        ]
        if showClosed { order += [("done", "Hecho"), ("halted", "Detenidos")] }
        order.append(("other", "Otros"))
        return order.compactMap { col, title in
            let hit = visible.filter { $0.boardColumn == col }
            return hit.isEmpty ? nil : (title, hit)
        }
    }
    private var needsYouCount: Int { (store.runs + store.prs).count { $0.isOnBoard && $0.tone == .needsYou } }
    private var liveCount: Int { visible.count(where: \.isOnBoard) + localOnly.count }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Desarrollo").gScreenTitle().padding(.top, 8)
                    filters.padding(.top, 14)
                    content.padding(.top, 16)
                }
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refresh() }
            .background(Color.gBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in DevRunView(id: id) }
        }
        .tint(.gInk)
        .onChange(of: path) { _, p in
            withAnimation(.easeOut(duration: 0.2)) { inRun = !p.isEmpty }
            if p.isEmpty { Task { await store.refresh() } }
        }
        .onChange(of: store.pendingRunID, initial: true) { _, id in
            guard let id else { return }
            path = [id]
            store.pendingRunID = nil
        }
        .task {
            // Gancho: `GHOSTY_DEV=<id>` abre ese pendiente al llegar (para verlo en el simulador).
            if let id = Gancho.valor("GHOSTY_DEV"), !id.isEmpty, path.isEmpty { path = [id] }
            await store.refresh()
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
            chip("Activos \(liveCount)", on: !showClosed && !onlyNeedsYou) { showClosed = false; onlyNeedsYou = false }
            if needsYouCount > 0 { chip("Te necesitan \(needsYouCount)", on: onlyNeedsYou) { showClosed = false; onlyNeedsYou = true } }
            chip("Todos", on: showClosed) { showClosed = true; onlyNeedsYou = false }
            if repos.count > 1 {
                Menu {
                    Button { repo = nil } label: { if repo == nil { Label("Todos los repos", systemImage: "checkmark") } else { Text("Todos los repos") } }
                    ForEach(repos, id: \.self) { r in
                        Button { repo = r } label: { if repo == r { Label(r, systemImage: "checkmark") } else { Text(r) } }
                    }
                } label: {
                    HStack(spacing: 5) { Text(repo ?? "Repo"); Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)) }
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize().foregroundStyle(repo == nil ? Color.gInk2 : Color.gPrimaryPressed)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(repo == nil ? Color.gCard : Color.gPrimaryTint, in: Capsule())
                        .overlay(Capsule().stroke(Color.gSeparator, lineWidth: 1))
                }
                .accessibilityIdentifier("dev-repo")
            }
        } }
    }

    private func chip(_ text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappy) { action() } }) {
            Text(text).font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
                .foregroundStyle(on ? Color.gPrimaryPressed : Color.gInk2)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(on ? Color.gPrimaryTint : Color.gCard, in: Capsule())
                .overlay(Capsule().stroke(on ? Color.gPrimaryLight : Color.gSeparator, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if !store.loaded {
            VStack(spacing: 12) { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.gFill).frame(height: 120) } }
        } else if let err = store.error {
            EmptyState(icon: "exclamationmark.triangle", title: err, detail: "Desliza hacia abajo para reintentar.")
        } else if visible.isEmpty && localOnly.isEmpty {
            EmptyState(icon: "chevron.left.forwardslash.chevron.right",
                       title: showClosed ? "Todavía no hay pendientes" : "Nada en curso",
                       detail: "Pídele a tu agente un cambio en tu repo y aquí verás cómo avanza: código, CI, revisión y merge.")
        } else {
            LazyVStack(spacing: 12) {
                ForEach(groups, id: \.0) { title, items in
                    if let title {
                        Text(title).gSectionTitle().foregroundStyle(Color.gInk2).padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(items) { run in
                        Button { path.append(run.id) } label: { DevRunRow(run: run) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("dev-run-\(run.id)")
                    }
                }
                // Issues que alguien tomó en su terminal y todavía no tienen PR: gs sólo sabe su título,
                // así que van al final y abren el issue. Con PR se abren dentro de la app.
                ForEach([("Pendientes", localOnly.filter(\.notStarted)), ("En una terminal", localOnly.filter { !$0.notStarted })], id: \.0) { title, items in
                    if !items.isEmpty {
                        Text(title).gSectionTitle().foregroundStyle(Color.gInk2).padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(items) { run in
                            Button {
                                if let id = run.prID { path.append(id) } else if let u = run.openURL { openURL(u) }
                            } label: { DevLocalRunRow(run: run) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("dev-local-\(run.id)")
                        }
                    }
                }
            }
        }
    }
}
