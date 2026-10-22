import XCTest
@testable import GhostyCore

/// Pedido #120 (20-oct): tras «Merge» con el CI pendiente el botón seguía vivo. En cola ya no te toca.
final class FactoryMergeQueuedTests: XCTestCase {
    private func run(_ status: String, _ events: [String]) throws -> FactoryRunDetail {
        let ev = events.map { #"{"type":"\#($0)"}"# }.joined(separator: ",")
        let json = #"{"id":120,"title":"t","status":"\#(status)","planVersion":1,"loops":0,"plans":[],"events":[\#(ev)],"running":[]}"#
        return try JSONDecoder().decode(FactoryRunDetail.self, from: Data(json.utf8))
    }

    func testQueuedMergeNoLongerAsks() throws {
        XCTAssertTrue(try run("pr_review", ["merge_queued", "behind_main", "check_pass"]).mergeQueued)
        XCTAssertTrue(try run("pr_review", ["behind_main", "merge_queued", "check_pass"]).mergeQueued)
    }

    func testRedCIAfterQueueAsksAgain() throws {
        XCTAssertFalse(try run("pr_review", ["ci_red_help", "merge_queued"]).mergeQueued)
        XCTAssertFalse(try run("pr_review", ["check_pass"]).mergeQueued)
        XCTAssertFalse(try run("done", ["merged", "merge_queued"]).mergeQueued)
    }
}

/// La línea del CI del PR (#119).
final class FactoryCILineTests: XCTestCase {
    private func ci(_ json: String) throws -> FactoryRunDetail.CI {
        try JSONDecoder().decode(FactoryRunDetail.CI.self, from: Data(json.utf8))
    }

    func testLines() throws {
        XCTAssertEqual(try ci(#"{"total":2,"passed":1,"running":[],"failed":[{"name":"typecheck","url":null}],"startedAt":null}"#).line,
                       "CI en rojo: typecheck")
        XCTAssertEqual(try ci(#"{"total":3,"passed":3,"running":[],"failed":[],"startedAt":null}"#).line, "CI en verde · 3 de 3 ✓")
        XCTAssertEqual(try ci(#"{"total":5,"passed":2,"running":[{"name":"a"},{"name":"b"},{"name":"c"}],"failed":[],"startedAt":null}"#).line,
                       "CI 2 de 5 ✓ · corre a, b…")
        XCTAssertNil(try ci(#"{"total":0,"passed":0,"running":[],"failed":[],"startedAt":null}"#).line)
    }
}

/// La tarjeta «Lugar» (21-oct) contra la forma exacta de gs `slotNoteOf` (`app/lib/ci/slot-courtesy.ts`).
final class FactorySlotNoteTests: XCTestCase {
    private let gs = #"""
    {"kind":"queued","title":"En fila por un lugar","message":"m","occupants":[
      {"label":"#40","detail":"pedido · construyendo","kind":"run","run":40,"pr":null,"repo":null,"releasable":false},
      {"label":"PR #92","detail":"preview","kind":"preview","run":null,"pr":92,"repo":"o/agenda","releasable":true}],
     "position":2,"ahead":[45],"chip":null,"suggestUpgrade":false,
     "plansUrl":"https://www.ghosty.studio/app/workspaces/x/plan","addSlotUrl":"https://www.ghosty.studio/app/workspaces/x/plan?lugar=1",
     "canAddSlot":false,"notifyAdmin":{"available":false,"lastAt":"2026-10-20T10:00:00.000Z","nextAt":"2026-11-03T10:00:00.000Z"}}
    """#

    func testDecodesGsShape() throws {
        let n = try JSONDecoder().decode(FactorySlotNote.self, from: Data(gs.utf8))
        XCTAssertTrue(n.queued)
        XCTAssertFalse(n.canAddSlot)
        XCTAssertEqual(n.addSlotUrl, "https://www.ghosty.studio/app/workspaces/x/plan?lugar=1")
        XCTAssertEqual(n.notifyAdmin?.available, false)
        XCTAssertEqual(n.notifyAdmin?.nextAt, "2026-11-03T10:00:00.000Z")
        // El `target` de `release` es el que acepta gs `releaseSlot`: {run} o {pr, repo}.
        XCTAssertEqual(n.occupants[0].target as? [String: Int], ["run": 40])
        XCTAssertFalse(n.occupants[0].releasable)
        let t = try XCTUnwrap(n.occupants[1].target)
        XCTAssertEqual(t["pr"] as? Int, 92)
        XCTAssertEqual(t["repo"] as? String, "o/agenda")
        XCTAssertTrue(n.occupants[1].releasable)
    }

    func testAdminNoteHasNoNotify() throws {
        let admin = #"{"kind":"courtesy","title":"t","message":"m","occupants":[],"plansUrl":"u","addSlotUrl":"u?lugar=1","canAddSlot":true,"notifyAdmin":null}"#
        let n = try JSONDecoder().decode(FactorySlotNote.self, from: Data(admin.utf8))
        XCTAssertTrue(n.canAddSlot)
        XCTAssertNil(n.notifyAdmin)
    }
}
