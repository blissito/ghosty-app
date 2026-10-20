import SwiftUI

/// Un sprint: lo que propone @plan cuando el objetivo no cabe en un pedido. En Teams es una tarjeta;
/// aquí es una lista nativa: deslizar quita o regresa un ticket, tocarlo abre su cuerpo (editable
/// en borrador), y abajo una sola barra «Crear sprint · N tickets» que firma todos a la vez. Ya en
/// marcha, cada ticket enseña quién lo tiene y lleva a su pedido.
struct FactorySprintView: View {
    let slug: String
    let sprintId: Int
    @Binding var path: [FactoryRoute]

    @State private var sprint: FactorySprint?
    @State private var error: String?
    @State private var busy = false
    @State private var open: FactorySprint.Item?
    @State private var confirming = false
    @State private var asking = false
    @State private var launched = 0

    var body: some View {
        Group {
            if let sprint {
                list(sprint)
            } else if let error {
                Text(error).gMeta().padding()
            } else {
                GhostySpinner(size: 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gBg.ignoresSafeArea())
        .navigationTitle("Sprint")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { if let sprint, sprint.isDraft, sprint.canEdit { approveBar(sprint) } }
        .sheet(item: $open) { it in
            if let sprint {
                FactoryTicketSheet(item: it, sprint: sprint, act: act) { runId in
                    open = nil
                    path.append(FactoryRoute(slug: slug, id: runId))
                }
            }
        }
        .sheet(isPresented: $confirming) {
            if let sprint {
                FactoryConfirmSheet(title: "¿Crear el sprint?",
                                    message: "Los \(sprint.included.count) tickets quedan firmados de una vez. Arrancan uno a la vez, en orden; @check revisa cada PR y tú haces el merge de cada uno.",
                                    action: "Crear sprint", identifier: "confirmar-sprint") {
                    Task { await act(.approve); launched += 1 }
                }
            }
        }
        .sheet(isPresented: $asking) {
            FactoryChangesSheet { note in Task { await act(.changes(note: note)) } }
        }
        .sensoryFeedback(.success, trigger: launched)
        .overlay { if launched > 0 { ConfettiBurst().allowsHitTesting(false).id(launched) } }
        .task { await poll() }
    }

    private func list(_ s: FactorySprint) -> some View {
        List {
            Section {
                header(s)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            }
            if let c = s.change, c.pending {
                Section {
                    Label("@plan está rehaciendo el sprint con tu nota: «\(c.note)»", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14)).foregroundStyle(Color.gAmberInk)
                        .listRowBackground(Color.gAmberTint)
                }
            }
            Section {
                ForEach(s.items) { it in
                    row(it, s)
                        .contentShape(Rectangle())
                        .onTapGesture { open = it }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if s.canEdit, s.isDraft || !it.included {
                                Button { Task { await act(.edit(itemId: it.id, included: !it.included)) } } label: {
                                    Label(it.included ? "Quitar" : "Incluir", systemImage: it.included ? "minus.circle" : "plus.circle")
                                }
                                .tint(it.included ? .gDangerInk : .gGreen)
                            }
                        }
                        .accessibilityIdentifier("ticket-\(it.key)")
                }
            } header: {
                Text(s.isDraft ? "Tickets · desliza para quitar" : "Tickets").gSectionCaps()
            } footer: {
                if s.isDraft { Text("Tócalo para leerlo o cambiarlo. Uno que depende de otro arranca cuando ése tenga merge.").gCaption() }
            }
            if let error {
                Section { Text(error).font(.system(size: 13)).foregroundStyle(Color.gDangerInk) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
        .animation(.snappy(duration: 0.25), value: s)
    }

    private func header(_ s: FactorySprint) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.isDraft ? "Propuesto por @plan · v\(s.version)" : s.status == "done" ? "Terminado" : "En marcha")
                    .gSectionCaps().foregroundStyle(s.isDraft ? Color.gAmberInk : Color.gPrimaryPressed)
                Text(s.title).font(.system(size: 22, weight: .heavy)).foregroundStyle(Color.gInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sprint-titulo")
                if !s.goal.isEmpty { Text(s.goal).font(.system(size: 15)).foregroundStyle(Color.gInk2).fixedSize(horizontal: false, vertical: true) }
                if let repo = s.repo { Label(repo, systemImage: "chevron.left.forwardslash.chevron.right").gCaption() }
            }
            Spacer(minLength: 0)
            if !s.isDraft { ring(s) }
        }
        .padding(.horizontal, 4)
    }

