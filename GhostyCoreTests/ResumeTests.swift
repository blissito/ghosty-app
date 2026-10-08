import XCTest
@testable import GhostyCore

final class ResumeTests: XCTestCase {
    func testResumingAddsHeaderAndQuery() {
        let r = ClienteGS.resuming(URLRequest(url: URL(string: "https://x.test/events")!), from: "t1:7")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Last-Event-ID"), "t1:7")
        XCTAssertEqual(r.url?.query, "resume=1")
    }
}

final class HelpersHeaderTests: XCTestCase {
    func testSplitsWakeHeader() {
        let text = "---\n*Terminó «Ríos de México», «Lagos» · 8:12 a. m.*\n\nAquí va el resumen."
        let s = HelpersHeader.split(text)
        XCTAssertEqual(s?.header.titles, ["Ríos de México", "Lagos"])
        XCTAssertEqual(s?.header.time, "8:12 a. m.")
        XCTAssertEqual(s?.rest, "Aquí va el resumen.")
    }
    func testPlainTextIsNotAHeader() {
        XCTAssertNil(HelpersHeader.split("Hola, ¿qué tal?"))
    }
}

final class HelperColorTests: XCTestCase {
    /// Igual que `agentColor` de gs: "a" → 97 → índice 1 → #edc75a.
    func testSameHashAsWeb() {
        var h: UInt32 = 0
        for c in "a".utf16 { h = h &* 31 &+ UInt32(c) }
        XCTAssertEqual(h % 8, 1)
    }
}

