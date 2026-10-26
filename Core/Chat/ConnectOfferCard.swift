import SwiftUI
import UIKit

/// «Conecta tu GitHub» dentro del hilo: lo que pinta la marca ` ```gs_connect <id>``` ` (ver
/// `ConnectOffers`). El agente ya le dio acceso a ESTE agente; aquí sólo falta que la persona
/// conecte su cuenta.
///
/// Espejo de la tarjeta de /c (`ghosty-studio/app/components/chat/ConnectOfferCard.tsx`) y del
/// camino de Integraciones: aviso previo si el catálogo trae `intro`, y si no `…/:id/start` en
/// la hoja del navegador. Una de llave (`credential`) abre Integraciones. Mientras espera revisa
/// sola (al volver a la app y cada 3 s, hasta 5 min) y al quedar conectada le avisa al agente
/// UNA vez para que siga (sólo si `onConnected` viene: la última respuesta).
struct ConnectOfferCard: View {
    let connectorID: String
    let store: LiveAgentStore
    /// Le dice al agente que ya quedó. `nil` = esta respuesta ya no es la última.
    var onConnected: ((String) -> Void)? = nil
    /// Abre Integraciones (conectores de llave).
    var openIntegrations: () -> Void = {}

    private enum Phase: Equatable { case loading, idle, starting, waiting, connected, already, error, gone }

    @State private var phase: Phase = .loading
    @State private var item: Conector?
    @State private var failure: String?
    @State private var showIntro = false
    @State private var pendingStart = false
    @State private var waitingSince = Date()
    @State private var told = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private static let pollEvery: Duration = .seconds(3)
    private static let pollFor: TimeInterval = 5 * 60

    private var name: String { item?.nombre ?? connectorID }
    private var brand: Color { item?.brandHex.map { Color(hex: $0) } ?? Color(hex: 0x181717) }
    private var ok: Bool { phase == .connected || phase == .already }

