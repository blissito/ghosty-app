import SwiftUI

/// Un pedido abierto desde la lista: espacio + número.
struct FactoryRoute: Hashable {
    let slug: String
    let id: Int
}

/// La fábrica: los pedidos de tus espacios, lo que te toca primero. Es una PESTAÑA (un área
/// completa no va en una hoja) con su propio `NavigationStack`: lista → pedido por push, con la
/// flecha nativa y el deslizar para regresar. Las hojas quedan sólo para acciones.
struct FactoryHomeView: View {
    /// Abrir directo un pedido al llegar (gancho `GHOSTY_FABRICA=<espacio>/<id>`).
    var openRoute: FactoryRoute?
    /// Hay un pedido abierto: `RootView` esconde la barra (abajo van sus botones).
    @Binding var inRun: Bool

    @State private var store = FactoryStore.shared
    @State private var selected: String?
    @State private var path: [FactoryRoute] = []
    @State private var sheet: HomeSheet?

    /// Las dos hojas de la cabecera. «Pide el primer cambio» pasa de una a la otra con el room escogido.
    enum HomeSheet: Identifiable {
        case newRun(room: String?)
        case connect
        var id: String {
            switch self {
            case .newRun(let room): "run-\(room ?? "")"
            case .connect: "connect"
            }
        }
    }

