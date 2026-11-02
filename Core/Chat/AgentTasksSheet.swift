import SwiftUI

/// «Tareas»: la lista que el agente mantiene sola (al estilo Things / Claude Duet).
///
/// Cuatro secciones en orden — te espera, en curso, próximas, resueltas — y nada más. La
/// lista la ordena gs; aquí sólo se reparte por estado. Sólo las notas (`source == "note"`)
/// se palomean a mano: lo demás lo resuelve el agente, o tú en su hilo («Abrir»).
struct AgentTasksSheet: View {
    let agentID: String
    let agentName: String
    /// Abrir el hilo de esa tarea: quien presenta cierra la hoja y entra a la conversación.
    var onOpen: (String) -> Void

    @State private var tasks = AgentTasksStore.shared
    @State private var showAllResolved = false
    /// Lo que acaba de terminar mientras mirabas: se queda un momento en su sección con el
    /// palomeo y luego baja a «Resueltas». Llave = id, valor = la sección donde estaba.
    @State private var lingering: [String: AgentTaskItem.Status] = [:]
    @State private var lastStatus: [String: AgentTaskItem.Status] = [:]
    @Namespace private var rows
    @Environment(\.openURL) private var openURL

    private static let resolvedPreview = 3

    var body: some View {
        let items = tasks.items(for: agentID)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tareas")
                        .font(.system(size: 24, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.gInk)
                    Text(agentName)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.gInk3)
                }
                .padding(.top, 18)

