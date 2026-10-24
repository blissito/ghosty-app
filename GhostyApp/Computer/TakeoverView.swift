import LiveKit
import SwiftUI
import UIKit

/// La computadora del agente a pantalla completa: la pestaña de su navegador llega como video de la
/// sala de LiveKit de esa sesión y, con un pase de `takeover`, tus toques y lo que escribes van a la
/// página por el canal de datos (`TakeoverProtocol`). «Devolver el control» despierta al agente que
/// esperaba en `cloud_browser_ask_human`, en el mismo turno.
///
/// - Tocar = mouse down + up en ese punto. Arrastrar = rueda. Pellizcar = zoom SÓLO del video (nunca
///   va a la página); las coordenadas se convierten con `TakeoverGeometry`.
/// - Lo que escribes va por un campo nativo (dictado, acentos, autocorrector, llavero con
///   «Contraseña»); Enter, Retroceso y Tab van como teclas sueltas.
/// - Sin `livekit` en el pase, o si no conecta en 5 s, se dice claro. ⚠️ El respaldo SSE (`liveUrl`
///   = JPEG por SSE + `inputUrl`) que usa la web todavía NO está en el teléfono.
struct TakeoverView: View {
    let presentation: AgentComputerStore.Presentation
    let onClose: () -> Void

    @State private var session: TakeoverSession
    @State private var texto = ""
    @State private var esContrasena = false
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var anchor = CGPoint(x: 0.5, y: 0.5)
    @State private var pinching = false
    @State private var lastDragY: CGFloat?
    @State private var copiado = false
    @FocusState private var enfocado: Bool

    init(presentation: AgentComputerStore.Presentation, onClose: @escaping () -> Void) {
        self.presentation = presentation
        self.onClose = onClose
        _session = State(initialValue: TakeoverSession(live: presentation.live, mode: presentation.mode))
    }

    private var takeover: Bool { presentation.mode == .takeover }

    var body: some View {
        VStack(spacing: 0) {
            header
            pantalla
            if takeover, case .live = session.state { entrada }
            pie
        }
        .background(Color.gDark.ignoresSafeArea())
        .task { await session.start() }
        .onDisappear { session.disconnect() }
        .onChange(of: session.state) { _, s in
            if case .released = s { onClose() }
        }
    }

