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


final class HelpersFoldTests: XCTestCase {
    func testTwoWakesBeforeNextUserMessageBecomeOne() {
        let msgs = [
            Message(id: "u", kind: .user("lanza dos")),
            Message(id: "w1", kind: .agent(text: "---\n*Terminó «A» · 9:00*\n\nuno", tools: nil, trailing: nil)),
            Message(id: "w2", kind: .agent(text: "---\n*Terminó «B» · 9:01*\n\ndos", tools: nil, trailing: nil)),
            Message(id: "u2", kind: .user("gracias")),
        ]
        let folded = HelpersHeader.fold(msgs)
        XCTAssertEqual(folded.map(\.id), ["u", "w2", "u2"])
        guard case .agent(let t, _, _) = folded[1].kind else { return XCTFail() }
        XCTAssertEqual(HelpersHeader.split(t)?.header.titles, ["A", "B"])
        XCTAssertEqual(HelpersHeader.split(t)?.rest, "dos")
    }
    func testPreviewDropsHeader() {
        XCTAssertEqual(HelpersHeader.stripped("---\n*Resumen · 9:58 a.m.*\n\nListo todo"), "Listo todo")
    }
}
