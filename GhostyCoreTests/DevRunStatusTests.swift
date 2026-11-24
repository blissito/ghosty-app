import XCTest
@testable import GhostyCore

/// 24-nov: iOS pinta la pastilla y la columna que calcula gs (`status`, `column`), sin recalcular fases.
final class DevRunStatusTests: XCTestCase {
    private func run(_ extra: String, phase: String = "needs_person") -> DevRun? {
        let json = #"{"id":"r1","repo":"o/r","phase":"\#(phase)","estado":"viejo",\#(extra)}"#
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))).flatMap { $0 as? [String: Any] }.flatMap(DevRun.from(json:))
    }

    func testServerLabelAndCategoryWinOverPhase() throws {
        // Run en `needs_person` sin pregunta: gs dice «Se detuvo», no «Te necesita».
        let r = try XCTUnwrap(run(#""column":"halted","status":{"category":"needs_action","label":"Se detuvo"}"#))
        XCTAssertEqual(r.phaseLabel, "Se detuvo")
        XCTAssertEqual(r.boardColumn, "halted")
        XCTAssertEqual(r.tone, .needsYou)
        XCTAssertNil(r.asked)
    }

    func testReadyColumnUsesServerLabel() throws {
        let r = try XCTUnwrap(run(#""column":"ready","status":{"category":"ready","label":"Listo para revisar"}"#, phase: "reviewing"))
        XCTAssertEqual(r.phaseLabel, "Listo para revisar")
        XCTAssertEqual(r.tone, .ready)
        XCTAssertEqual(r.stage, .merge)
    }

    func testUnknownValuesStayVisibleWithServerLabel() throws {
        let r = try XCTUnwrap(run(#""column":"snoozed","status":{"category":"paused","label":"En pausa"}"#, phase: "working"))
        XCTAssertEqual(r.phaseLabel, "En pausa")
        XCTAssertEqual(r.tone, .closed)
        XCTAssertEqual(r.boardColumn, "other")
        XCTAssertTrue(r.isOnBoard)
    }

    func testDoneAndHaltedLeaveTheBoard() throws {
        XCTAssertFalse(try XCTUnwrap(run(#""column":"done","status":{"category":"done","label":"Mergeado"}"#, phase: "merged")).isOnBoard)
        XCTAssertFalse(try XCTUnwrap(run(#""column":"halted","status":{"category":"failed","label":"Falló"}"#, phase: "failed")).isOnBoard)
    }

    func testFallbackWithoutServerFields() throws {
        let r = try XCTUnwrap(run("\"pr\":4", phase: "reviewing"))
        XCTAssertEqual(r.phaseLabel, "viejo")
        XCTAssertEqual(r.boardColumn, "review")
        XCTAssertEqual(r.tone, .working)
    }

    func testAskedStillParsed() throws {
        let r = try XCTUnwrap(run(#""column":"review","status":{"category":"needs_action","label":"Te necesita"},"asked":{"question":"¿A main?","options":["Sí","No"]}"#))
        XCTAssertEqual(r.asked?.options, ["Sí", "No"])
        XCTAssertEqual(r.phaseLabel, "Te necesita")
    }
}