    // MARK: cabecera

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(takeover ? "Tienes el control" : "Su computadora en vivo")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if let ask = presentation.live.needsHuman {
                    Text(ask).font(.system(size: 13)).foregroundStyle(Color.gDarkInk2).lineLimit(3)
                } else if let t = presentation.live.title, !t.isEmpty {
                    Text(t).font(.system(size: 13)).foregroundStyle(Color.gDarkInk2).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if zoom > 1.01 {
                Button {
                    withAnimation(.snappy) { zoom = 1; zoomBase = 1 }
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Quitar el zoom")
            }
            // La X también devuelve el control en una toma (como Atrás en Android): irse sin
            // devolverlo dejaba al agente esperando hasta que venciera la toma.
            do {
                Button { if takeover { Task { await session.release() } } else { onClose() } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Cerrar")
                .accessibilityIdentifier("cerrar-computadora")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: el video

    private var pantalla: some View {
        GeometryReader { geo in
            let g = geometry(container: geo.size)
            let r = g.videoRect
            ZStack {
                if case .live(let track) = session.state {
                    SwiftUIVideoView(track, layoutMode: .fit)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .scaleEffect(zoom, anchor: UnitPoint(x: anchor.x, y: anchor.y))
                } else {
                    estado.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(pinch(container: geo.size))
            .simultaneousGesture(scroll(geometry: g))
            .simultaneousGesture(tap(geometry: g))
        }
        .accessibilityIdentifier("computadora-video")
    }

    private func geometry(container: CGSize) -> TakeoverGeometry {
        TakeoverGeometry(viewport: session.viewport, container: container, zoom: zoom, anchor: anchor)
    }

    private func tap(geometry g: TakeoverGeometry) -> some Gesture {
        SpatialTapGesture().onEnded { v in
            guard takeover, let p = g.toPage(v.location) else { return }
            enfocado = false
            let x = Int(p.x), y = Int(p.y)
            session.send(.mouse(.down, x: x, y: y, clickCount: 1))
            session.send(.mouse(.up, x: x, y: y, clickCount: 1))
        }
    }

    private func scroll(geometry g: TakeoverGeometry) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard takeover, !pinching else { lastDragY = nil; return }
                let prev = lastDragY ?? v.startLocation.y
                lastDragY = v.location.y
                let dy = g.scrollDelta(forDrag: v.location.y - prev)
                if dy != 0 { session.send(.scroll(dy: dy)) }
            }
            .onEnded { _ in lastDragY = nil }
    }

    private func pinch(container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if !pinching {
                    pinching = true
                    // El ancla se fija al empezar: donde pusiste los dedos es lo que se acerca.
                    if zoomBase <= 1.01 { anchor = CGPoint(x: v.startAnchor.x, y: v.startAnchor.y) }
                }
                zoom = min(4, max(1, zoomBase * v.magnification))
            }
            .onEnded { _ in
                pinching = false
                zoomBase = zoom
                if zoom <= 1.01 { zoom = 1; zoomBase = 1 }
            }
    }

    @ViewBuilder private var estado: some View {
        VStack(spacing: 12) {
            switch session.state {
            case .loading, .connecting:
                ProgressView().tint(.white)
                Text("Conectando con la computadora de tu agente…")
            case .noLiveKit:
                Image(systemName: "video.slash").font(.system(size: 28))
                Text("Esta computadora todavía no transmite en vivo al teléfono.")
                Text("Ábrela desde ghosty.studio en la compu para tomar el control.").foregroundStyle(Color.gDarkInk2)
            case .failed(let m):
                Image(systemName: "wifi.exclamationmark").font(.system(size: 28))
                Text(m)
                Button("Reintentar") { Task { await session.start() } }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .accessibilityIdentifier("reintentar-computadora")
            case .gone(let m):
                Image(systemName: "checkmark.circle").font(.system(size: 28))
                Text(m)
            case .live, .released:
                EmptyView()
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(24)
    }

    // MARK: escribir

    private var entrada: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Group {
                    if esContrasena {
                        SecureField("Contraseña", text: $texto)
                            .textContentType(.password)
                    } else {
                        TextField("Escribe en la página", text: $texto)
                            .textContentType(nil)
                    }
                }
                .focused($enfocado)
                .submitLabel(.send)
                .onSubmit(enviarTexto)
                .font(.system(size: 16))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(Color.gInk)
                .accessibilityIdentifier("computadora-texto")
                Button(action: enviarTexto) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(texto.isEmpty ? Color.white.opacity(0.14) : Color.gPrimary, in: Circle())
                }
                .accessibilityLabel(texto.isEmpty ? "Enter" : "Escribir en la página")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tecla("Enter", icono: "return", key: "Enter")
                    tecla("Borrar", icono: "delete.left", key: "Backspace")
                    tecla("Tab", icono: "arrow.right.to.line", key: "Tab")
                    chip("Contraseña", icono: esContrasena ? "lock.fill" : "lock.open",
                         activo: esContrasena) { esContrasena.toggle(); texto = "" }
                        .accessibilityIdentifier("computadora-contrasena")
                    chip(copiado ? "Copiado" : "Copiar selección", icono: "doc.on.doc", activo: copiado) {
                        Task {
                            if let t = await session.copy(), !t.isEmpty {
                                UIPasteboard.general.string = t
                                copiado = true
                                try? await Task.sleep(for: .seconds(1.5))
                                copiado = false
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    /// Con el campo vacío, «enviar» es Enter (como Android): llenar un campo y mandarlo es un toque.
    private func enviarTexto() {
        guard !texto.isEmpty else { session.send(.key("Enter")); return }
        session.typeText(texto)
        texto = ""
    }

    private func tecla(_ nombre: String, icono: String, key: String) -> some View {
        chip(nombre, icono: icono, activo: false) { session.send(.key(key)) }
    }

    private func chip(_ nombre: String, icono: String, activo: Bool, _ accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            Label(nombre, systemImage: icono)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(activo ? Color.gInk : .white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(activo ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: pie

    @ViewBuilder private var pie: some View {
        if takeover {
            Button {
                Task { await session.release() }
            } label: {
                HStack {
                    if session.releasing { ProgressView().tint(.white) }
                    Text("Devolver el control")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(session.releasing)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            .accessibilityIdentifier("devolver-el-control")
        } else {
            Spacer().frame(height: 12)
        }
    }
}

/// La sala de LiveKit de la sesión del navegador: el video del publicador y, en una toma, la entrada
/// en orden por el canal confiable.
@MainActor @Observable
final class TakeoverSession {
    enum State: Equatable {
        case loading, connecting
        case live(VideoTrack)
        /// El pase no trae `livekit` (caja sin los puertos de WebRTC): no hay respaldo en el teléfono.
        case noLiveKit
        case failed(String)
        /// La toma ya no existe: el agente cerró el navegador o se acabó el tiempo.
        case gone(String)
        case released

        static func == (a: State, b: State) -> Bool {
            switch (a, b) {
            case (.loading, .loading), (.connecting, .connecting), (.noLiveKit, .noLiveKit), (.released, .released): true
            case let (.live(x), .live(y)): x === y
            case let (.failed(x), .failed(y)), let (.gone(x), .gone(y)): x == y
            default: false
            }
        }
    }

    let live: BrowserLive
    let mode: AgentComputerStore.Mode
    private(set) var state: State = .loading
    private(set) var releasing = false
    private(set) var viewport: CGSize
    /// Sin viewport en el paso ni en el pase, se toma el tamaño del video al llegar.
    @ObservationIgnored private var viewportKnown: Bool

    @ObservationIgnored private var pass: BrowserPass?
    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var events: RoomEvents?
    @ObservationIgnored private var pending: [HumanInput] = []
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var timers: [Task<Void, Never>] = []

    init(live: BrowserLive, mode: AgentComputerStore.Mode) {
        self.live = live
        self.mode = mode
        viewport = live.viewport ?? CGSize(width: 1280, height: 800)
        viewportKnown = live.viewport != nil
    }

    /// Pide el pase (si no lo hay) y entra a la sala. Reintentar vuelve a pasar por aquí.
    func start() async {
        disconnect()
        state = .loading
        // El modo demo no toca la red: se ve la pantalla sin transmisión.
        if DemoData.encendido { state = .noLiveKit; return }
        do {
            if pass == nil || mode == .watch {
                pass = try await AgentComputerAPI.pass(mode == .takeover ? .takeover : .watch,
                                                       agentID: live.agentID, browserSessionID: live.browserSessionID)
            }
        } catch AgentComputerAPI.Failure.gone {
            state = .gone("Tu agente ya cerró ese navegador.")
            return
        } catch {
            state = .failed((error as? AgentComputerAPI.Failure).flatMap {
                if case .message(let m) = $0 { m } else { nil }
            } ?? "No pude pedir la computadora.")
            return
        }
        guard let pass else { return }
        if let vp = pass.viewport { viewport = vp; viewportKnown = true }
        guard let lk = pass.livekit else { state = .noLiveKit; return }
        state = .connecting

        let room = Room()
        let events = RoomEvents { [weak self] track in
            Task { @MainActor in self?.attach(track) }
        } onLost: { [weak self] in
            Task { @MainActor in self?.lost() }
        }
        room.add(delegate: events)
        self.room = room
        self.events = events

        // Como la web: si en 5 s no hay video, se dice (no se queda «conectando» para siempre).
        timers.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.state == .connecting else { return }
            self.state = .failed("No pude conectar en vivo con la computadora de tu agente.")
            self.disconnectRoom()
        })
        // La toma vence (10 min en la caja): al vencer ya no hay nada que manejar.
        if mode == .takeover, let ms = pass.expiresInMs, ms > 0 {
            timers.append(Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(ms))
                guard let self, !Task.isCancelled else { return }
                self.state = .gone("Se acabó el tiempo de la toma. Tu agente ya puede seguir.")
                self.disconnectRoom()
            })
        }

        do {
            try await room.connect(url: lk.wsUrl, token: lk.token,
                                   roomOptions: RoomOptions(adaptiveStream: false, dynacast: false))
        } catch {
            if state == .connecting { state = .failed("No pude conectar en vivo con la computadora de tu agente.") }
            return
        }
        // Si la pista ya estaba suscrita al conectar, el delegado no vuelve a avisar.
        if let p = room.remoteParticipants[Participant.Identity(from: TakeoverProtocol.publisherIdentity)],
           let t = p.videoTracks.compactMap({ $0.track as? VideoTrack }).first {
            attach(t)
        }
    }

    private func attach(_ track: VideoTrack) {
        guard state == .connecting || { if case .live = state { true } else { false } }() else { return }
        state = .live(track)
        if !viewportKnown, let d = track.dimensions, d.width > 0, d.height > 0 {
            viewport = CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
        }
        guard mode == .takeover, let pass else { return }
        // Con LiveKit la entrada no pasa por gs: un latido por el camino HTTP mantiene despiertas la
        // caja y la toma, y avisa si ya no existe (igual que la web).
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                if await !AgentComputerAPI.heartbeat(pass) {
                    self?.state = .gone("Tu agente ya cerró ese navegador.")
                    self?.disconnectRoom()
                    return
                }
            }
        })
    }

    private func lost() {
        if case .live = state { state = .failed("Se cortó la transmisión.") }
        else if state == .connecting { state = .failed("No pude conectar en vivo con la computadora de tu agente.") }
    }

    // MARK: entrada

    /// En orden y, mientras un envío va en camino, compactando (`HumanInput.enqueue`).
    func send(_ ev: HumanInput) {
        guard mode == .takeover, case .live = state, let ev = ev.normalized else { return }
        pending = HumanInput.enqueue(pending, ev)
        pump()
    }

    /// El texto en trozos de `Limits.text` (lo que pase de ahí, la caja lo cortaría).
    func typeText(_ s: String) {
        var chunk = ""
        for ch in s {
            if chunk.utf16.count + ch.utf16.count > TakeoverProtocol.Limits.text { send(.type(chunk)); chunk = "" }
            chunk.append(ch)
        }
        if !chunk.isEmpty { send(.type(chunk)) }
    }

    private func pump() {
        guard !pumping else { return }
        pumping = true
        Task { [weak self] in
            while let self, !self.pending.isEmpty, let room = self.room {
                let ev = self.pending.removeFirst()
                try? await room.localParticipant.publish(
                    data: ev.encoded(),
                    options: DataPublishOptions(topic: TakeoverProtocol.inputTopic, reliable: true))
            }
            self?.pumping = false
        }
    }

    /// Lo seleccionado en la página (RPC `gc.copy` → `{text}`).
    func copy() async -> String? {
        guard let room, case .live = state else { return nil }
        guard let out = try? await room.localParticipant.performRpc(
            destinationIdentity: Participant.Identity(from: TakeoverProtocol.publisherIdentity),
            method: TakeoverProtocol.rpcCopy, payload: "", responseTimeout: 8, maxRoundTripLatency: 4) else { return nil }
        let j = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
        return j?["text"] as? String
    }

    /// «Devolver el control»: el RPC a la caja y el POST a gs a la vez. El POST es el que despierta al
    /// agente, así que va aunque no haya sala (sin LiveKit, al fallar, al vencer).
    func release() async {
        guard !releasing else { return }
        releasing = true
        let room = self.room
        async let rpc: Void = {
            guard let room, room.connectionState == .connected else { return }
            _ = try? await room.localParticipant.performRpc(
                destinationIdentity: Participant.Identity(from: TakeoverProtocol.publisherIdentity),
                method: TakeoverProtocol.rpcRelease, payload: "", responseTimeout: 3, maxRoundTripLatency: 2)
        }()
        if let pass { await AgentComputerAPI.release(pass) }
        await rpc
        disconnect()
        releasing = false
        state = .released
    }

    func disconnect() {
        timers.forEach { $0.cancel() }
        timers = []
        disconnectRoom()
    }

    private func disconnectRoom() {
        pending = []
        if let room { Task { await room.disconnect() } }
        room = nil
        events = nil
    }
}

/// El delegado de la sala: sólo cuenta el video del publicador (`agent-browser`).
private final class RoomEvents: NSObject, RoomDelegate, @unchecked Sendable {
    let onTrack: @Sendable (VideoTrack) -> Void
    let onLost: @Sendable () -> Void

    init(onTrack: @escaping @Sendable (VideoTrack) -> Void, onLost: @escaping @Sendable () -> Void) {
        self.onTrack = onTrack
        self.onLost = onLost
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard participant.identity?.stringValue == TakeoverProtocol.publisherIdentity,
              let t = publication.track as? VideoTrack else { return }
        onTrack(t)
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) { onLost() }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        if participant.identity?.stringValue == TakeoverProtocol.publisherIdentity { onLost() }
    }
}
