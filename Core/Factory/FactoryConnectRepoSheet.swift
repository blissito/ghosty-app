import SwiftUI

/// «Conectar repo»: dejar lista la fábrica de un repo sin abrir Teams. Como importar un repo en
/// Vercel o Railway: se ESCOGE de la lista de lo que ve tu GitHub App (no se teclea `dueño/repo`),
/// luego el room (uno nuevo con el nombre del repo, o uno que ya existe) y al final qué tan listo
/// quedó para agentes, con el botón para pedir el primer cambio. «¿No ves tu repo?» lleva a darle
/// acceso a la App en GitHub y, al volver, la lista se recarga sola.
struct FactoryConnectRepoSheet: View {
    let slug: String
    /// «Pide el primer cambio»: abre «Nuevo pedido» con este room ya escogido.
    var onRequestRun: (String) -> Void
    /// Se conectó algo: quien abrió la hoja refresca sus rooms.
    var onConnected: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []
    @State private var repos: FactoryRepos?
    @State private var rooms: [FactoryRooms.Room] = []
    @State private var error: String?
    @State private var query = ""
    @State private var opening = false

    enum Step: Hashable {
        case room(FactoryRepos.Repo)
        case done(FactoryConnected)
    }

    var body: some View {
        NavigationStack(path: $path) {
            pick
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .room(let repo):
                        FactoryConnectRoomStep(slug: slug, repo: repo, rooms: rooms, giveAccess: giveAccess) { result in
                            onConnected()
                            path.append(.done(result))
                        }
                    case .done(let result):
                        FactoryConnectedStep(result: result) {
                            onRequestRun(result.room)
                        } close: { dismiss() }
                    }
                }
        }
        .tint(.gInk)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Color.gBg)
        .task { await load() }
    }

    // MARK: - Paso 1: el repo

    private var shown: [FactoryRepos.Repo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = repos?.repos ?? []
        return q.isEmpty ? all : all.filter { $0.repo.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) }
    }

    private var pick: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Conectar repo").font(.system(size: 22, weight: .bold)).foregroundStyle(Color.gInk)
                        Text("Escoge el repo que @plan, @build y @check van a trabajar.").gMeta()
                    }
                    Spacer()
                    Button { dismiss() } label: { TintedIcon(systemName: "xmark", tint: .gInk, background: .gFill, size: 32) }
                        .buttonStyle(.gPressIcon)
                        .accessibilityIdentifier("cerrar-conectar")
                }
                if let error { banner(error) }
                if let repos {
                    if !repos.connected {
                        githubCard(title: "Conecta tu GitHub",
                                   text: "Ghosty necesita ver tus repos para que la fábrica trabaje en ellos. Tú escoges a cuáles.",
                                   action: "Conectar GitHub", id: "conectar-github") { await connectGitHub() }
                    } else if !repos.installed {
                        githubCard(title: "Instala la App de Ghosty",
                                   text: "GitHub ya está conectado. Falta instalar la App en tu cuenta y escoger a qué repos le das acceso.",
                                   action: "Instalar en GitHub", id: "instalar-app") { await giveAccess() }
                    } else {
                        searchField
                        if shown.isEmpty {
                            Text(query.isEmpty ? "La App todavía no ve ningún repo." : "Ningún repo coincide con «\(query)».")
                                .gMeta().frame(maxWidth: .infinity).padding(.vertical, 24)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
                                    repoRow(r)
                                    if i < shown.count - 1 { Divider().padding(.leading, 58) }
                                }
                            }
                            .ghostyCard()
                        }
                        missingRepo
                    }
                } else if error == nil {
                    HStack { Spacer(); GhostySpinner(size: 22); Spacer() }.padding(.top, 50)
                }
            }
            .padding(Theme.Space.screenH)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .background(Color.gBg)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
    }

    /// «hace 4 meses», completo: en una lista de repos «hace 4 m» se lee como minutos.
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.unitsStyle = .full
        return f
    }()

    private static func pushed(_ s: String?) -> String? {
        guard let d = FactoryAPI.date(s) else { return nil }
        return Date().timeIntervalSince(d) < 60 ? "ahora" : relative.localizedString(for: d, relativeTo: Date())
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.gInk3)
            TextField("Buscar repo", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("buscar-repo")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.gInk4) }
                    .buttonStyle(.plain)
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 14).frame(height: 44)
        .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private func repoRow(_ r: FactoryRepos.Repo) -> some View {
        Button {
            // Ya conectado: no se duplica, se va a sus pedidos.
            if let room = r.rooms.first, r.rooms.count == 1, rooms.contains(where: { $0.slug == room && $0.factory }) {
                onRequestRun(room)
            } else {
                path.append(.room(r))
            }
        } label: {
            HStack(spacing: 12) {
                TintedIcon(systemName: r.private ? "lock.fill" : "chevron.left.forwardslash.chevron.right",
                           tint: .gPrimary, background: .gPrimaryTint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk).lineLimit(1)
                    Text([r.owner, r.language, Self.pushed(r.pushedAt)].compactMap { $0 }.joined(separator: " · "))
                        .gCaption().lineLimit(1)
                }
                Spacer(minLength: 6)
                if let room = r.rooms.first {
                    Text("en #\(room)")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.gGreenInk)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Color.gGreenTint, in: Capsule())
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.gInk4)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.gPressRow)
        .accessibilityIdentifier("repo-\(r.name)")
    }

    private var missingRepo: some View {
        Button { Task { await giveAccess() } } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle").font(.system(size: 16, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("¿No ves tu repo?").font(.system(size: 14, weight: .semibold))
                    Text("Dale acceso a Ghosty en GitHub").font(.system(size: 13)).opacity(0.8)
                }
                Spacer()
                if opening { GhostySpinner() } else { Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)) }
            }
            .foregroundStyle(Color.gPrimary)
            .padding(14)
            .background(Color.gPrimaryTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.gPressRow)
        .disabled(opening)
        .accessibilityIdentifier("dar-acceso-github")
    }

    private func githubCard(title: String, text: String, action: String, id: String, run: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("logo-github").resizable().scaledToFit().frame(width: 34, height: 34)
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Color.gInk)
            Text(text).font(.system(size: 14)).foregroundStyle(Color.gInk2).fixedSize(horizontal: false, vertical: true)
            Button { Task { await run() } } label: {
                HStack { if opening { ProgressView().tint(.white) }; Text(action).gButtonLabel() }
                    .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.gDark, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.gPressPrimary)
            .disabled(opening)
            .accessibilityIdentifier(id)
        }
        .padding(18)
        .ghostyCard()
    }

    private func banner(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Color.gDangerInk)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gDangerTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Datos

    private func load() async {
        if DemoData.encendido {
            repos = FactoryStore.demoRepos
            rooms = FactoryStore.demoRooms
            return
        }
        do {
            async let r = FactoryAPI.repos(slug)
            async let l = FactoryAPI.rooms(slug)
            let (rr, ll) = try await (r, l)
            withAnimation(.snappy(duration: 0.25)) { repos = rr; rooms = ll.rooms; error = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Darle a la App acceso a más repos (o instalarla). Al volver, con o sin `…://`, se relee.
    private func giveAccess() async {
        opening = true
        defer { opening = false }
        if !DemoData.encendido, let url = try? await FactoryAPI.githubAccessURL() {
            _ = await WebAuth.open(url)
        }
        await load()
    }

    private func connectGitHub() async {
        opening = true
        defer { opening = false }
        if !DemoData.encendido, let url = try? await FactoryAPI.githubConnectURL() {
            _ = await WebAuth.open(url)
        }
        await load()
    }
}

// MARK: - Paso 2: el room

/// En qué room va el repo: uno nuevo con su nombre (lo normal) o uno que ya existe. «Conectar»
/// tarda varios segundos (GitHub, la caja de CI, la medición): una lista que avanza lo dice.
struct FactoryConnectRoomStep: View {
    let slug: String
    let repo: FactoryRepos.Repo
    let rooms: [FactoryRooms.Room]
    var giveAccess: () async -> Void
    var onDone: (FactoryConnected) -> Void

    @State private var choice: String? = nil  // nil = crear uno nuevo
    @State private var newName = ""
    @State private var isPrivate = false
    @State private var connecting = false
    @State private var stage = 0
    @State private var error: String?
    @State private var notVisible = false

    private static let stages = ["Revisando acceso en GitHub", "Preparando el room", "Preparando la caja de CI", "Midiendo qué tan listo está"]

    /// «Ghosty Studio» → «ghosty-studio».
    static func roomSlug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let dashed = folded.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(dashed).split(separator: "-").joined(separator: "-")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    TintedIcon(systemName: repo.private ? "lock.fill" : "chevron.left.forwardslash.chevron.right",
                               tint: .gPrimary, background: .gPrimaryTint, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.name).font(.system(size: 18, weight: .bold)).foregroundStyle(Color.gInk)
                        Text(repo.owner).gMeta()
                    }
                }
                if connecting { progress } else { form }
            }
            .padding(Theme.Space.screenH)
        }
        .scrollIndicators(.hidden)
        .background(Color.gBg)
        .navigationTitle("¿En qué room?")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(connecting)
        .onAppear { if newName.isEmpty { newName = Self.roomSlug(repo.name) } }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Room").gSectionCaps()
            VStack(spacing: 0) {
                option(selected: choice == nil, id: "room-nuevo") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Crear un room nuevo").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk)
                        if choice == nil {
                            HStack(spacing: 2) {
                                Text("#").foregroundStyle(Color.gInk3)
                                TextField("nombre", text: $newName)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .accessibilityIdentifier("nombre-room")
                            }
                            .font(.system(size: 15, design: .monospaced))
                            .padding(.horizontal, 10).frame(height: 38)
                            .background(Color.gFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Toggle(isOn: $isPrivate) {
                                Text("Privado: sólo tú y a quien agregues").font(.system(size: 13)).foregroundStyle(Color.gInk2)
                            }
                            .tint(.gPrimary)
                        }
                    }
                } tap: { choice = nil }
                ForEach(rooms.filter { !$0.repos.contains(repo.repo) }) { r in
                    Divider().padding(.leading, 44)
                    option(selected: choice == r.slug, id: "room-\(r.slug)") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(r.slug)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk)
                            Text(r.repos.isEmpty ? (r.private ? "Privado · sin repo" : "Sin repo") : r.repos.joined(separator: ", "))
                                .gCaption().lineLimit(1)
                        }
                    } tap: { choice = r.slug }
                }
            }
            .ghostyCard()

            if notVisible {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Ghosty no ve este repo con tu cuenta de GitHub.", systemImage: "eye.slash")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gAmberInk)
                    Button { Task { await giveAccess(); notVisible = false } } label: {
                        Text("Dar acceso en GitHub").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gPrimary)
                    }
                    .accessibilityIdentifier("dar-acceso-repo")
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gAmberTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if let error {
                Text(error).font(.system(size: 14)).foregroundStyle(Color.gDangerInk)
            }

            Button { Task { await connect() } } label: {
                Text(choice == nil ? "Crear #\(Self.roomSlug(newName)) y conectar" : "Conectar a #\(choice!)")
                    .gButtonLabel().foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.gPressPrimary)
            .disabled(choice == nil && Self.roomSlug(newName).isEmpty)
            .accessibilityIdentifier("conectar-repo")
        }
    }

    private func option<Content: View>(selected: Bool, id: String, @ViewBuilder content: () -> Content, tap: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 20)).foregroundStyle(selected ? Color.gPrimary : Color.gInk4)
                .padding(.top, 1)
            content()
            Spacer(minLength: 0)
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { tap() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(.isButton)
    }

    /// La lista que avanza mientras gs y Teams trabajan (una sola llamada; los tiempos son de vista).
    private var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 10) {
                    Group {
                        if i < stage {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.gGreen)
                        } else if i == stage {
                            GhostySpinner(size: 18)
                        } else {
                            Image(systemName: "circle").foregroundStyle(Color.gInk4)
                        }
                    }
                    .font(.system(size: 18)).frame(width: 22)
                    Text(i == 1 && choice == nil ? "Creando #\(Self.roomSlug(newName))" : s)
                        .font(.system(size: 15, weight: i == stage ? .semibold : .regular))
                        .foregroundStyle(i <= stage ? Color.gInk : Color.gInk3)
                }
                .transition(.opacity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostyCard()
        .animation(.snappy(duration: 0.25), value: stage)
        .accessibilityIdentifier("conectando")
    }

    private func connect() async {
        error = nil
        notVisible = false
        withAnimation { connecting = true; stage = 0 }
        let ticker = Task {
            for i in 1..<Self.stages.count {
                try? await Task.sleep(for: .seconds(1.6))
                if Task.isCancelled { return }
                stage = i
            }
        }
        defer { ticker.cancel() }
        let room = choice ?? Self.roomSlug(newName)
        do {
            let r: FactoryConnected
            if DemoData.encendido {
                try await Task.sleep(for: .seconds(2.5))
                if repo.name == FactoryStore.demoHiddenRepo { throw FactoryAPI.Failure(message: "", status: 409) }
                r = FactoryConnected(room: room, created: choice == nil, repo: repo.repo, factoryInstalled: true, ciLabel: "ws-demo",
                                     readiness: .init(level: 1, passed: 5, total: 10, missing: ["agents_md", "ci", "protected", "preview", "prod_env"]))
            } else {
                r = try await FactoryAPI.connect(slug, repo: repo.repo, room: room, create: choice == nil, isPrivate: choice == nil && isPrivate)
            }
            stage = Self.stages.count
            onDone(r)
        } catch let f as FactoryAPI.Failure where f.status == 409 {
            withAnimation { connecting = false; notVisible = true }
        } catch {
            withAnimation { connecting = false; self.error = error.localizedDescription }
        }
    }
}