    private func ring(_ s: FactorySprint) -> some View {
        let total = max(1, s.included.count)
        return ZStack {
            Circle().stroke(Color.gFillStrong, lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(s.merged) / CGFloat(total))
                .stroke(Color.gGreen, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(s.merged)/\(s.included.count)").font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(Color.gInk)
        }
        .frame(width: 56, height: 56)
        .accessibilityIdentifier("sprint-avance")
    }

    private func row(_ it: FactorySprint.Item, _ s: FactorySprint) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(it.key).font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(it.included ? Color.gPrimaryPressed : Color.gInk4)
                .frame(width: 34, height: 34)
                .background(it.included ? Color.gPrimaryTint : Color.gFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(it.title).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(it.included ? Color.gInk : Color.gInk4)
                    .strikethrough(!it.included, color: .gInk4)
                HStack(spacing: 6) {
                    FactorySizePill(size: it.size)
                    if !it.dependsOn.isEmpty { Text("después de \(it.dependsOn.joined(separator: ", "))").gCaption() }
                    if !it.included { Text("fuera").gCaption() }
                }
            }
            Spacer(minLength: 4)
            if !s.isDraft, it.included { stage(it) }
        }
        .padding(.vertical, 4)
    }

    private func stage(_ it: FactorySprint.Item) -> some View {
        let (text, ink, bg): (String, Color, Color) = switch (it.status, it.stage) {
        case ("merged", _): ("Merge", .gGreenInk, .gGreenTint)
        case ("skipped", _): ("Saltado", .gInk3, .gFill)
        case ("failed", _): ("Falló", .gDangerInk, .gDangerTint)
        case (_, "you_review"): ("Te toca", .gAmberInk, .gAmberTint)
        case (_, "you_decide"): ("Decide", .gAmberInk, .gAmberTint)
        case (_, "box_wait"): ("En espera", .gInk3, .gFill)
        case (_, let r?): (r, .gPrimaryPressed, .gPrimaryTint)
        default: ("Pendiente", .gInk3, .gFill)
        }
        return Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(ink)
            .padding(.horizontal, 8).frame(height: 22)
            .background(bg, in: Capsule())
    }

    private func approveBar(_ s: FactorySprint) -> some View {
        HStack(spacing: 10) {
            Button { asking = true } label: {
                Text("Pedir cambios").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk)
                    .padding(.horizontal, 16).frame(minHeight: 50)
                    .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.gPressPrimary)
            .accessibilityIdentifier("sprint-cambios")
            Button { confirming = true } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().tint(.white) }
                    Text("Crear sprint · \(s.included.count)").gButtonLabel().contentTransition(.numericText())
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.gPressPrimary)
            .disabled(busy || s.included.isEmpty || s.change?.pending == true)
            .accessibilityIdentifier("crear-sprint")
        }
        .padding(.horizontal, Theme.Space.screenH).padding(.vertical, 8)
        .background(Color.gBg)
    }

    // MARK: - Datos

    private func load() async {
        if DemoData.encendido { sprint = FactoryStore.demoSprint; return }
        do {
            let s = try await FactoryAPI.sprint(slug, sprintId)
            FactoryStore.shared.noteSprint(s, slug: slug)
            withAnimation(.snappy) { sprint = s; error = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// En borrador o en marcha la lista cambia sola (@plan rehace, un ticket avanza): cada 15 s.
    private func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private func act(_ a: FactoryAPI.SprintAction) async {
        busy = true
        defer { busy = false }
        do {
            let s = DemoData.encendido ? FactoryStore.demoSprintAct(a) : try await FactoryAPI.sprintAct(slug, sprintId, a)
            FactoryStore.shared.noteSprint(s, slug: slug)
            withAnimation(.snappy) { sprint = s; error = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct FactorySizePill: View {
    let size: String
    var body: some View {
        let (ink, bg): (Color, Color) = size == "L" ? (.gAmberInk, .gAmberTint) : size == "M" ? (.gPrimaryPressed, .gPrimaryTint) : (.gGreenInk, .gGreenTint)
        Text(size).font(.system(size: 11, weight: .heavy)).foregroundStyle(ink)
            .frame(minWidth: 20).frame(height: 20).padding(.horizontal, 4)
            .background(bg, in: Capsule())
    }
}

/// Un ticket del sprint: su cuerpo (lo que lee @build), editable en borrador por quien puede.
struct FactoryTicketSheet: View {
    let item: FactorySprint.Item
    let sprint: FactorySprint
    var act: (FactoryAPI.SprintAction) async -> Void
    var openRun: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var title = ""
    @State private var body_ = ""

    private var editable: Bool { sprint.isDraft && sprint.canEdit }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text(item.key).font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(Color.gPrimaryPressed)
                        FactorySizePill(size: item.size)
                        if !item.dependsOn.isEmpty { Text("después de \(item.dependsOn.joined(separator: ", "))").gCaption() }
                    }
                    if editing {
                        TextField("Título", text: $title, axis: .vertical)
                            .font(.system(size: 20, weight: .bold))
                            .padding(10).background(Color.gFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityIdentifier("ticket-titulo")
                        TextEditor(text: $body_)
                            .font(.system(size: 15, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8).frame(minHeight: 300)
                            .background(Color.gFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityIdentifier("ticket-cuerpo")
                    } else {
                        Text(item.title).font(.system(size: 22, weight: .heavy)).foregroundStyle(Color.gInk)
                        GhostyMarkdown(markdown: item.bodyMd)
                    }
                    actions
                }
                .padding(Theme.Space.screenH)
            }
            .background(Color.gBg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editing ? "Cancelar" : "Cerrar") { if editing { editing = false } else { dismiss() } }
                }
                if editable {
                    ToolbarItem(placement: .confirmationAction) {
                        if editing {
                            Button("Guardar") {
                                Task {
                                    await act(.edit(itemId: item.id, title: title == item.title ? nil : title, bodyMd: body_ == item.bodyMd ? nil : body_))
                                    dismiss()
                                }
                            }
                            .accessibilityIdentifier("guardar-ticket")
                        } else {
                            Button("Editar") { title = item.title; body_ = item.bodyMd; editing = true }
                                .accessibilityIdentifier("editar-ticket")
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Color.gBg)
    }

    @ViewBuilder
    private var actions: some View {
        if !editing {
            VStack(spacing: 10) {
                if let run = item.runId {
                    wide("Ver pedido #\(run)", "arrow.right", .gPrimary, .white) { openRun(run) }
                }
                if item.status == "failed", sprint.canEdit {
                    wide("Reintentar", "arrow.clockwise", .gPrimary, .white) { Task { await act(.item(itemId: item.id, op: "retry")); dismiss() } }
                    wide("Saltarlo", "forward", .gFill, .gInk) { Task { await act(.item(itemId: item.id, op: "skip")); dismiss() } }
                }
                if sprint.canEdit, sprint.isDraft || !item.included {
                    wide(item.included ? "Quitar del sprint" : "Incluir en el sprint", item.included ? "minus.circle" : "plus.circle", .gFill, item.included ? .gDangerInk : .gGreenInk) {
                        Task { await act(.edit(itemId: item.id, included: !item.included)); dismiss() }
                    }
                }
                if sprint.canEdit, item.issueNumber == nil, item.runId == nil {
                    wide("Dejarlo como issue de GitHub", "tray.and.arrow.down", .gFill, .gInk) { Task { await act(.issue(itemId: item.id)); dismiss() } }
                }
            }
            .padding(.top, 8)
        }
    }

    private func wide(_ text: String, _ icon: String, _ bg: Color, _ fg: Color, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(text, systemImage: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(fg)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(bg, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.gPressPrimary)
    }
}

/// «Pedir cambios» al sprint: la nota despierta a @plan, que entrega otra versión.
struct FactoryChangesSheet: View {
    var send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("¿Qué le cambio?").font(.system(size: 22, weight: .heavy)).foregroundStyle(Color.gInk)
            Text("@plan rehace el sprint con tu nota y respeta lo que editaste a mano.").gMeta()
            TextEditor(text: $note)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(10).frame(minHeight: 140)
                .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .accessibilityIdentifier("nota-sprint")
            Button { send(note.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() } label: {
                Text("Mandar a @plan").gButtonLabel().foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.gPressPrimary)
            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.screenH)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Color.gBg)
    }
}
