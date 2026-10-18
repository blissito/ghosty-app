import XCTest
@testable import GhostyCore

/// Contra un servidor AG-UI DE VERDAD (no grabado). Sólo corre con `AGUI_LIVE=<url>`, por ejemplo el
/// de `~/ghostykit/examples/langgraph` (`npm run dev` + `npm run agui`):
///
///     TEST_RUNNER_AGUI_LIVE=http://localhost:8000/agent xcodebuild test -scheme GhostyCore …
final class AGUILiveTests: XCTestCase {
    func testApprovalRoundTripAgainstRealServer() async throws {
        guard let raw = ProcessInfo.processInfo.environment["AGUI_LIVE"], let url = URL(string: raw) else {
            throw XCTSkip("sin AGUI_LIVE")
        }
        AGUITransport.defaultSession = {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 60
            return URLSession(configuration: c)
        }()
        ClienteGS.runURL = url
        ClienteGS.autorizar = { _, _ in }
        defer { ClienteGS.runURL = nil }
        let cliente = ClienteGS(agentID: "vivo")
        let senales = Senales()
        await cliente.alPedirPermiso { p in Task { await senales.permiso(p) } }
        await cliente.alResolverPermiso { id in Task { await senales.resuelto(id) } }
        let hilo = UUID().uuidString.lowercased()

        let caja = ClienteGSAGUITests.Caja()
        let lector = Task {
            do { for try await r in cliente.prompt(sessionID: hilo, texto: "¿Por qué falló el monitor?", adjuntos: [], turnId: UUID().uuidString.lowercased()) { await caja.add(r) }; await caja.cerrar(nil) }
            catch { await caja.cerrar(error) }
        }
        // El agente revisa y se detiene a pedir permiso.
        var permisos: [ACPClient.Permiso] = []
        for _ in 0..<60 where permisos.isEmpty { try await Task.sleep(for: .milliseconds(500)); permisos = await senales.permisos }
        XCTAssertEqual(permisos.count, 1)
        let cerradoAntes = await caja.cerrado
        XCTAssertFalse(cerradoAntes, "esperando aprobación el flujo sigue abierto")

        try await cliente.responderPermiso(permisos[0].id, opcion: permisos[0].opciones.first { $0.tipo.hasPrefix("allow") }!.id)
        for _ in 0..<60 { if await caja.cerrado { break }; try await Task.sleep(for: .milliseconds(500)) }
        let cerrado = await caja.cerrado
        let error = await caja.error
        XCTAssertTrue(cerrado)
        XCTAssertNil(error)
        let ev = await caja.eventos
        let texto = ev.compactMap { if case .agent(let t) = $0 { return t } else { return nil } }.joined()
        XCTAssertTrue(texto.contains("Reviso"), texto)
        XCTAssertGreaterThanOrEqual(ev.filter { if case .tool = $0 { return true } else { return false } }.count, 2)
        lector.cancel()

        // Reconectar a un hilo ya en reposo: sin tarjetas nuevas ni trabajo en vivo.
        let vig = ClienteGSAGUITests.Caja()
        let t2 = Task { do { for try await r in cliente.seguir(sessionID: hilo)! { await vig.add(r) } } catch {} }
        try await Task.sleep(for: .seconds(2))
        t2.cancel()
        let n = await senales.permisos.count
        XCTAssertEqual(n, 1)
        let vivos = await vig.eventos
        XCTAssertTrue(vivos.isEmpty, "\(vivos)")
    }
}
