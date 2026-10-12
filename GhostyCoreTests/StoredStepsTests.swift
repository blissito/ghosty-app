import XCTest
@testable import GhostyCore

/// Los pasos que gs guarda con la respuesta vuelven como tarjeta al reabrir el hilo.
final class StoredStepsTests: XCTestCase {
    func testAgentMessageKeepsItsSteps() {
        let m: [String: Any] = [
            "seq": 4, "role": "assistant", "text": "Listo, aquí está.",
            "steps": [
                ["id": "t1", "title": "Busqué en la web", "kind": "web_search", "detalle": "ríos de México", "status": "completed"],
                ["id": "t2", "title": "Entregué el PDF", "kind": "deliver", "status": "failed"],
            ],
        ]
        let page = ReplayToMessages.convertWithServerIndex(ClienteGS.replay(of: m, index: 4), archivos: [:])
        guard case .agent(let text, let tools, _) = page.messages.first?.kind else { return XCTFail("sin mensaje") }
        XCTAssertEqual(text, "Listo, aquí está.")
        XCTAssertEqual(tools?.herramientas.map(\.titulo), ["Busqué en la web", "Entregué el PDF"])
        XCTAssertEqual(tools?.herramientas.first?.clase, .webSearch)
        XCTAssertEqual(tools?.herramientas.first?.detalle, "ríos de México")
        XCTAssertEqual(tools?.herramientas.last?.estado, .fallida)
    }

    func testAgentMessageWithoutStepsHasNoCard() {
        let m: [String: Any] = ["seq": 2, "role": "assistant", "text": "Hola"]
        let page = ReplayToMessages.convertWithServerIndex(ClienteGS.replay(of: m, index: 2), archivos: [:])
        guard case .agent(_, let tools, _) = page.messages.first?.kind else { return XCTFail("sin mensaje") }
        XCTAssertNil(tools)
    }
}
