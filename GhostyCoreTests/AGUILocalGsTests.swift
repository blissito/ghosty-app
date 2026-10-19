import XCTest
@testable import GhostyCore

/// Contra gs LOCAL (rama agui, agente simulado). Env: GHOSTY_TOKEN (local), GS_LOCAL_AGENT, GS_LOCAL_SIDS (5 ids).
final class AGUILocalGsTests: XCTestCase {
    var agent: String { ProcessInfo.processInfo.environment["GS_LOCAL_AGENT"] ?? "" }
    var sids: [String] { (ProcessInfo.processInfo.environment["GS_LOCAL_SIDS"] ?? "").split(separator: ",").map(String.init) }

    override func setUp() async throws {
        guard !agent.isEmpty, sids.count >= 6 else { throw XCTSkip("sin gs local") }
        ClienteGS.runURL = URL(string: "http://localhost:5180/api/v2/me/agents/\(agent)/agui")
    }
    override func tearDown() { ClienteGS.runURL = nil; ClienteGS.modoPermisos = nil }

    func texto(_ ev: [ACPClient.Replay]) -> String { ev.compactMap { if case .agent(let t) = $0 { return t } else { return nil } }.joined() }
    func correr(_ f: AsyncThrowingStream<ACPClient.Replay, Error>) -> (ClienteGSAGUITests.Caja, Task<Void, Never>) {
        let c = ClienteGSAGUITests.Caja()
        return (c, Task { do { for try await r in f { await c.add(r) }; await c.cerrar(nil) } catch { await c.cerrar(error) } })
    }
    func esperar(_ c: ClienteGSAGUITests.Caja, _ s: Double = 40) async { for _ in 0..<Int(s * 4) { if await c.cerrado { return }; try? await Task.sleep(for: .milliseconds(250)) } }

    func testA_TurnWithToolAndUsage() async throws {
        let cl = ClienteGS(agentID: agent)
        let (c, t) = correr(cl.prompt(sessionID: sids[0], texto: "hola", adjuntos: [], turnId: UUID().uuidString.lowercased()))
        await esperar(c); defer { t.cancel() }
        let ev = await c.eventos
        let tools = ev.compactMap { if case .tool(let h) = $0 { return h } else { return nil } }
        print("GSL A cerrado=\(await c.cerrado) error=\(String(describing: await c.error)) texto=\(texto(ev).prefix(60)) tools=\(tools.map { "\($0.titulo)/\($0.clase)/\($0.estado)" }) usage=\(ev.contains { if case .usage = $0 { return true } else { return false } })")
        XCTAssertTrue(!texto(ev).isEmpty)
        let err = await c.error
        XCTAssertNil(err)
        XCTAssertEqual(tools.last?.estado, .hecha)
    }

    func approval(_ sid: String, aprobar: Bool) async throws {
        let cl = ClienteGS(agentID: agent)
        let s = Senales()
        await cl.alPedirPermiso { p in Task { await s.permiso(p) } }
        await cl.alResolverPermiso { id in Task { await s.resuelto(id) } }
        ClienteGS.modoPermisos = "ask"
        let (c, t) = correr(cl.prompt(sessionID: sid, texto: "necesito permiso para esto", adjuntos: [], turnId: UUID().uuidString.lowercased()))
        defer { t.cancel() }
        var ps: [ACPClient.Permiso] = []
        for _ in 0..<160 { ps = await s.permisos; if !ps.isEmpty { break }; try await Task.sleep(for: .milliseconds(250)) }
        print("GSL perm opciones=\(ps.first.map { $0.opciones.map { "\($0.id):\($0.tipo)" } } ?? []) cerradoAntes=\(await c.cerrado)")
        guard let p = ps.first else { return XCTFail("sin interrupt") }
        let cerradoAntes = await c.cerrado
        XCTAssertFalse(cerradoAntes)
        let op = p.opciones.first { $0.tipo.hasPrefix(aprobar ? "allow" : "reject") }!.id
        try await cl.responderPermiso(p.id, opcion: op)
        await esperar(c)
        let ev = await c.eventos
        let turnos = Set(ev.compactMap { if case .turno(let id) = $0 { return id } else { return nil } })
        print("GSL perm \(aprobar ? "aprobado" : "rechazado") cerrado=\(await c.cerrado) error=\(String(describing: await c.error)) turnos=\(turnos.count) resueltos=\(await s.resueltos.count) cola=\(texto(ev).suffix(80).replacingOccurrences(of: "\n", with: " "))")
        let cerrado = await c.cerrado, err = await c.error
        XCTAssertTrue(cerrado)
        XCTAssertNil(err)
        XCTAssertEqual(turnos.count, 1, "el resume sigue en la misma burbuja")
    }
    func testB_ApprovalApproved() async throws { try await approval(sids[1], aprobar: true) }
    func testC_ApprovalRejected() async throws { try await approval(sids[2], aprobar: false) }

    func testD_Delivery() async throws {
        let cl = ClienteGS(agentID: agent)
        let (c, t) = correr(cl.prompt(sessionID: sids[3], texto: "mándame un archivo", adjuntos: [], turnId: UUID().uuidString.lowercased()))
        await esperar(c); defer { t.cancel() }
        let e = await c.eventos.compactMap { if case .entrega(let e) = $0 { return e } else { return nil } }
        print("GSL D entregas=\(e.map { "\($0.titulo)/\($0.forma)/\($0.remoteID ?? "-")" })")
        XCTAssertFalse(e.isEmpty)
    }

    func testE_SlowReconnectAndCancel() async throws {
        let cl = ClienteGS(agentID: agent)
        let turn = UUID().uuidString.lowercased()
        let (c, t) = correr(cl.prompt(sessionID: sids[4], texto: "hazlo lento", adjuntos: [], turnId: turn))
        for _ in 0..<40 { if texto(await c.eventos).count > 10 { break }; try await Task.sleep(for: .milliseconds(250)) }
        t.cancel()  // la app se va: NO detiene nada
        try await Task.sleep(for: .seconds(2))
        let otro = ClienteGS(agentID: agent)  // como volver del fondo
        let (v, tv) = correr(otro.seguir(sessionID: sids[4])!)
        defer { tv.cancel() }
        for _ in 0..<40 { if texto(await v.eventos).count > 10 { break }; try await Task.sleep(for: .milliseconds(250)) }
        let ve = await v.eventos
        let first = ve.compactMap { if case .turno(let id) = $0 { return id } else { return nil } }.first
        print("GSL E reconexión turno=\(first == turn) chars=\(texto(ve).count)")
        XCTAssertEqual(first, turn, "la burbuja se llama como el run vivo")
        // 409 sin steer: el mensaje nuevo detiene el vivo y sale
        await otro.cancelar(sids[4])
        try await Task.sleep(for: .seconds(2))
        let veFin = await v.eventos
        let cerrados = veFin.filter { if case .cerrado = $0 { return true } else { return false } }.count
        print("GSL E tras detener cerrado-turno=\(cerrados) vigilante-cerrado=\(await v.cerrado)")
        XCTAssertEqual(cerrados, 1)
    }

    func testF_RunError() async throws {
        let cl = ClienteGS(agentID: agent)
        let (c, t) = correr(cl.prompt(sessionID: sids[5], texto: "provoca un error", adjuntos: [], turnId: UUID().uuidString.lowercased()))
        await esperar(c); defer { t.cancel() }
        print("GSL F error=\(String(describing: await c.error))")
        let err = await c.error
        XCTAssertNotNil(err)
    }
}
