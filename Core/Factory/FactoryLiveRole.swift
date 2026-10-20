import SwiftUI

/// Un rol trabajando en el pedido, en vivo. Antes era sólo «@build está construyendo… 1:58» y no
/// decía si leía, probaba o estaba colgado (#115, 19-oct). Ahora va como las tareas en segundo plano
/// de Codex, Cursor o Devin: lo que hace AHORA con su ícono y lo que lleva, los últimos pasos ya
/// hechos, «Ver todo» con la línea de tiempo completa y el atasco dentro de la misma tarjeta.
/// Sin `live` (caja de gs vieja, o todavía no llega) se ve sólo el encabezado con el reloj.
struct FactoryLiveRole: View {
    let role: String?
    let since: String
    let live: FactoryLive.Role?

    @State private var drawer = false

    /// Pasos ya cerrados que se ven en la tarjeta; el resto vive en «Ver todo».
    private static let visibles = 3

    private var run: ToolRun? { live.map(\.toolRun) }
    private var open: FactoryLive.Step? { live?.steps.last { $0.status == "running" } }
    private var finished: [FactoryLive.Step] { (live?.steps ?? []).filter { $0.status != "running" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let stall = live?.stalled { stallStrip(stall) }
            if let open { nowLine(open) } else if let now = live?.now { nowLine(text: now) }
            if !finished.isEmpty { recent }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gPrimaryTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeOut(duration: 0.3), value: live)
        .sheet(isPresented: $drawer) {
            if let run {
                DrawerDePasos(run: run)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.gBg)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            GhostySpinner(size: 16)
            Text(FactoryFormat.working(role)).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gInk)
            Spacer()
            if let d = FactoryAPI.date(since) {
                Text(d, style: .timer).gMono(size: 12).foregroundStyle(Color.gInk3)
            }
        }
    }

    /// Lo que hace ahora: el paso abierto, con el ícono de su clase y lo que lleva. Respira mientras corre.
    private func nowLine(_ s: FactoryLive.Step) -> some View {
        let clase = Herramienta.Clase(s.kind)
        return HStack(spacing: 10) {
            TintedIcon(systemName: clase.icono, tint: clase.tinte.fg, background: Color.gCard, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gInk)
                if let d = s.detail { Text(d).gMono(size: 12).foregroundStyle(Color.gInk2).lineLimit(1).truncationMode(.middle) }
            }
            .phaseAnimator([1.0, 0.55]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 1.1) }
            Spacer(minLength: 0)
            if let secs = s.secs { Text(FactoryFormat.secs(secs)).gMono(size: 12).foregroundStyle(Color.gInk3) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paso-ahora")
    }

    /// Sin pasos a la mano, la línea del latido («Corriendo un comando»).
    private func nowLine(text: String) -> some View {
        HStack(spacing: 10) {
            GhostyDots(color: .gPrimary, size: 5)
            Text(text).font(.system(size: 13)).foregroundStyle(Color.gInk2).lineLimit(1)
        }
        .accessibilityIdentifier("paso-ahora")
    }

    /// Los últimos pasos hechos y «Ver todo».
    private var recent: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(finished.suffix(Self.visibles), id: \.id) { s in
                HStack(spacing: 6) {
                    if let h = run?.herramientas.first(where: { $0.id == s.id }) { FilaDePaso(h: h) }
                    Spacer(minLength: 0)
                    if let secs = s.secs { Text(FactoryFormat.secs(secs)).gMono(size: 11).foregroundStyle(Color.gInk4) }
                }
            }
            Button { drawer = true } label: {
                HStack(spacing: 4) {
                    Text("Ver todo · \(live?.steps.count ?? 0) pasos")
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.gPrimary)
            }
            .buttonStyle(.gPressRow)
            .padding(.top, 2)
            .accessibilityIdentifier("ver-todos-los-pasos")
        }
        .padding(.leading, 2)
    }

    /// El atasco, dentro de la tarjeta: no hay que bajar a la bitácora para enterarse.
    private func stallStrip(_ s: FactoryLive.Stall) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hourglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.gAmber)
            Text(LocalizedStringKey("Se atoró: " + s.human))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.gAmberInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.gAmberTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("atasco")
    }
}

/// Lo que mandaste al firmar, debajo de «Firmaste tú»: la nota para @build y lo único que revisa
/// @check. Plegado a 3 líneas; tocarlo lo abre.
struct FactoryDecisionNote: View {
    let note: String?
    let scope: String?
    @State private var expanded = false

    var body: some View {
        if note?.isEmpty == false || scope?.isEmpty == false {
            Button { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } } label: {
                VStack(alignment: .leading, spacing: 6) {
                    if let note, !note.isEmpty {
                        Text(LocalizedStringKey(note)).font(.system(size: 13)).foregroundStyle(Color.gInk2)
                            .lineLimit(expanded ? nil : 3).multilineTextAlignment(.leading)
                    }
                    if let scope, !scope.isEmpty {
                        (Text("@check revisa sólo: ").bold() + Text(LocalizedStringKey(scope)))
                            .font(.system(size: 12.5)).foregroundStyle(Color.gInk3)
                            .lineLimit(expanded ? nil : 2).multilineTextAlignment(.leading)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.gPressRow)
            .padding(.top, 4)
            .accessibilityIdentifier("nota-firmada")
        }
    }
}
