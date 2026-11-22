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
    var body: some View {
        let t = run.tone
        HStack(spacing: 2) {
            PulsingDot(color: t.accent, active: t == .working || t == .needsYou, size: 6).padding(.leading, -2)
            Text(run.phaseLabel).gChip().foregroundStyle(t.ink)
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
                    Text(s.label)
                        .font(.system(size: 11, weight: now ? .bold : .medium))
                        .foregroundStyle(now ? run.tone.ink : done ? Color.gInk2 : Color.gInk4)
                        .lineLimit(1)
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
            Text(subtitle).gMeta().foregroundStyle(Color.gInk3).lineLimit(2)
            DevStageBar(run: run).padding(.top, 2)
        }
        .padding(Theme.Space.cardH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostyCard()
    }

    private var subtitle: String {
        var parts: [String] = []
        if let pr = run.pr { parts.append("PR #\(pr)") }
        if run.isLive, run.rounds > 0 { parts.append("vuelta \(run.rounds) de 3") }
        if run.phase == "merged" { parts.append("Merge \(DevDate.ago(run.updatedAt))") }
        else { parts.append(DevDate.ago(run.updatedAt)) }
        return parts.joined(separator: " · ")
    }
}

struct DevHomeView: View {
    /// Hay un pendiente abierto: `RootView` esconde la barra.
    @Binding var inRun: Bool
    @State private var store = DevStore.shared
    @State private var path: [String] = []
    @State private var showClosed = false

    private var visible: [DevRun] { store.runs.filter { showClosed || $0.isLive } }
    private var liveCount: Int { store.runs.filter(\.isLive).count }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Dev").gScreenTitle().padding(.top, 8)
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
        HStack(spacing: 8) {
            chip("Activos \(liveCount)", on: !showClosed) { showClosed = false }
            chip("Todos", on: showClosed) { showClosed = true }
        }
    }

    private func chip(_ text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappy) { action() } }) {
            Text(text).font(.system(size: 14, weight: .semibold))
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
        } else if visible.isEmpty {
            EmptyState(icon: "chevron.left.forwardslash.chevron.right",
                       title: showClosed ? "Todavía no hay pendientes" : "Nada en curso",
                       detail: "Pídele a tu agente un cambio en tu repo y aquí verás cómo avanza: código, CI, revisión y merge.")
        } else {
            LazyVStack(spacing: 12) {
                ForEach(visible) { run in
                    Button { path.append(run.id) } label: { DevRunRow(run: run) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("dev-run-\(run.id)")
                }
            }
        }
    }
}
