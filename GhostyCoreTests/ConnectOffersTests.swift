import XCTest
@testable import GhostyCore

final class ConnectOffersTests: XCTestCase {
    func testQuitaLaMarcaYDaElId() {
        let r = ConnectOffers.extract("Necesito tu GitHub.\n\n```gs_connect github\n```")
        XCTAssertEqual(r.ids, ["github"])
        XCTAssertEqual(r.rest, "Necesito tu GitHub.")
    }

    func testVariasSinRepetirYEnOrden() {
        let r = ConnectOffers.extract("```gs_connect github\n```\nHola\n```gs_connect stripe```\n```gs_connect github\n```")
        XCTAssertEqual(r.ids, ["github", "stripe"])
        XCTAssertEqual(r.rest, "Hola")
    }

    func testSinMarcaNoToca() {
        let t = "Texto con ```código```"
        XCTAssertEqual(ConnectOffers.extract(t).ids, [])
        XCTAssertEqual(ConnectOffers.extract(t).rest, t)
    }

    func testAMediasNoSeQuita() {
        // Todavía llegando: sin cierre no hay tarjeta.
        XCTAssertEqual(ConnectOffers.extract("Va\n```gs_connect github").ids, [])
    }
}
