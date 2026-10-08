import XCTest
@testable import GhostyCore

final class ResumeTests: XCTestCase {
    func testResumingAddsHeaderAndQuery() {
        let r = ClienteGS.resuming(URLRequest(url: URL(string: "https://x.test/events")!), from: "t1:7")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Last-Event-ID"), "t1:7")
        XCTAssertEqual(r.url?.query, "resume=1")
    }
}
