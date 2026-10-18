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

    /// Un video de `VideoRun` que el agente entregó sin pegar el ```eb-file``` en su texto.
    func testPlacedVideoRunComesBackAsCard() {
        let m: [String: Any] = ["seq": 6, "role": "assistant", "text": "Aquí está tu video de LinkedIn."]
        var f = GhostyAPI.ArchivoDeSesion(id: "v1", nombre: "post.mp4", mime: "video/mp4", bytes: 1, segundos: nil, onda: nil)
        f.origen = "agente"; f.videoRunID = "run1"; f.despuesDe = 6
        let page = ReplayToMessages.convertWithServerIndex(ClienteGS.replay(of: m, index: 6), archivos: ["post.mp4#v1": f])
        XCTAssertEqual(page.messages.last?.id, "entrega-f-v1")
        // Sin ubicar sigue fuera: se amontonaría al final del hilo.
        f.despuesDe = nil
        let sinSitio = ReplayToMessages.convertWithServerIndex(ClienteGS.replay(of: m, index: 6), archivos: ["post.mp4#v1": f])
        XCTAssertFalse(sinSitio.messages.contains { $0.id == "entrega-f-v1" })
        // Con el ```eb-file``` en el texto: una sola tarjeta, la del texto.
        f.despuesDe = 6; f.objectKey = "videos/post.mp4"
        let conBloque: [String: Any] = ["seq": 6, "role": "assistant", "text":
            "Aquí está.\n```eb-file\n{\"url\":\"https://b.example/videos/post.mp4?sig=x\",\"name\":\"post.mp4\",\"mime\":\"video/mp4\"}\n```"]
        let unaSola = ReplayToMessages.convertWithServerIndex(ClienteGS.replay(of: conBloque, index: 6), archivos: ["post.mp4#v1": f])
        XCTAssertEqual(unaSola.messages.filter { $0.id.hasPrefix("entrega-") }.count, 1)
    }
}
