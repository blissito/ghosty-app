import XCTest
@testable import GhostyCore

final class ThreadMergeTests: XCTestCase {
    private func user(_ id: String, _ text: String, seq: Int? = nil, turn: String? = nil) -> Message {
        Message(id: id, kind: .user(text), seq: seq, turnId: turn)
    }
    private func agent(_ id: String, _ text: String, seq: Int? = nil, turn: String? = nil) -> Message {
        Message(id: id, kind: .agent(text: text, tools: nil, trailing: nil), seq: seq, turnId: turn)
    }
    private func texts(_ list: [Message]) -> [String] {
        list.map { m in
            switch m.kind {
            case .user(let t, _, _): return "u:\(t)"
            case .agent(let t, _, _): return "a:\(t)"
            default: return "?"
            }
        }
    }

    func testFreshPageIntoEmptyThread() {
        let page = [user("s1", "hola", seq: 1, turn: "t1"), agent("s2", "qué tal", seq: 2, turn: "t1")]
        XCTAssertEqual(texts(ThreadMerge.merge([], with: page)), ["u:hola", "a:qué tal"])
    }

    func testSamePageTwiceIsIdempotent() {
        let page = [user("s1", "hola", seq: 1), agent("s2", "qué tal", seq: 2)]
        let once = ThreadMerge.merge([], with: page)
        XCTAssertEqual(ThreadMerge.merge(once, with: page), once)
    }

    /// El bug del 8-oct: una copia pedida ANTES de mandar llega después y no trae tu mensaje.
    func testStaleCopyDoesNotDropPendingMessage() {
        let local = [user("s1", "hola", seq: 1), agent("s2", "qué tal", seq: 2),
                     user("local-uuid", "nuevo", turn: "t9")]
        let stale = [user("s1", "hola", seq: 1), agent("s2", "qué tal", seq: 2)]
        let merged = ThreadMerge.merge(local, with: stale)
        XCTAssertEqual(texts(merged), ["u:hola", "a:qué tal", "u:nuevo"])
        XCTAssertEqual(merged.last?.id, "local-uuid")
    }

    func testOptimisticAdoptsSeqAndKeepsViewId() {
        let local = [user("s1", "hola", seq: 1), user("local-uuid", "nuevo", turn: "t9")]
        let page = [user("s3", "nuevo", seq: 3, turn: "t9"), agent("s4", "listo", seq: 4, turn: "t9")]
        let merged = ThreadMerge.merge(local, with: page)
        XCTAssertEqual(merged.map(\.id), ["s1", "local-uuid", "s4"])
        XCTAssertEqual(merged[1].seq, 3)
    }

    func testLiveTurnBubbleIsNotOverwritten() {
        let local = [user("u", "nuevo", turn: "t9"), agent("turno-t9", "escribiendo más", turn: "t9")]
        let page = [user("s3", "nuevo", seq: 3, turn: "t9"), agent("s4", "escri", seq: 4, turn: "t9")]
        let merged = ThreadMerge.merge(local, with: page, liveTurnId: "t9")
        XCTAssertEqual(texts(merged), ["u:nuevo", "a:escribiendo más"])
        XCTAssertEqual(merged[1].id, "turno-t9")
    }

    func testOlderPageGoesOnTop() {
        let local = [user("s5", "c", seq: 5), agent("s6", "d", seq: 6)]
        let older = [user("s3", "a", seq: 3), agent("s4", "b", seq: 4)]
        XCTAssertEqual(texts(ThreadMerge.merge(local, with: older)), ["u:a", "a:b", "u:c", "a:d"])
    }

    func testLocalDeliveryStaysInPlace() {
        let entrega = Message(id: "entrega-x", kind: .sistema("archivo"))
        let local = [user("s1", "hola", seq: 1), entrega]
        let merged = ThreadMerge.merge(local, with: [agent("s2", "va", seq: 2)])
        XCTAssertEqual(merged.map(\.id), ["s1", "entrega-x", "s2"])
    }

    func testDeletedSeqIsRemoved() {
        let local = [user("s1", "hola", seq: 1), agent("s2", "va", seq: 2)]
        XCTAssertEqual(ThreadMerge.merge(local, with: [], deleted: [2]).map(\.id), ["s1"])
    }

    func testUpdatedTextKeepsLocalTools() {
        let run = ToolRun(herramientas: [])
        let local = [Message(id: "s2", kind: .agent(text: "par", tools: run, trailing: nil), seq: 2)]
        let merged = ThreadMerge.merge(local, with: [agent("s2", "parcial completo", seq: 2)])
        guard case .agent(let t, let tools, _) = merged[0].kind else { return XCTFail() }
        XCTAssertEqual(t, "parcial completo")
        XCTAssertNotNil(tools)
    }
}

final class ThreadMergePendingTests: XCTestCase {
    func testSteerWithoutKnownTurnIsAdoptedByText() {
        let local = [Message(id: "s1", kind: .user("hola"), seq: 1),
                     Message(id: "local", kind: .user("y también esto", steer: true), turnId: "pending-x")]
        let page = [Message(id: "s2", kind: .user("y también esto"), seq: 2, turnId: "t2")]
        let merged = ThreadMerge.merge(local, with: page)
        XCTAssertEqual(merged.map(\.id), ["s1", "local"])
        XCTAssertEqual(merged[1].seq, 2)
        guard case .user(_, _, let steer) = merged[1].kind else { return XCTFail() }
        XCTAssertTrue(steer)
    }
}

final class ThreadMergeSteerTests: XCTestCase {
    /// gs guarda el steer con el turno VIVO, no con el del POST: no debe duplicarse.
    func testSteerSavedWithLiveTurnIsNotDuplicated() {
        let local = [Message(id: "u1", kind: .user("haz esto"), seq: 1, turnId: "t1"),
                     Message(id: "steer", kind: .user("y también aquello", steer: true), turnId: "t2-post")]
        let page = [Message(id: "s2", kind: .user("y también aquello"), seq: 2, turnId: "t1")]
        let merged = ThreadMerge.merge(local, with: page)
        XCTAssertEqual(merged.map(\.id), ["u1", "steer"])
        XCTAssertEqual(merged[1].seq, 2)
    }
}

