import XCTest
@testable import GhostyCore

/// Auditoría 3-nov: un escalado `decision` con opciones no se podía contestar desde iOS (la app no
/// leía `options`), y `waitingFix`/`waiting` salían como «Te toca decidir» o «Construyendo».
final class FactoryDecisionOptionsTests: XCTestCase {
    private func detail(_ extra: String, status: String = "escalated") throws -> FactoryRunDetail {
        let json = #"{"id":153,"title":"t","status":"\#(status)","planVersion":1,"loops":2,"plans":[],"events":[],"running":[]\#(extra)}"#
        return try JSONDecoder().decode(FactoryRunDetail.self, from: Data(json.utf8))
    }

    func testOptionsDecode() throws {
        let d = try detail(#","escalation":{"kind":"decision","reason":"CI rojo ajeno","actions":["choose","advise","close"],"options":[{"id":"a","label":"Arreglar en main","action":"fix_main","brief":"Abre un pedido"},{"id":"b","label":"Mergear así","action":"merge_as_is","brief":"x"}]}"#)
        XCTAssertEqual(d.escalation?.options.map(\.id), ["a", "b"])
        XCTAssertEqual(d.escalation?.options.last?.action, "merge_as_is")
        XCTAssertNil(d.escalation?.waitingFix)
    }

    func testOldServerWithoutOptions() throws {
        let d = try detail(#","escalation":{"kind":"decision","reason":"r","actions":["advise","fix","replan"]}"#)
        XCTAssertEqual(d.escalation?.options, [])
    }

    func testWaitingFixIsNotADecision() throws {
        let d = try detail(#","needsYou":false,"escalation":{"kind":"decision","reason":"r","waitingFix":211},"waiting":{"kind":"fix","run":211}"#)
        XCTAssertEqual(d.escalation?.waitingFix, 211)
        XCTAssertEqual(d.escalation?.label, "Esperando arreglo de main #211")
        XCTAssertEqual(d.waiting?.line, "Esperando el arreglo de main (#211)")
    }

    func testWaitingPerson() throws {
        let d = try detail(#","needsYou":true,"waiting":{"kind":"person","role":"build"}"#, status: "building")
        XCTAssertEqual(d.waiting?.asked, true)
        XCTAssertEqual(d.waiting?.line, "@build te preguntó algo: contesta en el hilo")
    }
}
