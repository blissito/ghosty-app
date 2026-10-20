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
