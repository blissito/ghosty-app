import XCTest
@testable import GhostyCore

/// Contra gs de PRODUCCIÓN. Sólo con GHOSTY_TOKEN y conversaciones NUEVAS.
final class AGUIProdTests: XCTestCase {
    var agent: String { ProcessInfo.processInfo.environment["PROD_AGENT"] ?? "" }
    var permAgent: String { ProcessInfo.processInfo.environment["PROD_PERM_AGENT"] ?? "" }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["GHOSTY_TOKEN"]?.isEmpty == false, !agent.isEmpty else { throw XCTSkip("sin token") }
    }

    func leer(_ f: AsyncThrowingStream<ACPClient.Replay, Error>, segundos: Double, hasta: ((ClienteGSAGUITests.Caja) async -> Bool)? = nil) async -> ClienteGSAGUITests.Caja {
        let caja = ClienteGSAGUITests.Caja()
        let t = Task { do { for try await r in f { await caja.add(r) }; await caja.cerrar(nil) } catch { await caja.cerrar(error) } }
        let fin = Date().addingTimeInterval(segundos)
        while Date() < fin {
            if await caja.cerrado { break }
            if let hasta, await hasta(caja) { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        _ = t
        return caja
    }
    func texto(_ ev: [ACPClient.Replay]) -> String { ev.compactMap { if case .agent(let t) = $0 { return t } else { return nil } }.joined() }

    func test1_TurnReconnectStopSteer() async throws {
        let c = ClienteGS(agentID: agent)
        let s = Senales()
        await c.alCambiarEstado { _, f in Task { await s.fase(f) } }
        let caps = ClienteGSAGUITests.Caps()
        await c.alConocerCapacidades { v in Task { await caps.set(v) } }
        let (sid, _) = try await c.nuevaSesion(cwd: "/data/work")
        print("PROD sid=\(sid)")
        // A. un turno
        let a = await leer(c.prompt(sessionID: sid, texto: "Contesta exactamente con la palabra: listo", adjuntos: [], turnId: UUID().uuidString.lowercased()), segundos: 120)
        let ae = await a.eventos; let ac = await a.cerrado; let aerr = await a.error
        print("PROD A cerrado=\(ac) error=\(String(describing: aerr)) texto=\(texto(ae).prefix(80)) eventos=\(ae.count)")
        print("PROD fases=\(await s.fases) steer=\(String(describing: await caps.steer))")
        XCTAssertTrue(ac); XCTAssertNil(aerr); XCTAssertTrue(texto(ae).lowercased().contains("listo"))
        // B. reconectar a hilo quieto
        let b = await leer(c.seguir(sessionID: sid)!, segundos: 8)
        let be = await b.eventos
        print("PROD B eventos=\(be.count) cerrado=\(await b.cerrado)")
        XCTAssertTrue(texto(be).isEmpty)
        // C. steer en un turno largo
        let largo = c.prompt(sessionID: sid, texto: "Escribe los números del 1 al 150, uno por línea, sin nada más.", adjuntos: [], turnId: UUID().uuidString.lowercased())
        let cc = ClienteGSAGUITests.Caja()
        let tc = Task { do { for try await r in largo { await cc.add(r) }; await cc.cerrar(nil) } catch { await cc.cerrar(error) } }
        for _ in 0..<200 { if texto(await cc.eventos).count > 20 { break }; try await Task.sleep(for: .milliseconds(300)) }
        let entro = try await c.mandarMas(sessionID: sid, texto: "Al terminar escribe FIN.", turnId: UUID().uuidString.lowercased())
        print("PROD C steer entró=\(entro)")
        for _ in 0..<240 { if await cc.cerrado { break }; try await Task.sleep(for: .milliseconds(500)) }
        print("PROD C cola=\(texto(await cc.eventos).suffix(30).replacingOccurrences(of: "\n", with: " "))")
        // D. detener uno largo a media respuesta
        let cd = ClienteGSAGUITests.Caja()
        let largo2 = c.prompt(sessionID: sid, texto: "Escribe los números del 1 al 3000, uno por línea, sin nada más.", adjuntos: [], turnId: UUID().uuidString.lowercased())
        let tc2 = Task { do { for try await r in largo2 { await cd.add(r) }; await cd.cerrar(nil) } catch { await cd.cerrar(error) } }
        for _ in 0..<200 { if texto(await cd.eventos).count > 40 { break }; try await Task.sleep(for: .milliseconds(300)) }
        await c.cancelar(sid)
        defer { tc2.cancel() }
        for _ in 0..<60 { if await cd.cerrado { break }; try await Task.sleep(for: .milliseconds(500)) }
        let ce = await cd.eventos
        print("PROD D cerrado=\(await cd.cerrado) error=\(String(describing: await cd.error)) chars=\(texto(ce).count) cola=\(texto(ce).suffix(40).replacingOccurrences(of: "\n", with: " "))")
        let ccCerrado = await cd.cerrado
        XCTAssertTrue(ccCerrado)
        tc.cancel()
    }

    func test2_PermissionRejected() async throws {
        guard !permAgent.isEmpty else { throw XCTSkip("sin agente de permisos") }
        let c = ClienteGS(agentID: permAgent)
        let s = Senales()
        await c.alPedirPermiso { p in Task { await s.permiso(p) } }
        await c.alResolverPermiso { id in Task { await s.resuelto(id) } }
        let (sid, _) = try await c.nuevaSesion(cwd: "/data/work")
        let st = try await c.estado(de: sid)
        print("PROD2 sid=\(sid) caps=\(String(describing: st?["caps"]).replacingOccurrences(of: "\n", with: " "))")
        ClienteGS.modoPermisos = "ask"
        defer { ClienteGS.modoPermisos = nil }
        let f = c.prompt(sessionID: sid, texto: "Usa tu herramienta de terminal para correr `ls /tmp` y dime cuántas entradas hay.", adjuntos: [], turnId: UUID().uuidString.lowercased())
        let caja = ClienteGSAGUITests.Caja()
        let t = Task { do { for try await r in f { await caja.add(r) }; await caja.cerrar(nil) } catch { await caja.cerrar(error) } }
        var ps: [ACPClient.Permiso] = []
        for _ in 0..<240 { ps = await s.permisos; let fin = await caja.cerrado; if !ps.isEmpty || fin { break }; try await Task.sleep(for: .milliseconds(500)) }
        print("PROD2 texto=\(texto(await caja.eventos).suffix(200).replacingOccurrences(of: "\n", with: " ")) tools=\(await caja.eventos.filter { if case .tool = $0 { return true } else { return false } }.count)")
        print("PROD2 permisos=\(ps.map { "\($0.titulo) [\($0.opciones.map { "\($0.id):\($0.tipo)" }.joined(separator: ","))]" }) cerrado=\(await caja.cerrado) error=\(String(describing: await caja.error))")
        guard let p = ps.first else { t.cancel(); return }
        let no = p.opciones.first { $0.tipo.hasPrefix("reject") }!.id
        try await c.responderPermiso(p.id, opcion: no)
        for _ in 0..<240 { if await caja.cerrado { break }; try await Task.sleep(for: .milliseconds(500)) }
        let ev = await caja.eventos
        print("PROD2 tras rechazar cerrado=\(await caja.cerrado) error=\(String(describing: await caja.error)) resueltos=\(await s.resueltos) texto=\(texto(ev).suffix(120).replacingOccurrences(of: "\n", with: " "))")
        let cerrado = await caja.cerrado
        XCTAssertTrue(cerrado)
        t.cancel()
    }
}