// MARK: - Paso 3: listo

/// Quedó conectado: qué tan listo está para agentes (nivel y lo que falta) y el siguiente paso.
struct FactoryConnectedStep: View {
    let result: FactoryConnected
    var requestRun: () -> Void
    var close: () -> Void

    static let levelNames = [0: "Por empezar", 1: "Funciona", 2: "Listo para agentes", 3: "Seguro"]

    /// Las frases de `RepoReadiness.tsx` de Teams, para que se lea igual en las dos.
    static let criteria: [String: String] = [
        "readme": "Tiene README",
        "lockfile": "Dependencias fijadas",
        "scripts": "Se puede probar",
        "agents_md": "Reglas para agentes (AGENTS.md)",
        "ci": "Las pruebas corren solas en cada cambio",
        "codeowners": "Una persona revisa los cambios al CI",
        "dependabot": "Dependencias al día",
        "protected": "Nada entra a main sin tu aprobación",
        "preview": "Cada cambio se ve antes del merge",
        "prod_env": "Los despliegues se ven en GitHub",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Color.gGreen)
                        .symbolEffect(.bounce, value: result.repo)
                    Text(result.created ? "Creé #\(result.room) y le conecté \(result.repo)" : "Conecté \(result.repo) a #\(result.room)")
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(Color.gInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("conectado")
                }
                if !result.factoryInstalled {
                    Label("La Software Factory no está instalada en este espacio: el dueño la instala en Teams → /factory.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14)).foregroundStyle(Color.gAmberInk)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gAmberTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if let rd = result.readiness { readiness(rd) }
                VStack(spacing: 10) {
                    Button(action: requestRun) {
                        Text("Pide el primer cambio").gButtonLabel().foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.gPressPrimary)
                    .accessibilityIdentifier("pide-primer-cambio")
                    Button("Listo", action: close)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk2)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(Theme.Space.screenH)
        }
        .scrollIndicators(.hidden)
        .background(Color.gBg)
        .navigationBarBackButtonHidden(true)
        .sensoryFeedback(.success, trigger: result.repo)
    }

    private func readiness(_ rd: FactoryConnected.Readiness) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.gFillStrong, lineWidth: 5)
                    Circle().trim(from: 0, to: CGFloat(rd.level) / 3)
                        .stroke(Color.gPrimary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(rd.level)/3").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.gInk)
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.levelNames[rd.level] ?? "Nivel \(rd.level)").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.gInk)
                    Text("\(rd.passed) de \(rd.total) puntos para que los agentes trabajen solos").gMeta()
                }
            }
            if !rd.missing.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lo que falta").gSectionCaps()
                    ForEach(rd.missing, id: \.self) { k in
                        HStack(spacing: 8) {
                            Image(systemName: "circle.dashed").font(.system(size: 14)).foregroundStyle(Color.gAmber)
                            Text(Self.criteria[k] ?? k).font(.system(size: 14)).foregroundStyle(Color.gInk2)
                        }
                    }
                    Text("@build puede ir llenando estos puntos: pídeselos como cualquier otro cambio.").gCaption()
                }
            }
        }
        .padding(16)
        .ghostyCard()
        .accessibilityIdentifier("nivel-repo")
    }
}
