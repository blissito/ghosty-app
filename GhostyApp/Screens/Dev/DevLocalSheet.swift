import SwiftUI

// Piezas de Desarrollo que sólo pintan lo que manda gs: los botones de `actions`, el campo de mensaje
// con su `compose` y la ficha mínima de una fila `local` (un pendiente en la terminal de alguien).

/// Una acción del servidor como botón. `primary` = la recomendada; una acción desconocida sale igual, con su `label`.
struct DevActionButton: View {
    let action: DevAction
    var busy = false
    /// Esta es la que está corriendo: lleva spinner en vez de quedarse quieta.
    var running = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if running { ProgressView().tint(filled ? .white : .gInk2).controlSize(.small) }
                Text(running ? "\(action.label)…" : action.label).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(fg)
                .background(filled ? Color.gPrimary : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(filled ? Color.clear : Color.gSeparator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(action.isDisabled || busy)
        .accessibilityIdentifier("dev-action-\(action.id)")
    }

    /// Lo destructivo («Soltar») nunca se pinta como el botón recomendado, aunque gs lo marque `primary`.
    private var filled: Bool { action.primary && !action.destructive && !action.isDisabled }

    private var fg: Color {
        if action.isDisabled { return .gInk4 }
        if filled { return .white }
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

/// Lo que trajo una acción `read` (el log de la caja), para pintarlo en una hoja.
struct DevReadText: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// La hoja con el texto de una acción `read`: monoespaciado, seleccionable y desde el final (es una cola de log).
struct DevReadSheet: View {
    let item: DevReadText
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    Text(item.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.gInk)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.screenH)
                    Color.clear.frame(height: 1).id("end")
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            .background(Color.gBg.ignoresSafeArea())
            .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Copiar") { UIPasteboard.general.string = item.text } }
                ToolbarItem(placement: .topBarTrailing) { Button("Listo") { dismiss() } }
            }
        }
        .presentationBackground(Color.gBg)
        .accessibilityIdentifier("dev-read-sheet")
    }
}

/// Los campos que gs pide antes de una acción (`fields`, p. ej. «Editar criterio»). Manda sólo con todo lleno.
struct DevActionFormSheet: View {
    let action: DevAction
    /// Ejecuta con los valores; devuelve el error para mostrarlo (o `nil` si salió).
    let submit: ([String: Any]) async -> String?
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    private var parsed: [String: Any]? {
        var out: [String: Any] = [:]
        for f in action.fields {
            let v = (values[f.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { return nil }
            if f.type == "number" { guard let n = Int(v) else { return nil }; out[f.name] = n } else { out[f.name] = v }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(action.fields) { f in
                    Section(f.label) {
                        TextField(f.label, text: Binding(get: { values[f.name] ?? "" }, set: { values[f.name] = $0 }), axis: f.type == "number" ? .horizontal : .vertical)
                            .keyboardType(f.type == "number" ? .numberPad : .default)
                            .accessibilityIdentifier("dev-field-\(f.name)")
                    }
                }
                if let problem { Text(problem).foregroundStyle(Color.gDangerInk) }
            }
            .scrollContentBackground(.hidden)
            .background(Color.gBg.ignoresSafeArea())
            .navigationTitle(action.label).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(busy ? "Enviando…" : "Enviar") {
                        guard let v = parsed else { return }
                        Task {
                            busy = true
                            problem = await submit(v)
                            busy = false
                            if problem == nil { dismiss() }
                        }
                    }
                    .disabled(parsed == nil || busy)
                    .accessibilityIdentifier("dev-field-submit")
                }
            }
        }
        .presentationBackground(Color.gBg)
        .presentationDetents([.medium, .large])
    }
}

/// La ficha mínima de un pendiente de terminal: título, escritor, «Sin señal desde hace X» y las acciones del servidor.
struct DevLocalSheet: View {
    let initial: DevLocalRun
    @State private var store = DevStore.shared
    @State private var busy = false
    @State private var notice: String?
    @State private var pending: DevAction?
    @State private var formAction: DevAction?
    @State private var readText: DevReadText?
    @State private var runningID: String?
    /// Si cabe en la nube: se pregunta al abrir la ficha cuando hay «Mandar a la nube».
    @State private var capacity: DevCapacity?
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
                    // El estado de gs entero («Bloqueado por #94 · …»): en la fila puede ir en dos renglones, aquí completo.
                    if run.phaseLabel != writerLine { Text(run.phaseLabel).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gInk2).fixedSize(horizontal: false, vertical: true) }
                    if let stale = run.claim?.staleLine {
                        Label(stale, systemImage: "clock.badge.exclamationmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gAmberInk)
                            .accessibilityIdentifier("dev-local-stale")
                    } else if let at = run.claim?.at {
                        Text("Última señal \(DevDate.ago(at))").gMeta().foregroundStyle(Color.gInk3)
                    }
                    Text(run.pr.map { "PR #\($0)" } ?? "Issue #\(run.issue)").gMeta().foregroundStyle(Color.gInk3)
                }
                if let cap = capacity {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: cap.fits ? "shippingbox" : "exclamationmark.triangle.fill")
                        Text(cap.line)
                    }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(cap.fits ? Color.gInk3 : Color.gAmberInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dev-capacity")
                    if cap.blocked, let u = cap.buyURL {
                        Button("Conseguir más cajas") { openURL(u) }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.gPrimaryPressed)
                    }
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
        .sheet(item: $formAction) { a in
            DevActionFormSheet(action: a) { v in
                switch await store.perform(a, repo: run.repo, issue: run.issue > 0 ? run.issue : nil, pr: run.pr, runID: run.prID, values: v) {
                case .failed(let m): return m
                default: notice = "Listo: \(a.label.lowercased())."; return nil
                }
            }
        }
        .sheet(item: $readText) { DevReadSheet(item: $0) }
        .task {
            if run.actions?.contains(where: { $0.kind == .start }) == true { capacity = await store.capacity(repo: run.repo) }
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
                    DevActionButton(action: a, busy: busy, running: runningID == a.id) { tap(a) }
                    if a.isDisabled, let why = a.disabledWhy { Text(why).gCaption().foregroundStyle(Color.gInk3) }
                }
            } else if let u = run.openURL {
                DevActionButton(action: DevAction(id: "open", label: "Abrir en GitHub", kind: .link, href: u, primary: true), busy: busy) { openURL(u) }
            }
        }
    }

    private func tap(_ a: DevAction) {
        // Sin lugar ni nada que apagar, gs tardaría en contestar «sin caja libre»: se dice ya.
        if a.kind == .start, let cap = capacity, cap.blocked { notice = "Sin caja libre: \(cap.used) de \(cap.slots) ocupadas. Libera una o consigue más cajas."; return }
        if !a.fields.isEmpty { formAction = a }
        else if let c = a.confirm, !c.isEmpty { pending = a } else { Task { await perform(a) } }
    }

    private func perform(_ a: DevAction) async {
        busy = true
        runningID = a.id
        defer { busy = false; runningID = nil }
        switch await store.perform(a, repo: run.repo, issue: run.issue > 0 ? run.issue : nil, pr: run.pr, runID: run.prID) {
        case .done:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            store.flash = "Listo: \(a.label.lowercased())."
            dismiss()
        case .open(let u): openURL(u)
        case .text(let t): readText = DevReadText(title: a.label, text: t)
        case .failed(let m):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            notice = m
        }
    }
}
