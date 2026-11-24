import XCTest
@testable import GhostyCore

/// `actions`, `compose` y `claim` que manda gs (24-nov-2026): el cliente sólo los pinta.
final class DevActionsTests: XCTestCase {
    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    func testDecodesActionsOfALocalRow() {
        let r = DevLocalRun.from(json: json("""
        {"id":"local:a/b#94","repo":"a/b","issue":94,"title":"Algo","phase":"working","writer":"bliss",
         "actions":[
          {"id":"start","label":"Mandar a la nube","kind":"start","primary":true},
          {"id":"release_claim","label":"Soltar","kind":"op","op":"release_claim","confirm":"¿Soltar?","destructive":true},
          {"id":"open","label":"Abrir en GitHub","kind":"link","href":"https://github.com/a/b/issues/94"}],
         "claim":{"at":"2026-11-24T01:00:00.000Z","stale":true},
         "compose":{"enabled":true,"routedTo":"cloud","writer":"Ghosty"}}
        """))
        let a = try? XCTUnwrap(r?.actions)
        XCTAssertEqual(a?.map(\.id), ["start", "release_claim", "open"])
        XCTAssertEqual(a?[0].kind, .start)
        XCTAssertTrue(a?[0].primary == true)
        XCTAssertEqual(a?[1].confirm, "¿Soltar?")
        XCTAssertTrue(a?[1].destructive == true)
        XCTAssertEqual(a?[2].href?.absoluteString, "https://github.com/a/b/issues/94")
        XCTAssertEqual(r?.claim?.stale, true)
        XCTAssertNotNil(r?.claim?.staleLine)
        XCTAssertEqual(r?.compose?.routedTo, "cloud")
    }

    func testUnknownActionAndKindAreKeptWithTheirLabel() {
        let list = DevAction.list(from: json("""
        {"a":[{"id":"teleport","label":"Teletransportar","kind":"warp","disabled":{"why":"Aún no"}},
              {"label":"Sin id","kind":"op"}]}
        """)["a"])
        XCTAssertEqual(list?.count, 2)
        XCTAssertEqual(list?[0].label, "Teletransportar")
        XCTAssertEqual(list?[0].kind, .other("warp"))
        XCTAssertTrue(list?[0].isDisabled == true)
        XCTAssertEqual(list?[0].disabledWhy, "Aún no")
        XCTAssertEqual(list?[1].id, "Sin id")
    }

    func testMissingActionsMeansOldServer() {
        let run = DevRun.from(json: json(#"{"id":"r1","repo":"a/b","phase":"waiting_ci","ready":true,"canMerge":true}"#))
        XCTAssertNil(run?.actions)
        // Respaldo: sin `actions` se usa lo calculado antes.
        XCTAssertEqual(run?.canMerge, true)
        XCTAssertEqual(run?.readyToMerge, true)
    }

    func testServerActionsDecideMerge() {
        let on = DevRun.from(json: json(#"{"id":"r1","repo":"a/b","phase":"waiting_ci","actions":[{"id":"merge","label":"Merge","kind":"op","op":"merge","primary":true}]}"#))
        XCTAssertEqual(on?.canMerge, true)
        let off = DevRun.from(json: json(#"{"id":"r1","repo":"a/b","phase":"waiting_ci","ready":true,"canMerge":true,"actions":[{"id":"merge","label":"Merge","kind":"op","op":"merge","disabled":{"why":"El CI sigue corriendo"}}]}"#))
        XCTAssertEqual(off?.canMerge, false)
        XCTAssertEqual(off?.action("merge")?.disabledWhy, "El CI sigue corriendo")
        let none = DevRun.from(json: json(#"{"id":"r1","repo":"a/b","phase":"stopped","pr":3,"ready":true,"actions":[]}"#))
        XCTAssertEqual(none?.canMerge, false)
        XCTAssertEqual(none?.canReopen, false)
        let reopen = DevRun.from(json: json(#"{"id":"r1","repo":"a/b","phase":"stopped","actions":[{"id":"reopen","label":"Reabrir","kind":"op","op":"reopen"}]}"#))
        XCTAssertEqual(reopen?.canReopen, true)
    }

    func testComposeDisabledKeepsWhyAndAction() {
        let c = DevCompose.from(json: json("""
        {"c":{"enabled":false,"why":"La fábrica está en pausa","action":{"id":"resume_factory_and_send","label":"Reanudar la fábrica y enviar"}}}
        """)["c"])
        XCTAssertEqual(c?.enabled, false)
        XCTAssertEqual(c?.disabledText, "La fábrica está en pausa")
        XCTAssertEqual(c?.action?.id, "resume_factory_and_send")
        // Sin motivo, el campo igual dice algo.
        XCTAssertFalse(DevCompose(enabled: false).disabledText.isEmpty)
    }

    func testSentLineAlwaysHasAnOwner() {
        XCTAssertEqual(DevSent(routedTo: "cloud", writer: "Ghosty").line, "Lo tomó Ghosty en la nube.")
        XCTAssertEqual(DevSent(routedTo: "terminal", writer: "bliss").line, "Le llegó a @bliss.")
        XCTAssertEqual(DevSent(routedTo: "terminal", writer: nil).line, "Le llegó a tu terminal.")
    }

    func testPRCardInheritsServerFields() {
        let card = DevRun.from(card: json("""
        {"id":"pr:a/b#5","repo":"a/b","pr":5,"title":"PR","column":"review","status":{"label":"CI","category":"in_progress"},
         "actions":[{"id":"start","label":"Mandar a la nube","kind":"start"}],"compose":{"enabled":true,"routedTo":"terminal","writer":"bliss"}}
        """))
        XCTAssertEqual(card?.actions?.map(\.id), ["start"])
        XCTAssertEqual(card?.compose?.writer, "bliss")
    }
}
