import XCTest
@testable import GhostyCore

/// Flujos AG-UI GRABADOS de un servidor real (`~/ghostykit/examples/langgraph`, adaptador oficial
/// `@ag-ui/langgraph`), los mismos que prueban la web y Piloto. Se leen del árbol de fuentes: el
/// simulador corre sobre el disco de la Mac.
enum Fixture {
    static func text(_ name: String, file: StaticString = #filePath) -> String {
        let dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().appendingPathComponent("Fixtures")
        return (try? String(contentsOf: dir.appendingPathComponent("\(name).sse"), encoding: .utf8)) ?? ""
    }
    static func events(_ name: String) -> [AGUIEvent] { SSEParser.events(in: text(name)) }
}

final class SSEParserTests: XCTestCase {
    func testSplitsOnBlankLineAndIgnoresPings() {
        let m = SSEParser.messages(in: ": ping\n\ndata: {\"type\":\"A\"}\n\n: ping\ndata: {\"type\":\"B\"}\n\n")
        XCTAssertEqual(m.map(\.data), ["{\"type\":\"A\"}", "{\"type\":\"B\"}"])
    }

    func testMultiLineDataAndCRLF() {
        var p = SSEParser()
        XCTAssertNil(p.line("event: x\r"))
        XCTAssertNil(p.line("data: uno\r"))
        XCTAssertNil(p.line("data:dos\r"))
        XCTAssertEqual(p.line("\r"), .init(event: "x", data: "uno\ndos", id: nil))
    }

    func testLastEventWithoutBlankLineStillCounts() {
        XCTAssertEqual(SSEParser.messages(in: "data: {\"type\":\"RUN_FINISHED\"}").count, 1)
    }

    func testRecordedStreamParsesEveryEvent() {
        let text = Fixture.text("agui-turn-interrupt")
        XCTAssertFalse(text.isEmpty, "falta el fixture")
        let events = SSEParser.events(in: text)
        XCTAssertEqual(events.first?.type, "RUN_STARTED")
        XCTAssertEqual(events.last?.type, "RUN_FINISHED")
        XCTAssertEqual(events.filter { $0.type == "TEXT_MESSAGE_CONTENT" }.count, 23)
    }
}

