import XCTest
@testable import GhostyCore

/// Los avisos de Teams abrían un chat vacío (1-nov): gs manda ahora el destino como `link`, con el
/// mismo formato que escribe `app/lib/push/factory-link.ts`. Si estos strings cambian, cambian allá.
final class GhostyLinkTests: XCTestCase {
    func testFactoryRunMatchesGs() {
        let link = GhostyLink(string: "com.fixtergeek.ghostyapp://pedido?espacio=business&id=96")
        XCTAssertEqual(link, .factoryRun(space: "business", id: 96))
        XCTAssertEqual(link?.factorySpace, "business")
    }

    func testFactoryThreadMatchesGs() {
        let link = GhostyLink(string: "com.fixtergeek.ghostyapp://factory-thread?space=business&room=denik&thread=812")
        XCTAssertEqual(link, .factoryThread(space: "business", room: "denik", thread: 812))
    }

    func testRoundTrip() {
        let all: [GhostyLink] = [
            .conversation(agent: "cmu7", session: "20260926_4"),
            .shared(id: "abc"),
            .factoryRun(space: "business", id: 96),
            .factoryThread(space: "business", room: "denik", thread: 812),
        ]
        for link in all { XCTAssertEqual(GhostyLink(url: link.url), link) }
    }

    func testRejectsForeignOrIncomplete() {
        XCTAssertNil(GhostyLink(string: "https://business.teams.ghosty.studio/c/denik?thread=812"))
        XCTAssertNil(GhostyLink(string: "com.fixtergeek.ghostyapp://factory-thread?space=business&room=denik"))
        XCTAssertNil(GhostyLink(string: "com.fixtergeek.ghostyapp://pedido?espacio=&id=3"))
        XCTAssertNil(GhostyLink(string: nil))
        XCTAssertNil(GhostyLink.conversation(agent: "a", session: "s").factorySpace)
    }
}