    private var space: FactorySpace? {
        store.spaces.first { $0.slug == selected } ?? store.spaces.first
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    content.padding(.top, 18)
                }
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refresh() }
            .background(Color.gBg.ignoresSafeArea())
            // La raíz pinta su propia cabecera (espacio + pedido nuevo); el pedido sí trae la barra
            // nativa con su flecha y el deslizar para regresar.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: FactoryRoute.self) { r in
                FactoryRunView(slug: r.slug, id: r.id)
            }
        }
        .tint(.gInk)
        .onChange(of: path) { _, p in withAnimation(.easeOut(duration: 0.2)) { inRun = !p.isEmpty } }
        // Abrir un pedido pedido desde fuera (Actividad): su espacio y su detalle por push.
        .onChange(of: store.pendingRoute, initial: true) { _, route in
            guard let route else { return }
            selected = route.slug
            path = [route]
            store.pendingRoute = nil
        }
        .task {
            await store.refresh(force: !store.loaded)
            if let openRoute, path.isEmpty {
                selected = openRoute.slug
                path = [openRoute]
            }
        }
        // Mientras un agente trabaja, la lista se pone al día sola cada 10 s.
        .task(id: store.anyWorking) {
            guard store.anyWorking else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, path.isEmpty, let slug = space?.slug else { continue }
                await store.refresh(space: slug)
            }
        }
        .sheet(item: $sheet) { which in
            if let space {
                switch which {
                case .newRun(let room):
                    FactoryNewRunSheet(space: space, initialRoom: room, onConnectRepo: { swap(to: .connect) }) { _ in
                        Task { await store.refresh(space: space.slug) }
                    }
                case .connect:
                    FactoryConnectRepoSheet(slug: space.slug) { room in
                        swap(to: .newRun(room: room))
                    }
                }
            }
        }
    }

    /// Cambiar de hoja: se cierra la abierta y, ya abajo, sube la otra.
    private func swap(to next: HomeSheet) {
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            sheet = next
        }
    }

    /// «Pedido» es lo de diario (un toque); el menú del «⋯» de al lado conecta un repo nuevo.
    private var newRunButton: some View {
        HStack(spacing: 6) {
            Menu {
                Button { sheet = .connect } label: { Label("Conectar repo", systemImage: "link.badge.plus") }
                    .accessibilityIdentifier("menu-conectar-repo")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Color.gInk)
                    .frame(width: 36, height: 36)
                    .background(Color.gFill, in: Circle())
            }
            .disabled(space == nil)
            .accessibilityIdentifier("fabrica-mas")
            runButton
        }
    }

    private var runButton: some View {
        Button { sheet = .newRun(room: nil) } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                Text("Pedido").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 36)
            .background(Color.gPrimary, in: Capsule())
            .ghostyPrimaryShadow()
        }
        .buttonStyle(.gPressPill)
        .disabled(space == nil)
        .accessibilityIdentifier("fabrica-nuevo")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                spaceSwitcher
                Spacer()
                newRunButton
            }
            .padding(.bottom, 14)
            Text("Fábrica").gScreenTitle()
            Text("Lo que tus agentes construyen en tus repos. Firmas el plan, ellos hacen el resto.")
                .gScreenSubtitle()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    /// El espacio, arriba a la izquierda como en Slack: su inicial en un cuadro de marca y el
    /// nombre. Con varios espacios es un menú nativo (con lo que te toca en cada uno), no una hoja.
    @ViewBuilder
    private var spaceSwitcher: some View {
        let label = HStack(spacing: 8) {
            Text(String((space?.slug ?? "·").prefix(1)).uppercased())
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(space?.slug ?? "Fábrica").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.gInk)
            if store.spaces.count > 1 {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.gInk3)
            }
        }
        .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 4)
        .background(Color.gFill, in: Capsule())
        if store.spaces.count > 1 {
            Menu {
                ForEach(store.spaces) { s in
                    let pending = s.runs.filter(\.stage.needsYou).count
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { selected = s.slug }
                    } label: {
                        if s.slug == space?.slug { Label(s.slug, systemImage: "checkmark") }
                        else { Text(pending > 0 ? "\(s.slug) · \(pending) te toca" : s.slug) }
                    }
                }
            } label: { label }
            .accessibilityIdentifier("fabrica-espacio")
        } else {
            label.accessibilityIdentifier("fabrica-espacio")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let space {
            let mine = space.runs.filter(\.stage.needsYou)
            let working = space.runs.filter(\.stage.working)
            let rest = space.runs.filter { !$0.stage.needsYou && !$0.stage.working }
            if space.runs.isEmpty {
                firstRepo
            } else {
            VStack(alignment: .leading, spacing: 22) {
                summary(space)
                if !mine.isEmpty { section("Te toca", mine, accent: .gAmberInk) }
                if !working.isEmpty { section("Trabajando", working, accent: .gPrimaryPressed) }
                if !rest.isEmpty { section("Recientes", rest, accent: .gInk3) }
            }
            .id(space.slug)
            .transition(.opacity)
            }
        } else if !store.loaded || store.loading {
            HStack { Spacer(); GhostySpinner(size: 22); Spacer() }.padding(.top, 60)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "shippingbox").font(.system(size: 34)).foregroundStyle(Color.gInk4)
                Text(store.error ?? "Ninguno de tus espacios tiene pedidos en la fábrica todavía.")
                    .gMeta().multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
        }
    }

    /// Un espacio sin pedidos: lo primero es conectar un repo.
    private var firstRepo: some View {
        VStack(alignment: .leading, spacing: 12) {
            TintedIcon(systemName: "link.badge.plus", tint: .gPrimary, background: .gPrimaryTint, size: 44)
            Text("Conecta tu primer repo").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.gInk)
            Text("Escoge un repo de tu GitHub y la fábrica lo deja listo: @plan propone, tú firmas y @build lo hace.")
                .font(.system(size: 15)).foregroundStyle(Color.gInk2).fixedSize(horizontal: false, vertical: true)
            Button { sheet = .connect } label: {
                Text("Conectar repo").gButtonLabel().foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.gPressPrimary)
            .accessibilityIdentifier("conectar-primer-repo")
        }
        .padding(18)
        .ghostyCard()
    }

    /// Tres cifras arriba: te toca, trabajando, terminados.
    private func summary(_ s: FactorySpace) -> some View {
        let mine = s.runs.filter(\.stage.needsYou).count
        let working = s.runs.filter(\.stage.working).count
        let done = s.runs.filter { $0.stage == .done }.count
        let usd = s.runs.compactMap(\.usd).reduce(0, +)
        return HStack(spacing: 8) {
            stat("\(mine)", "te toca", mine > 0 ? .gAmberInk : .gInk)
            stat("\(working)", "trabajando", working > 0 ? .gPrimaryPressed : .gInk)
            stat("\(done)", "terminados", .gInk)
            if usd > 0 { stat(String(format: "$%.0f", usd), "USD", .gInk) }
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .heavy).monospacedDigit()).foregroundStyle(color)
                .contentTransition(.numericText())
            Text(label).gCaption().lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(Color.gFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func section(_ title: String, _ runs: [FactoryRun], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).gSectionCaps().foregroundStyle(accent)
                Text("\(runs.count)").gSectionCaps()
            }
            ForEach(Array(runs.enumerated()), id: \.element.id) { i, run in
                NavigationLink(value: FactoryRoute(slug: space?.slug ?? "", id: run.id)) {
                    FactoryRunRow(run: run)
                }
                .buttonStyle(.gPressRow)
                .accessibilityIdentifier("pedido-\(run.id)")
                .gIn(delay: min(Double(i) * 0.04, 0.3))
            }
        }
    }
}