                if items.isEmpty {
                    if tasks.loaded.contains(agentID) { emptyState } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    }
                } else {
                    section("Necesita tu respuesta", bucket(items, .needsYou))
                    section("En curso", bucket(items, .working))
                    section("Próximas", bucket(items, .upcoming))
                    resolvedSection(items)
                }
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.bottom, 24)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: signature(items))
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: showAllResolved)
        }
        .scrollIndicators(.hidden)
        .refreshable { await tasks.refresh(agentID) }
        .background(Color.gBg)
        .task(id: agentID) { await tasks.refresh(agentID) }
        .onChange(of: signature(items), initial: true) { _, _ in noticeCompletions(items) }
        .accessibilityIdentifier("hoja-tareas")
    }

    // MARK: - Reparto

    /// La sección donde se pinta un item: la suya, salvo que acabe de terminar (se queda un
    /// momento arriba con el palomeo antes de bajar).
    private func shownStatus(_ i: AgentTaskItem) -> AgentTaskItem.Status {
        if let was = lingering[i.id] { return was }
        // Antes de que `noticeCompletions` lo apunte (el primer cuadro con el dato nuevo).
        if i.isResolved, let before = lastStatus[i.id], !before.isResolvedStatus { return before }
        return i.status == .failed ? .done : i.status
    }

    private func bucket(_ items: [AgentTaskItem], _ s: AgentTaskItem.Status) -> [AgentTaskItem] {
        items.filter { shownStatus($0) == s }
    }

    private func signature(_ items: [AgentTaskItem]) -> String {
        items.map { "\($0.id):\(shownStatus($0).rawValue):\($0.status.rawValue)" }.joined(separator: "|")
            + "#\(lingering.count)"
    }

    /// ¿Algo pasó a «done» desde la última foto? Se queda en su sitio 0.9 s, palomeado.
    private func noticeCompletions(_ items: [AgentTaskItem]) {
        var next: [String: AgentTaskItem.Status] = [:]
        for i in items {
            next[i.id] = i.status
            if let before = lastStatus[i.id], !before.isResolvedStatus, i.isResolved, lingering[i.id] == nil {
                lingering[i.id] = before
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { _ = lingering.removeValue(forKey: i.id) }
                }
            }
        }
        lastStatus = next
    }

    // MARK: - Secciones

    @ViewBuilder
    private func section(_ title: String, _ items: [AgentTaskItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                header(title, count: items.count)
                ForEach(items) { row($0) }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func resolvedSection(_ all: [AgentTaskItem]) -> some View {
        let resolved = bucket(all, .done)
        if !resolved.isEmpty {
            let shown = showAllResolved ? resolved : Array(resolved.prefix(Self.resolvedPreview))
            VStack(alignment: .leading, spacing: 2) {
                header("Resueltas", count: resolved.count)
                ForEach(shown) { row($0) }
                if resolved.count > Self.resolvedPreview {
                    Button { showAllResolved.toggle() } label: {
                        Text(showAllResolved ? "Ver menos" : "Ver todas (\(resolved.count))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.gPrimary)
                            .padding(.vertical, 10)
                            .padding(.leading, 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tareas-ver-todas")
                }
            }
            .transition(.opacity)
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.gInk3)
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.gInk4)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Renglón

    private func row(_ item: AgentTaskItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            TaskCircle(status: item.status, checkable: item.isCheckable) {
                Task { await tasks.toggle(item, agentID: agentID) }
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.isResolved ? Color.gInk3 : Color.gInk)
                    .strikethrough(item.status == .done && item.isCheckable, color: .gInk3)
                    .lineLimit(1)
                statusLine(item)
                if let p = item.progress, !item.isResolved {
                    ProgressBar(fraction: Double(p.done) / Double(p.total))
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.sessionID != nil || item.url != nil {
                Button { open(item) } label: {
                    HStack(spacing: 2) {
                        Text("Abrir").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Color.gPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.gPrimaryTint, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Abrir «\(item.title)»")
                .accessibilityIdentifier("tarea-abrir-\(item.id)")
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .matchedGeometryEffect(id: item.id, in: rows)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tarea-\(item.id)")
    }

    private func statusLine(_ item: AgentTaskItem) -> some View {
        let (label, color) = Self.statusLabel(item)
        return (Text(label).foregroundColor(color)
                + Text(item.detail.map { " · \($0)" } ?? "").foregroundColor(.gInk3))
            .font(.system(size: 13))
            .lineLimit(1)
    }

    static func statusLabel(_ item: AgentTaskItem, now: Date = Date()) -> (String, Color) {
        switch item.status {
        case .needsYou: return ("Necesita tu respuesta", .gDangerInk)
        case .working: return ("Trabajando", .gPrimary)
        case .upcoming: return (item.dueAt.map { relativeDue($0, now: now) } ?? "Pendiente", .gInk3)
        case .done: return ("Listo", .gGreenInk)
        case .failed: return ("Falló", .gDangerInk)
        }
    }

    /// Reloj de 24 h («18:00», «9:00»), sin a. m./p. m.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "H:mm"
        return f
    }()

    /// «Hoy 18:00», «Mañana 9:00», «12 nov» (o «12 nov 2027» si no es este año).
    static func relativeDue(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = Self.clock.string(from: d)
        if cal.isDate(d, inSameDayAs: now) { return "Hoy \(time)" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: tomorrow) {
            return "Mañana \(time)"
        }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: yesterday) {
            return "Ayer \(time)"
        }
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_MX"))
        if cal.component(.year, from: d) != cal.component(.year, from: now) { style = style.year() }
        return d.formatted(style).replacingOccurrences(of: ".", with: "")
    }

    private func open(_ item: AgentTaskItem) {
        if let sid = item.sessionID { onOpen(sid) } else if let url = item.url { openURL(url) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.gInk3)
            Text("Sin pendientes")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.gInk)
            Text("Cuando tu agente tenga algo entre manos, aparece aquí.")
                .font(.system(size: 14))
                .foregroundStyle(Color.gInk3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityIdentifier("tareas-vacio")
    }
}

private extension AgentTaskItem.Status {
    var isResolvedStatus: Bool { self == .done || self == .failed }
}

/// El círculo de la izquierda: vacío = abierto, anillo que gira = trabajando, check relleno
/// = listo (con su animación al llegar), x = falló. Sólo se toca si la tarea es una nota.
struct TaskCircle: View {
    let status: AgentTaskItem.Status
    var checkable = false
    var onToggle: () -> Void = {}

    @State private var spin = false
    private let size: CGFloat = 24

    var body: some View {
        let circle = ZStack {
            switch status {
            case .done:
                Circle().fill(Color.gGreen)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            case .failed:
                Circle().fill(Color.gDangerTint)
                Circle().stroke(Color.gDanger, lineWidth: 1.5)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.gDangerInk)
            case .working:
                Circle().stroke(Color.gPrimaryRing, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.gPrimary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            case .needsYou:
                Circle().stroke(Color.gDanger, lineWidth: 1.8)
                Circle().fill(Color.gDanger).frame(width: 8, height: 8)
            case .upcoming:
                Circle().stroke(Color.gInk4, lineWidth: 1.6)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: status)
        .sensoryFeedback(.success, trigger: status) { _, new in new == .done }

        if checkable {
            Button(action: onToggle) {
                circle.frame(width: 32, height: 32).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 26)
            .accessibilityLabel(status == .done ? "Marcar como pendiente" : "Marcar como lista")
        } else {
            circle
                .frame(width: 28, height: 26)
                .accessibilityHidden(true)
        }
    }
}

/// La barrita de avance (`progress.done / total`), delgada.
private struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gFill)
                Capsule().fill(Color.gPrimary)
                    .frame(width: max(4, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 3)
        .frame(maxWidth: 180)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// El botón de «Tareas» en la cabecera del hilo, con la insignia: rojo si algo te espera,
/// lila si sólo hay trabajo corriendo.
struct AgentTasksButton: View {
    let counts: AgentTaskCounts
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checklist")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.gInk)
                .frame(width: 40, height: 44)
                .overlay(alignment: .topTrailing) {
                    if counts.badge > 0 {
                        Text("\(counts.badge)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(counts.badgeIsAlert ? Color.gDanger : Color.gPrimary, in: Capsule())
                            .overlay(Capsule().stroke(Color.gBg, lineWidth: 1.5))
                            .offset(x: -2, y: 6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.gPressIcon)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: counts.badge)
        .accessibilityLabel(counts.needsYou > 0 ? "Tareas, \(counts.needsYou) necesitan tu respuesta"
                            : counts.working > 0 ? "Tareas, \(counts.working) en curso" : "Tareas")
        .accessibilityIdentifier("hilo-tareas")
    }
}