final class AGUIReducerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_760_802_000)

    func testTurnWithInterruptBuildsStepsNarrationAndCard() {
        var s = AGUIReducer.beginSend(AGUIState(), text: "¿Por qué falló el monitor?", now: now.addingTimeInterval(-3))
        s = AGUIReducer.reduce(s, Fixture.events("agui-turn-interrupt"), now: now)
        XCTAssertFalse(s.busy)
        XCTAssertEqual(s.outcome, .interrupt)
        XCTAssertEqual(s.turns.map(\.role), [.user, .assistant])
        let a = s.turns[1]
        XCTAssertTrue(a.text.hasPrefix("Reviso tus crons."))
        XCTAssertEqual(a.tools.map(\.name), ["list_crons", "run_cron"])
        XCTAssertEqual(a.tools[0].status, "completed")
        // La que espera aprobación no gira: espera.
        XCTAssertEqual(a.tools[1].status, "pending")
        XCTAssertEqual(a.tools[1].detail, "job: purge-notifications")
        // Lo de antes de cada herramienta es narración.
        XCTAssertEqual(a.cuts.first, "Reviso tus crons.".count)
        XCTAssertEqual(a.seconds, 3)
        XCTAssertEqual(s.permissions.count, 1)
        XCTAssertEqual(s.permissions[0].id, "7e7350617e69e236575c0974266608fc")
        XCTAssertEqual(s.permissions[0].title, "Correr ahora purge-notifications")
        XCTAssertEqual(s.permissions[0].toolCallId, "call_run_cron_3")
        XCTAssertEqual(s.permissions[0].tool, "run_cron")
    }

    func testOpenPausedThreadShowsSnapshotAndCard() {
        let s = AGUIReducer.reduce(AGUIState(), Fixture.events("agui-open-paused"), now: now)
        XCTAssertEqual(s.turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(s.turns[1].tools.map(\.status), ["completed", "pending"])
        XCTAssertEqual(s.permissions.map(\.title), ["Correr ahora purge-notifications"])
        // Abrir no es un turno de este cliente: no hay segundos.
        XCTAssertNil(s.turns[1].seconds)
    }

    func testOpenDoneThreadHasNoCards() {
        let s = AGUIReducer.reduce(AGUIState(), Fixture.events("agui-open-done"), now: now)
        XCTAssertEqual(s.outcome, .success)
        XCTAssertTrue(s.permissions.isEmpty)
        XCTAssertEqual(s.turns.map(\.role), [.user, .assistant])
        XCTAssertTrue(s.turns[1].text.hasSuffix("No corrí la purga. Cuando quieras, me dices."))
        XCTAssertEqual(s.turns[1].tools.map(\.name), ["list_crons", "run_cron"])
    }

    func testOpenLiveRunContinuesAfterSnapshot() {
        let s = AGUIReducer.reduce(AGUIState(), Fixture.events("agui-open-live"), now: now)
        XCTAssertEqual(s.turns.filter { $0.role == .user }.count, 1)
        XCTAssertFalse(s.turns.last!.tools.isEmpty)
    }

    func testCancelledRunClosesOpenSteps() {
        var s = AGUIReducer.beginSend(AGUIState(), text: "hola", now: now)
        s = AGUIReducer.reduce(s, Fixture.events("agui-cancelled-run"), now: now)
        XCTAssertEqual(s.outcome, .cancelled)
        XCTAssertFalse(s.turns.last!.tools.contains { $0.status == "in_progress" })
    }

    func testRunErrorEndsWithMessage() {
        var s = AGUIReducer.beginSend(AGUIState(), text: "hola", now: now)
        s = AGUIReducer.reduce(s, [
            AGUIEvent(type: "RUN_STARTED", ["runId": "r1"]),
            AGUIEvent(type: "TOOL_CALL_START", ["toolCallId": "t1", "toolCallName": "bash"]),
            AGUIEvent(type: "RUN_ERROR", ["message": "Se acabó el saldo.", "code": "limit"]),
        ], now: now)
        XCTAssertEqual(s.outcome, .error("Se acabó el saldo.", code: "limit"))
        XCTAssertEqual(s.turns.last?.tools.first?.status, "failed")
        XCTAssertFalse(s.busy)
    }

    /// La cuenta regresiva usa el reloj del SERVIDOR: un teléfono 10 min adelantado no la acorta.
    func testDeadlineUsesServerClock() {
        let serverNow = Date(timeIntervalSince1970: 1_760_800_000)
        let phoneNow = serverNow.addingTimeInterval(600)
        let expires = serverNow.addingTimeInterval(120)
        let iso = ISO8601DateFormatter().string(from: expires)
        let s = AGUIReducer.reduce(AGUIState(), AGUIEvent(type: "RUN_FINISHED", [
            "timestamp": serverNow.timeIntervalSince1970 * 1000,
            "outcome": ["type": "interrupt", "interrupts": [["id": "i1", "reason": "confirmation", "message": "x", "expiresAt": iso]]],
        ]), now: phoneNow)
        XCTAssertEqual(s.permissions[0].deadline!.timeIntervalSince(phoneNow), 120, accuracy: 1)
    }

    func testCustomStepNamesTheToolForPeople() {
        let s = AGUIReducer.reduce(AGUIState(), [
            AGUIEvent(type: "TOOL_CALL_START", ["toolCallId": "t1", "toolCallName": "Read"]),
            AGUIEvent(type: "CUSTOM", ["name": "ghosty.step", "value": ["toolCallId": "t1", "title": "Leyendo notas.md", "kind": "read"]]),
            AGUIEvent(type: "CUSTOM", ["name": "ghosty.title", "value": ["title": "Notas"]]),
        ], now: now)
        XCTAssertEqual(s.turns.last?.tools.first?.title, "Leyendo notas.md")
        XCTAssertEqual(s.turns.last?.tools.first?.kind, "read")
        XCTAssertEqual(s.title, "Notas")
    }

    func testStateDeltaPatchesSharedState() {
        let s = AGUIReducer.reduce(AGUIState(), [
            AGUIEvent(type: "STATE_SNAPSHOT", ["snapshot": ["queue": ["ahead": 2]]]),
            AGUIEvent(type: "STATE_DELTA", ["delta": [["op": "replace", "path": "/queue/ahead", "value": 1],
                                                       ["op": "add", "path": "/phase", "value": "waking"]]]),
        ], now: now)
        XCTAssertEqual((s.shared["queue"] as? [String: Any])?["ahead"] as? Int, 1)
        XCTAssertEqual(s.shared["phase"] as? String, "waking")
    }
}
