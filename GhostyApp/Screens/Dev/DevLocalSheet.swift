import SwiftUI

// Piezas de Desarrollo que sólo pintan lo que manda gs: los botones de `actions`, el campo de mensaje
// con su `compose` y la ficha mínima de una fila `local` (un pendiente en la terminal de alguien).

/// Una acción del servidor como botón. `primary` = la recomendada; una acción desconocida sale igual, con su `label`.
struct DevActionButton: View {
    let action: DevAction
    var busy = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(action.label).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(fg)
                .background(action.primary && !action.isDisabled ? Color.gPrimary : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(action.primary && !action.isDisabled ? Color.clear : Color.gSeparator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(action.isDisabled || busy)
        .accessibilityIdentifier("dev-action-\(action.id)")
    }

    private var fg: Color {
        if action.isDisabled { return .gInk4 }
        if action.primary { return .white }
        return action.destructive ? .gDangerInk : .gInk
    }
}

/// El campo de mensaje de una fila `local`: se apaga con el motivo de gs sin perder lo escrito, y al enviar
/// dice a dónde llegó (la terminal de @writer o Ghosty en la nube). Nunca «esperando a tu agente» sin dueño.
struct DevComposeBar: View {
    let compose: DevCompose
    let repo: String
    let send: (String) async -> DevSendResult
    @State private var store = DevStore.shared
    @State private var text = ""
    @State private var sending = false
    @State private var result: String?
    @State private var problem: String?
    /// El 409 `no_destination` apaga el campo aunque la fila decía que sí.
    @State private var blocked: DevCompose?

    private var current: DevCompose { blocked ?? compose }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var placeholder: String {
        guard current.enabled else { return "Mensaje" }
        return current.routedTo == "cloud" ? "Escríbele a Ghosty en la nube…" : "Escríbele a \(current.writer.map { "@\($0)" } ?? "tu terminal")…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result { Label(result, systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.gGreenInk) }
            if let problem { Text(problem).gCaption().foregroundStyle(Color.gDangerInk) }
            if !current.enabled {
                Text(current.disabledText).font(.system(size: 13)).foregroundStyle(Color.gAmberInk).fixedSize(horizontal: false, vertical: true)
                if let a = current.action {
                    Button { Task { await tapAction(a) } } label: {
                        Text(a.label).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundStyle(trimmed.isEmpty ? Color.gInk4 : Color.white)
                            .background(trimmed.isEmpty ? Color.gFill : Color.gPrimary, in: Capsule())
                    }
                    .buttonStyle(.plain).disabled(sending || (a.id == Self.resumeID && trimmed.isEmpty))
                    .accessibilityIdentifier("dev-compose-action")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical).lineLimit(1...4)
                    .font(.system(size: 15)).disabled(!current.enabled || sending)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.gFill.opacity(current.enabled ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("dev-compose-field")
                Button { Task { await submit() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                        .foregroundStyle(current.enabled && !trimmed.isEmpty ? Color.gPrimary : Color.gInk4)
                }
                .buttonStyle(.plain).disabled(!current.enabled || trimmed.isEmpty || sending)
                .accessibilityLabel("Enviar").accessibilityIdentifier("dev-compose-send")
            }
        }
        .padding(.top, 4)
        .onChange(of: compose) { _, _ in blocked = nil }
    }

    static let resumeID = "resume_factory_and_send"

    private func tapAction(_ a: DevAction) async {
        guard a.id == Self.resumeID else {
            problem = "Esta versión de la app no sabe «\(a.label)». Hazlo desde la web."
            return
        }
        sending = true
        defer { sending = false }
        if let err = await store.resumeFactory(repo: repo) { problem = err; return }
        blocked = nil
        await deliver()
    }

    private func submit() async {
        sending = true
        defer { sending = false }
        await deliver()
    }

    /// Manda lo escrito; sólo se borra si llegó (si no, se conserva para reintentar).
    private func deliver() async {
        let content = trimmed
        guard !content.isEmpty else { return }
        problem = nil
        switch await send(content) {
        case .sent(let s): result = s.line; text = ""
        case .blocked(let c): blocked = c; result = nil
        case .failed(let m): problem = m
        }
    }
}

/// La ficha mínima de un pendiente de terminal: título, escritor, «Sin señal desde hace X» y las acciones del servidor.
struct DevLocalSheet: View {
    let initial: DevLocalRun
    @State private var store = DevStore.shared
    @State private var busy = false
    @State private var notice: String?
    @State private var pending: DevAction?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Lo último que sabe el store (tras refrescar); si la fila ya no está, lo que se abrió.
    private var run: DevLocalRun { store.local.first { $0.id == initial.id } ?? initial }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(run.repo, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.gInk3)
                Text(run.title).font(.system(size: 20, weight: .bold)).foregroundStyle(Color.gInk)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Label(writerLine, systemImage: "terminal").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gInk2)
                    if let stale = run.claim?.staleLine {
                        Label(stale, systemImage: "clock.badge.exclamationmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gAmberInk)
                            .accessibilityIdentifier("dev-local-stale")
                    } else if let at = run.claim?.at {
                        Text("Última señal \(DevDate.ago(at))").gMeta().foregroundStyle(Color.gInk3)
                    }
                    Text(run.pr.map { "PR #\($0)" } ?? "Issue #\(run.issue)").gMeta().foregroundStyle(Color.gInk3)
                }
                actionsList
                if let c = run.compose {
                    Divider().overlay(Color.gHairline)
                    DevComposeBar(compose: c, repo: run.repo) { text in
                        await store.sendMessage(repo: run.repo, issue: run.issue > 0 ? run.issue : nil, pr: run.pr, content: text)
                    }
                }
            }
            .padding(Theme.Space.screenH).padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .background(Color.gBg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK", role: .cancel) {} }
        .confirmationDialog(pending?.confirm ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let a = pending { Button(a.label, role: a.destructive ? .destructive : nil) { Task { await perform(a) } } }
        }
    }

    private var writerLine: String {
        if let w = run.writer { return "En la terminal de @\(w)" }
        return run.notStarted ? "Nadie lo ha tomado" : "En una terminal"
    }

    /// Las acciones de gs tal cual; sin ellas (gs viejo) sólo queda abrirlo en GitHub.
    @ViewBuilder private var actionsList: some View {
        VStack(spacing: 8) {
            if let acts = run.actions {
                ForEach(acts) { a in
                    DevActionButton(action: a, busy: busy) { tap(a) }
                    if a.isDisabled, let why = a.disabledWhy { Text(why).gCaption().foregroundStyle(Color.gInk3) }
                }
            } else if let u = run.openURL {
                DevActionButton(action: DevAction(id: "open", label: "Abrir en GitHub", kind: .link, href: u, primary: true), busy: busy) { openURL(u) }
            }
        }
    }

    private func tap(_ a: DevAction) {
        if let c = a.confirm, !c.isEmpty { pending = a } else { Task { await perform(a) } }
    }

    private func perform(_ a: DevAction) async {
        busy = true
        defer { busy = false }
        switch await store.perform(a, repo: run.repo, issue: run.issue > 0 ? run.issue : nil, runID: run.prID) {
        case .done: dismiss()
        case .open(let u): openURL(u)
        case .failed(let m): notice = m
        }
    }
}
