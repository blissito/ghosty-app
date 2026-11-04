import XCTest
@testable import GhostyCore

/// `liveUrl` de `GET /me/files` (gs 57df0a37): el index de un sitio publicado se abre vivo
/// y no como copia. Ver `Delivery.liveURL` y `HTMLViewer`.
final class LiveURLTests: XCTestCase {
    private func parse(_ json: String) throws -> [GhostyAPI.ArchivoDeSesion] {
        try XCTUnwrap(GhostyAPI.parsearArchivos(Data(json.utf8)))
    }

    func testArriba() throws {
        let f = try parse(#"{"files":[{"id":"a","name":"index.html","mime":"text/html","size":10,"liveUrl":"https://barberia-el-filo-reservas.ghosty.page"}]}"#)
        XCTAssertEqual(f.first?.liveURL, "https://barberia-el-filo-reservas.ghosty.page")
        XCTAssertEqual(Delivery.fromAccountFile(f[0]).liveURL, "https://barberia-el-filo-reservas.ghosty.page")
    }

    func testEnMeta() throws {
        let meta = #"{\"origen\":\"agente\",\"liveUrl\":\"https://x.ghosty.page\"}"#
        let f = try parse(#"{"files":[{"id":"a","name":"index.html","mime":"text/html","size":10,"meta":""# + meta + #""}]}"#)
        XCTAssertEqual(f.first?.liveURL, "https://x.ghosty.page")
    }

    func testSinLiveUrl() throws {
        let f = try parse(#"{"files":[{"id":"a","name":"foto.png","mime":"image/png","size":10}]}"#)
        XCTAssertNil(f.first?.liveURL)
    }

    /// Se guarda y vuelve; y un `entregas.json` viejo (sin la llave) se sigue leyendo.
    func testCodable() throws {
        var e = Delivery(id: "x", agentID: "a", forma: .archivo, title: "index.html", receivedAt: Date(timeIntervalSince1970: 0))
        e.liveURL = "https://x.ghosty.page"
        let data = try JSONEncoder().encode(e)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("liveUrl"))
        XCTAssertEqual(try JSONDecoder().decode(Delivery.self, from: data).liveURL, "https://x.ghosty.page")

        let viejo = #"{"id":"x","agentID":"a","forma":"archivo","titulo":"t","recibida":0}"#
        XCTAssertNil(try JSONDecoder().decode(Delivery.self, from: Data(viejo.utf8)).liveURL)
    }

    /// Un ```eb-file``` cuya `url` YA es la página publicada se abre viva; una liga firmada no.
    func testLivePageDeEbFile() {
        var viva = Delivery(id: "v", agentID: "a", forma: .archivo, title: "Reservas", receivedAt: Date(),
                            url: "https://barberia-el-filo-reservas.ghosty.page/")
        viva.mime = "text/html"
        XCTAssertEqual(viva.livePage?.host, "barberia-el-filo-reservas.ghosty.page")

        var firmada = viva
        firmada.url = "https://bucket.example.com/index.html?X-Amz-Signature=abc"
        XCTAssertNil(firmada.livePage)

        var foto = viva
        foto.mime = "image/png"
        XCTAssertNil(foto.livePage)
    }
}