    var body: some View {
        if phase != .gone {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .frame(maxWidth: 380, alignment: .leading)
            .background(Color.gCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.gSeparator, lineWidth: 1))
            .accessibilityIdentifier("connect-offer-\(connectorID)")
            .task { await load(initial: true) }
            .task(id: phase == .waiting) { await poll() }
            .onChange(of: scenePhase) { _, p in
                if p == .active, phase == .waiting { Task { await recheck() } }
            }
            .sheet(isPresented: $showIntro, onDismiss: {
                // Se conecta al CERRARSE la intro: presentar el navegador mientras la hoja se va falla.
                if pendingStart { pendingStart = false; start(seenIntro: true) }
            }) {
                if let intro = item?.intro {
                    IntroConectorSheet(intro: intro) { pendingStart = true; showIntro = false }
                }
            }
        }
    }

    /// Franja de marca: el color del proveedor, como su propio botón de «Sign in».
    private var header: some View {
        HStack(spacing: 10) {
            logo
            VStack(alignment: .leading, spacing: 1) {
                Text(ok ? "\(name) conectado" : "Conecta tu \(name)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Tu agente lo usa en cuanto conectes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if ok {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.gGreen, in: Circle())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(brand)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: ok)
    }

    /// El PNG del servidor, la marca empaquetada o el símbolo, en cuadro blanco.
    @ViewBuilder
    private var logo: some View {
        let box = { (v: AnyView) in
            v.frame(width: 22, height: 22)
                .frame(width: 34, height: 34)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        if let url = item?.logoPngURL {
            AsyncImage(url: url) { f in
                if let img = f.image { box(AnyView(img.resizable().interpolation(.high).scaledToFit())) }
                else { box(AnyView(localLogo)) }
            }
        } else {
            box(AnyView(localLogo))
        }
    }

    @ViewBuilder
    private var localLogo: some View {
        if let marca = item?.marca {
            Image(marca, bundle: GhostyAssets.bundle).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: item?.icono ?? "puzzlepiece.extension.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: 0x5E5D6B))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            RoundedRectangle(cornerRadius: 4).fill(Color.gSeparator).frame(width: 180, height: 12)
        case .idle, .starting:
            if let d = item?.descripcion, !d.isEmpty {
                Text(d).font(.system(size: 14)).foregroundStyle(Color.gInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { start() } label: {
                HStack(spacing: 8) {
                    if phase == .starting { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "arrow.up.right.square").font(.system(size: 14, weight: .semibold)) }
                    Text("Conectar \(name)")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(brand, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.gPressPill)
            .disabled(phase == .starting)
            .accessibilityIdentifier("connect-offer-start-\(connectorID)")
        case .waiting:
            HStack(spacing: 8) {
                GhostySpinner()
                Text("Termina en \(name); aquí lo veo solo.")
                    .font(.system(size: 14)).foregroundStyle(Color.gInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                smallButton("Abrir otra vez") { start(seenIntro: true) }
                smallButton("Ya lo conecté", icon: "arrow.clockwise") {
                    Task {
                        await recheck()
                        if phase == .waiting { failure = "Todavía no aparece conectado." }
                    }
                }
            }
        case .connected, .already:
            HStack(spacing: 8) {
                Text(phase == .connected && told ? "Listo: ya le avisé a tu agente." : "Ya está conectado.")
                    .font(.system(size: 14)).foregroundStyle(Color.gInk2)
                if phase == .connected, !told, onConnected != nil {
                    Button("Seguir") { finish() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Color.gDark, in: Capsule())
                        .buttonStyle(.gPressPill)
                }
                Spacer(minLength: 0)
                if let m = item?.manage, let u = m.url {
                    Button { openURL(u) } label: {
                        HStack(spacing: 3) {
                            Text(m.label)
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Color.gInk3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("connect-offer-manage-\(connectorID)")
                }
            }
        case .error:
            Button { Task { await load(initial: true) } } label: {
                Label("No pude cargar la tarjeta. Reintentar", systemImage: "arrow.clockwise")
                    .font(.system(size: 14)).foregroundStyle(Color.gInk3)
            }
            .buttonStyle(.plain)
        case .gone:
            EmptyView()
        }
        if let failure {
            Text(failure).font(.system(size: 12)).foregroundStyle(Color.gDangerInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func smallButton(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title)
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.gInk)
            .padding(.horizontal, 12).frame(height: 30)
            .overlay(Capsule().strokeBorder(Color.gSeparator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.gPressPill)
    }

    // MARK: - Datos

    /// El renglón del conector en `GET /me/connectors` (vía el store, para que Integraciones
    /// quede al día también). `nil` = no se pudo leer.
    private func fetch() async -> Conector?? {
        await store.cargarConectores()
        guard store.hayConectores || DemoData.encendido else {
            return store.falloDeConectores == nil ? .some(nil) : nil
        }
        return .some(store.conectores.first { $0.id == connectorID })
    }

    private func load(initial: Bool) async {
        guard let found = await fetch() else { phase = .error; return }
        item = found
        guard let c = found, c.disponible else { phase = .gone; return }
        if initial || phase == .error { phase = c.conectado ? .already : .idle }
    }

    /// Revisa si ya quedó; mientras espera, sin ruido si falla.
    private func recheck() async {
        guard let found = await fetch(), let c = found else { return }
        item = c
        if c.conectado, phase == .waiting || phase == .idle || phase == .starting {
            failure = nil
            finish()
        } else if phase == .waiting, Date().timeIntervalSince(waitingSince) > Self.pollFor {
            phase = .idle
        }
    }

    private func poll() async {
        guard phase == .waiting else { return }
        while !Task.isCancelled, phase == .waiting {
            try? await Task.sleep(for: Self.pollEvery)
            guard !Task.isCancelled, phase == .waiting else { return }
            await recheck()
        }
    }

    /// Quedó conectada en esta visita: se le avisa al agente una sola vez para que siga.
    private func finish() {
        phase = .connected
        guard !told, let onConnected else { return }
        told = true
        onConnected("Listo, ya conecté \(name). Sigue con lo que ibas.")
    }

    private func start(seenIntro: Bool = false) {
        guard let c = item else { return }
        if c.intro != nil, !seenIntro { failure = nil; showIntro = true; return }
        // De llave: el formulario vive en Integraciones; al volver, la tarjeta revisa sola.
        if c.kind == "credential" {
            waitingSince = Date()
            phase = .waiting
            openIntegrations()
            return
        }
        failure = nil
        phase = .starting
        Task {
            guard let url = await store.urlDeConexion(c.id) else {
                failure = "No pude iniciar la conexión."
                phase = .idle
                return
            }
            waitingSince = Date()
            phase = .waiting
            let back = await WebAuth.open(url)
            if let back, Self.query(back, "estado") == "ok" {
                await recheck()
                // gs ya dijo que quedó: aunque la lista tarde, se da por hecho.
                if phase == .waiting { finish() }
                return
            }
            if let back, let d = Self.query(back, "estado") == "error" ? Self.query(back, "detalle") : nil, d != "cancelado" {
                failure = "No se pudo conectar \(name): \(d)."
            }
            // Cerró la hoja o salió por otro lado: se sigue esperando (revisa sola) hasta 5 min.
            await recheck()
        }
    }

    private static func query(_ url: URL, _ key: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
    }
}
