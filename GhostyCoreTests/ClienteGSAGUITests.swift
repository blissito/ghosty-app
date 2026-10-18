import XCTest
@testable import GhostyCore

/// Un servidor AG-UI de mentiras: contesta cada `POST` con el siguiente flujo grabado y guarda lo
/// que le mandaron, para comprobar el `RunAgentInput` (resume, cancel, threadId…).
final class StubAGUI: URLProtocol {
    nonisolated(unsafe) static var respuestas: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var recibidos: [[String: Any]] = []
    static let lock = NSLock()

    static func preparar(_ r: [(Int, String)]) {
        lock.lock(); defer { lock.unlock() }
        respuestas = r.map { (status: $0.0, body: $0.1) }
        recibidos = []
    }

    static var cuerpos: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return recibidos }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            s.close()
        }
        Self.lock.lock()
        Self.recibidos.append((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        let r = Self.respuestas.isEmpty ? (status: 500, body: "") : Self.respuestas.removeFirst()
        Self.lock.unlock()
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": r.status == 200 ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(r.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Recoge lo que el cliente avisa por sus ganchos.
actor Senales {
    var permisos: [ACPClient.Permiso] = []
    var resueltos: [String] = []
    var fases: [String] = []
    func permiso(_ p: ACPClient.Permiso) { permisos.append(p) }
    func resuelto(_ id: String) { resueltos.append(id) }
    func fase(_ f: String) { fases.append(f) }
}

final class ClienteGSAGUITests: XCTestCase {
    var cliente: ClienteGS!
    let senales = Senales()

    override func setUp() async throws {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubAGUI.self]
        AGUITransport.defaultSession = URLSession(configuration: c)
        ClienteGS.autorizar = { req, _ in req.setValue("Bearer prueba", forHTTPHeaderField: "Authorization") }
        cliente = ClienteGS(agentID: "agente")
        let s = senales
        await cliente.alPedirPermiso { p in Task { await s.permiso(p) } }
        await cliente.alResolverPermiso { id in Task { await s.resuelto(id) } }
        await cliente.alCambiarEstado { _, f in Task { await s.fase(f) } }
    }

    /// Lee del flujo hasta que pasa `hasta` o se cierra; devuelve lo leído y si se cerró.
    func leer(_ flujo: AsyncThrowingStream<ACPClient.Replay, Error>, hasta: Double = 2) async -> (eventos: [ACPClient.Replay], cerrado: Bool, error: Error?) {
        let box = Caja()
        let t = Task {
            do {
                for try await r in flujo { await box.add(r) }
                await box.cerrar(nil)
            } catch { await box.cerrar(error) }
        }
        try? await Task.sleep(for: .seconds(hasta))
        t.cancel()
        return (await box.eventos, await box.cerrado, await box.error)
    }

    actor Caja {
        var eventos: [ACPClient.Replay] = []
        var cerrado = false
        var error: Error?
        func add(_ r: ACPClient.Replay) { eventos.append(r) }
        func cerrar(_ e: Error?) { cerrado = true; error = e }
    }

    func texto(_ ev: [ACPClient.Replay]) -> String {
        ev.compactMap { if case .agent(let t) = $0 { return t } else { return nil } }.joined()
    }

    func testTurnWithApprovalContinuesInSameStream() async throws {
        StubAGUI.preparar([(200, Fixture.text("agui-turn-interrupt")), (200, Fixture.text("agui-resume-approved"))])
        let flujo = cliente.prompt(sessionID: "th1", texto: "¿Por qué falló el monitor?", adjuntos: [], turnId: "turno-1")
        let box = Caja()
        let lector = Task { do { for try await r in flujo { await box.add(r) }; await box.cerrar(nil) } catch { await box.cerrar(error) } }
        try await Task.sleep(for: .seconds(1))

        // El POST lleva el mensaje nuevo y el turnId como runId.
        let primero = StubAGUI.cuerpos[0]
        XCTAssertEqual(primero["threadId"] as? String, "th1")
        XCTAssertEqual(primero["runId"] as? String, "turno-1")
        XCTAssertEqual((primero["messages"] as? [[String: Any]])?.first?["content"] as? String, "¿Por qué falló el monitor?")

        // Se detuvo en la tarjeta: el flujo NO cerró y hay un permiso.
        let antes = await box.eventos
        if case .turno(let id) = antes.first { XCTAssertEqual(id, "turno-1") } else { XCTFail("sin .turno") }
        XCTAssertTrue(texto(antes).hasPrefix("Reviso tus crons."))
        let cerradoAntes = await box.cerrado
        XCTAssertFalse(cerradoAntes)
        let permisos = await senales.permisos
        XCTAssertEqual(permisos.map(\.id), ["7e7350617e69e236575c0974266608fc"])
        XCTAssertEqual(permisos.first?.titulo, "Correr ahora purge-notifications")
        let fasesAntes = await senales.fases
        XCTAssertFalse(fasesAntes.contains("reposo"), "esperando aprobación no es reposo")

        // Aprobar: sale el resume y su stream sigue en la MISMA burbuja.
        try await cliente.responderPermiso(permisos[0].id, opcion: permisos[0].opciones.first { $0.tipo.hasPrefix("allow") }!.id)
        try await Task.sleep(for: .seconds(1))
        let resume = StubAGUI.cuerpos[1]
        XCTAssertEqual((resume["messages"] as? [Any])?.count, 0)
        let r = (resume["resume"] as? [[String: Any]])?.first
        XCTAssertEqual(r?["interruptId"] as? String, permisos[0].id)
        XCTAssertEqual(r?["status"] as? String, "resolved")
        XCTAssertEqual((r?["payload"] as? [String: Any])?["approved"] as? Bool, true)
        let resueltos = await senales.resueltos
        XCTAssertEqual(resueltos, [permisos[0].id])
        let despues = await box.eventos
        let turnos = despues.compactMap { if case .turno(let id) = $0 { return id } else { return nil } }
        XCTAssertEqual(Set(turnos), ["turno-1"])
        XCTAssertGreaterThan(texto(despues).count, texto(antes).count)
        let cerrado = await box.cerrado
        XCTAssertTrue(cerrado)
        lector.cancel()
    }

    func testReconnectToPausedThreadAsksOnce() async throws {
        StubAGUI.preparar([(200, Fixture.text("agui-open-paused")), (200, Fixture.text("agui-open-paused"))])
        _ = await leer(cliente.seguir(sessionID: "th2")!, hasta: 0.8)
        _ = await leer(cliente.seguir(sessionID: "th2")!, hasta: 0.8)
        let permisos = await senales.permisos
        XCTAssertEqual(permisos.count, 1, "reconectar no repite la tarjeta")
        // La reconexión no manda mensaje.
        XCTAssertEqual((StubAGUI.cuerpos[0]["messages"] as? [Any])?.count, 0)
    }

    func testAnsweredElsewhereRetiresCard() async throws {
        StubAGUI.preparar([(200, Fixture.text("agui-open-paused")), (200, Fixture.text("agui-open-done"))])
        _ = await leer(cliente.seguir(sessionID: "th3")!, hasta: 0.8)
        _ = await leer(cliente.seguir(sessionID: "th3")!, hasta: 0.8)
        let resueltos = await senales.resueltos
        XCTAssertEqual(resueltos, ["7e7350617e69e236575c0974266608fc"])
    }

    func testIdleReconnectStaysOpenWithoutWork() async throws {
        StubAGUI.preparar([(200, Fixture.text("agui-open-done"))])
        let r = await leer(cliente.seguir(sessionID: "th4")!, hasta: 0.8)
        XCTAssertFalse(r.cerrado, "el vigilante se queda escuchando")
        XCTAssertTrue(texto(r.eventos).isEmpty, "el snapshot es historia, no trabajo en vivo")
    }

    func testStopSendsCancelWithLiveRun() async throws {
        StubAGUI.preparar([(200, Fixture.text("agui-turn-interrupt")), (200, Fixture.text("agui-cancel"))])
        _ = await leer(cliente.prompt(sessionID: "th5", texto: "hola", adjuntos: [], turnId: "turno-5"), hasta: 0.8)
        await cliente.cancelar("th5")
        let c = StubAGUI.cuerpos[1]
        XCTAssertEqual((c["forwardedProps"] as? [String: Any])?["cancel"] as? String, "turno-5")
        // Con una tarjeta abierta basta el cancel: gs la rechaza.
        XCTAssertNil(c["resume"])
    }

    func testSendOverLiveRunWithoutSteerStopsItAndRetries() async throws {
        StubAGUI.preparar([(409, #"{"error":"run_active","message":"no"}"#), (200, Fixture.text("agui-cancel")),
                           (200, Fixture.text("agui-open-done"))])
        let r = await leer(cliente.prompt(sessionID: "th11", texto: "otra cosa", adjuntos: [], turnId: "turno-11"), hasta: 1)
        XCTAssertNil(r.error)
        XCTAssertEqual(StubAGUI.cuerpos.count, 3)
        XCTAssertNotNil((StubAGUI.cuerpos[1]["forwardedProps"] as? [String: Any])?["cancel"])
        XCTAssertEqual(StubAGUI.cuerpos[2]["runId"] as? String, "turno-11")
    }

    func testRunErrorAndPaymentRequired() async throws {
        StubAGUI.preparar([(402, #"{"error":"limit","message":"Se acabó tu saldo."}"#)])
        let r = await leer(cliente.prompt(sessionID: "th6", texto: "hola", adjuntos: [], turnId: "turno-6"), hasta: 0.8)
        guard case ACPClient.Fallo.limit(let m)? = r.error as? ACPClient.Fallo else { return XCTFail("\(String(describing: r.error))") }
        XCTAssertEqual(m, "Se acabó tu saldo.")
    }

    func testNewMessageCancelsOpenCards() async throws {
        StubAGUI.preparar([(200, Fixture.text("agui-open-paused")), (200, Fixture.text("agui-open-done"))])
        _ = await leer(cliente.seguir(sessionID: "th7")!, hasta: 0.8)
        _ = await leer(cliente.prompt(sessionID: "th7", texto: "mejor otra cosa", adjuntos: [], turnId: "turno-7"), hasta: 0.8)
        let r = (StubAGUI.cuerpos[1]["resume"] as? [[String: Any]])?.first
        XCTAssertEqual(r?["status"] as? String, "cancelled")
    }
}

/// Lo propio de gs («gs-agui 1», `agui-adopcion.md` §0) en un stream armado a mano.
extension ClienteGSAGUITests {
    static func sse(_ events: [[String: Any]]) -> String {
        events.map { "data: " + String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! + "\n\n" }.joined()
    }

    func testGsCustomsReachTheThread() async throws {
        let caps = Caps()
        await cliente.alConocerCapacidades { s in Task { await caps.set(s) } }
        StubAGUI.preparar([(200, Self.sse([
            ["type": "RUN_STARTED", "threadId": "th8", "runId": "turno-8", "timestamp": 1],
            ["type": "STATE_SNAPSHOT", "snapshot": ["caps": ["steer": true, "image": true]]],
            ["type": "STEP_STARTED", "stepName": "waking"],
            ["type": "STEP_FINISHED", "stepName": "waking"],
            ["type": "TOOL_CALL_START", "toolCallId": "tc1", "toolCallName": "Read"],
            ["type": "CUSTOM", "name": "ghosty.tool", "value": ["toolCallId": "tc1", "title": "Leyendo notas.md", "kind": "read", "detail": "notas.md"]],
            ["type": "TOOL_CALL_END", "toolCallId": "tc1"],
            ["type": "TOOL_CALL_RESULT", "toolCallId": "tc1", "messageId": "m", "content": "ok"],
            ["type": "TEXT_MESSAGE_START", "messageId": "turno-8:a0", "role": "assistant"],
            ["type": "TEXT_MESSAGE_CONTENT", "messageId": "turno-8:a0", "delta": "Listo."],
            ["type": "TEXT_MESSAGE_END", "messageId": "turno-8:a0"],
            ["type": "CUSTOM", "name": "ghosty.delivery", "value": ["id": "d1", "messageId": "turno-8:a0", "tipo": "archivo", "nombre": "reporte.pdf",
                                                                      "fileId": "f9", "mime": "application/pdf", "size": 1234, "url": "https://x.test/f9"]],
            ["type": "RUN_FINISHED", "threadId": "th8", "runId": "turno-8", "outcome": ["type": "success"],
             "usage": [["model": "m", "inputTokens": 10, "outputTokens": 5]]],
        ]))])
        let r = await leer(cliente.prompt(sessionID: "th8", texto: "hola", adjuntos: [], turnId: "turno-8"), hasta: 0.8)
        XCTAssertTrue(r.cerrado)
        let tools = r.eventos.compactMap { if case .tool(let h) = $0 { return h } else { return nil } }
        XCTAssertEqual(tools.last?.titulo, "Leyendo notas.md")
        XCTAssertEqual(tools.last?.clase, .read)
        XCTAssertEqual(tools.last?.estado, .hecha)
        let entregas = r.eventos.compactMap { if case .entrega(let e) = $0 { return e } else { return nil } }
        XCTAssertEqual(entregas.first?.id, "f-f9")
        XCTAssertEqual(entregas.first?.url, "https://x.test/f9")
        XCTAssertEqual(entregas.first?.bytesRemotos, 1234)
        XCTAssertTrue(r.eventos.contains { if case .usage(10, 5) = $0 { return true } else { return false } })
        let fases = await senales.fases
        XCTAssertEqual(fases.first, "waking")
        XCTAssertEqual(fases.last, "reposo")
        let steer = await caps.steer
        XCTAssertEqual(steer, true)
    }

    actor Caps { var steer: Bool?; func set(_ s: Bool) { steer = s } }

    /// Reconectar a mitad de run (grabado de LangGraph): la burbuja se llama como el run VIVO.
    func testReconnectToLiveRunNamesBubbleByLiveRun() async throws {
        StubAGUI.preparar([(200, Fixture.text("android/06-reconnect-live"))])
        let r = await leer(cliente.seguir(sessionID: "th9")!, hasta: 0.8)
        if case .turno(let id) = r.eventos.first { XCTAssertEqual(id, "run-a-6") } else { XCTFail("sin .turno: \(r.eventos)") }
        XCTAssertFalse(texto(r.eventos).isEmpty)
        XCTAssertFalse(r.cerrado)
    }

    func testSteerTakesOverTheLiveStream() async throws {
        StubAGUI.preparar([
            (200, Fixture.text("agui-turn-interrupt")),
            (409, #"{"error":"run_active","message":"no"}"#),
            (200, Self.sse([
                ["type": "RUN_STARTED", "threadId": "th10", "runId": "turno-10"],
                ["type": "CUSTOM", "name": "ghosty.injected", "value": ["messageId": "x:u"]],
                ["type": "TEXT_MESSAGE_CONTENT", "messageId": "turno-10:a9", "delta": " y además esto."],
                ["type": "RUN_FINISHED", "threadId": "th10", "runId": "turno-10", "outcome": ["type": "success"]],
            ])),
        ])
        let flujo = cliente.prompt(sessionID: "th10", texto: "hola", adjuntos: [], turnId: "turno-10")
        let box = Caja()
        let lector = Task { do { for try await r in flujo { await box.add(r) }; await box.cerrar(nil) } catch { await box.cerrar(error) } }
        try await Task.sleep(for: .seconds(0.8))
        let no = try await cliente.mandarMas(sessionID: "th10", texto: "otra", turnId: "s1")
        XCTAssertFalse(no)
        let sigueAbierto = await box.cerrado
        XCTAssertFalse(sigueAbierto, "un steer rechazado no toca el flujo")
        let si = try await cliente.mandarMas(sessionID: "th10", texto: "y además", turnId: "s2")
        XCTAssertTrue(si)
        let body = StubAGUI.cuerpos[2]
        XCTAssertEqual((body["forwardedProps"] as? [String: Any])?["steer"] as? String, "turno-10")
        XCTAssertEqual(body["runId"] as? String, "s2")
        try await Task.sleep(for: .seconds(0.5))
        let ev = await box.eventos
        XCTAssertTrue(texto(ev).hasSuffix(" y además esto."))
        let cerrado = await box.cerrado
        XCTAssertTrue(cerrado)
        lector.cancel()
    }
}

final class AGUIInputTests: XCTestCase {
    func testAttachmentsGoAsContentParts() async throws {
        let a = Adjunto(nombre: "foto.png", mime: "image/png", datos: Data([1, 2, 3]))
        var input = AGUITransport.Input(threadId: "t", runId: "r", text: "mira")
        input.attachments = [.init(json: try await ClienteGS.parte(a))]
        let content = (input.json["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "text")
        XCTAssertEqual(content?[1]["type"] as? String, "image")
        XCTAssertEqual((content?[1]["source"] as? [String: Any])?["type"] as? String, "data")
        XCTAssertEqual((content?[1]["source"] as? [String: Any])?["value"] as? String, Data([1, 2, 3]).base64EncodedString())
    }
}
