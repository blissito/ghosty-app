import CoreGraphics
import Foundation
import Observation

/// «La computadora del agente» en el teléfono: el navegador de la caja que el agente usa en un turno
/// (`cloud_browser_*` de gs). Aquí vive lo que no depende de LiveKit —el pase, el pedido de ayuda,
/// la geometría del toque— para que lo compartan Personal y Work. La pantalla con el video está en
/// `GhostyApp/Computer/TakeoverView.swift`.

/// Lo que dijo el último `ghosty.browser` de una conversación: qué navegador, de qué tamaño y si el
/// agente pidió ayuda (`cloud_browser_ask_human` → `needsHuman`).
struct BrowserLive: Equatable, Identifiable, Sendable {
    let agentID: String
    /// La conversación (el `threadId` del turno).
    let conversationID: String
    /// La sesión del NAVEGADOR en la caja (no la conversación): es lo que piden los pases.
    let browserSessionID: String
    var viewport: CGSize?
    var url: String?
    var title: String?
    /// El texto del pedido de ayuda («Paga tú»); `nil` = el agente sólo está navegando.
    var needsHuman: String?

    var id: String { "\(agentID)/\(conversationID)/\(browserSessionID)" }

    /// `value` de un CUSTOM `ghosty.browser` (el `PartnerTurnFrame` de gs sin la imagen).
    init?(agentID: String, conversationID: String, frame v: [String: Any]) {
        guard let s = v["sessionId"] as? String, !s.isEmpty else { return nil }
        self.agentID = agentID
        self.conversationID = conversationID
        browserSessionID = s
        if let vp = v["viewport"] as? [String: Any],
           let w = (vp["width"] as? NSNumber)?.doubleValue, let h = (vp["height"] as? NSNumber)?.doubleValue, w > 0, h > 0 {
            viewport = CGSize(width: w, height: h)
        }
        url = v["url"] as? String
        title = v["title"] as? String
        needsHuman = (v["needsHuman"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    init(agentID: String, conversationID: String, browserSessionID: String, needsHuman: String?, viewport: CGSize? = nil) {
        self.agentID = agentID
        self.conversationID = conversationID
        self.browserSessionID = browserSessionID
        self.needsHuman = needsHuman
        self.viewport = viewport
    }
}

/// Lo que gs da al pedir un pase (`cloud-browser-pass.server.ts`).
struct BrowserPass: Sendable {
    struct LiveKit: Sendable, Equatable { let wsUrl: String; let token: String }
    let liveUrl: URL?
    /// Sólo en `takeover`: el camino HTTP de la entrada (latido y respaldo) y el de «Devolver».
    let inputUrl: URL?
    let releaseUrl: URL?
    let viewport: CGSize?
    let expiresInMs: Int?
    let livekit: LiveKit?

    init(_ j: [String: Any]) {
        liveUrl = (j["liveUrl"] as? String).flatMap(URL.init(string:))
        inputUrl = (j["inputUrl"] as? String).flatMap(URL.init(string:))
        releaseUrl = (j["releaseUrl"] as? String).flatMap(URL.init(string:))
        if let vp = j["viewport"] as? [String: Any],
           let w = (vp["width"] as? NSNumber)?.doubleValue, let h = (vp["height"] as? NSNumber)?.doubleValue, w > 0, h > 0 {
            viewport = CGSize(width: w, height: h)
        } else { viewport = nil }
        expiresInMs = (j["expiresInMs"] as? NSNumber)?.intValue
        if let lk = j["livekit"] as? [String: Any], let u = lk["wsUrl"] as? String, let t = lk["token"] as? String, !u.isEmpty, !t.isEmpty {
            livekit = LiveKit(wsUrl: u, token: t)
        } else { livekit = nil }
    }
}

/// Los pases de gs: `POST /api/v2/me/agents/:agentId/browser/(watch|takeover) {sessionId}` con la
/// sesión de la app. Las URLs que regresan llevan el pase firmado: se llaman sin bearer.
enum AgentComputerAPI {
    enum Op: String, Sendable { case watch, takeover }

    enum Failure: Error, Equatable {
        /// 410: el agente ya no usa ese navegador (terminó el turno o lo cerró).
        case gone
        case message(String)
    }

    static func pass(_ op: Op, agentID: String, browserSessionID: String) async throws -> BrowserPass {
        let url = Session.base.appendingPathComponent("api/v2/me/agents/\(agentID)/browser/\(op.rawValue)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.assumesHTTP3Capable = false
        req.setValue("Bearer \(try await Session.accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["sessionId": browserSessionID])
        let datos: Data, resp: URLResponse
        do { (datos, resp) = try await URLSession.shared.data(for: req) }
        catch { throw Failure.message("Sin conexión. Inténtalo de nuevo.") }
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any] ?? [:]
        if codigo == 410 { throw Failure.gone }
        guard (200..<300).contains(codigo) else {
            throw Failure.message((j["error"] as? String) ?? "El servidor contestó \(codigo).")
        }
        return BrowserPass(j)
    }

    /// «Devolver el control»: es ESTE POST el que despierta al agente que esperaba en
    /// `cloud_browser_ask_human` (gs `releaseHandoff`), así que se manda aunque el RPC ya haya ido.
    static func release(_ pass: BrowserPass) async {
        guard let u = pass.releaseUrl else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        _ = try? await URLSession.shared.data(for: req)
    }

    /// El latido por el camino HTTP mientras la entrada va por LiveKit: mantiene viva la caja y la
    /// toma (gs cuenta su uso por aquí). `false` = la toma ya no existe (404/410).
    static func heartbeat(_ pass: BrowserPass) async -> Bool {
        guard let u = pass.inputUrl else { return true }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"type":"ping"}"#.utf8)
        req.timeoutInterval = 15
        guard let (_, r) = try? await URLSession.shared.data(for: req) else { return true }
        let c = (r as? HTTPURLResponse)?.statusCode ?? 0
        return c != 404 && c != 410
    }
}

/// Dónde está cada navegador vivo y qué pantalla de la computadora hay que abrir. Una para toda la
/// app: lo llenan los streams del chat (`ClienteGS.alVerNavegador`) y el toque de un push.
@MainActor @Observable
final class AgentComputerStore {
    static let shared = AgentComputerStore()

    enum Mode: String, Sendable { case watch, takeover }

    /// Lo que pide abrir la pantalla de la computadora (la presenta `RootView`).
    struct Presentation: Identifiable, Equatable {
        let live: BrowserLive
        let mode: Mode
        var id: String { "\(live.id)/\(mode.rawValue)" }
    }

    /// El último navegador por conversación (`agente/conversación`).
    private(set) var live: [String: BrowserLive] = [:]
    var presenting: Presentation?

    private init() {
        ClienteGS.alVerNavegador = { agent, conversation, frame in
            nonisolated(unsafe) let frame = frame
            Task { @MainActor in AgentComputerStore.shared.apply(agent: agent, conversation: conversation, frame: frame) }
        }
        ClienteGS.alTerminarRun = { agent, conversation in
            Task { @MainActor in AgentComputerStore.shared.clear(agent: agent, conversation: conversation) }
        }
    }

    /// Se llama al arrancar para que los callbacks queden puestos antes del primer stream.
    static func install() { _ = shared }

    private static func key(_ a: String, _ c: String) -> String { "\(a)/\(c)" }

    func current(agent: String, conversation: String?) -> BrowserLive? {
        guard let conversation else { return nil }
        return live[Self.key(agent, conversation)]
    }

    func apply(agent: String, conversation: String, frame: [String: Any]) {
        guard let b = BrowserLive(agentID: agent, conversationID: conversation, frame: frame) else { return }
        live[Self.key(agent, conversation)] = b
    }

    /// El run terminó: ya no hay navegador que mirar ni ayuda que dar.
    func clear(agent: String, conversation: String) {
        live[Self.key(agent, conversation)] = nil
    }

    func open(_ b: BrowserLive, mode: Mode) {
        presenting = Presentation(live: b, mode: mode)
    }

    /// Un push de «te necesito» (ver `Avisos`): se abre la toma aunque el stream todavía no llegue.
    func openFromPush(agent: String, conversation: String, browserSessionID: String, text: String?) {
        let b = BrowserLive(agentID: agent, conversationID: conversation, browserSessionID: browserSessionID,
                            needsHuman: text, viewport: live[Self.key(agent, conversation)]?.viewport)
        live[Self.key(agent, conversation)] = b
        open(b, mode: .takeover)
    }
}

/// De la pantalla del teléfono a px del viewport de la página: el video va ajustado (aspect fit) al
/// contenedor y encima puede llevar zoom LOCAL (pellizcar), que nunca se manda a la página.
struct TakeoverGeometry: Equatable {
    var viewport: CGSize
    var container: CGSize
    var zoom: CGFloat = 1
    /// El ancla del zoom en el contenedor (0…1), donde empezó el pellizco.
    var anchor = CGPoint(x: 0.5, y: 0.5)

    /// El rectángulo del video sin zoom.
    var videoRect: CGRect {
        guard viewport.width > 0, viewport.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let k = min(container.width / viewport.width, container.height / viewport.height)
        let size = CGSize(width: viewport.width * k, height: viewport.height * k)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Un punto del contenedor en px de la página, o `nil` si cae fuera del video.
    func toPage(_ p: CGPoint) -> CGPoint? {
        let r = videoRect
        guard r.width > 0 else { return nil }
        let a = CGPoint(x: anchor.x * container.width, y: anchor.y * container.height)
        let z = max(zoom, 0.0001)
        let q = CGPoint(x: a.x + (p.x - a.x) / z, y: a.y + (p.y - a.y) / z)
        guard r.contains(q) else { return nil }
        return CGPoint(x: ((q.x - r.minX) / r.width * viewport.width).rounded(),
                       y: ((q.y - r.minY) / r.height * viewport.height).rounded())
    }

    /// Arrastrar el dedo `dy` pt (positivo = hacia abajo) es rueda en sentido contrario, a la escala
    /// de la página: el contenido sigue al dedo, como en cualquier pantalla táctil.
    func scrollDelta(forDrag dy: CGFloat) -> Int {
        let r = videoRect
        guard r.height > 0 else { return 0 }
        return Int((-dy * viewport.height / r.height / max(zoom, 0.0001)).rounded())
    }
}
