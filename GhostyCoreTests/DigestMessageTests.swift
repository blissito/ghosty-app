import XCTest
@testable import GhostyCore

/// El brief de la mañana como lo escribe gs (`renderDigestMessage`), con y sin audio.
final class DigestMessageTests: XCTestCase {
    private let footer = "¿Te sirve? [Sí](https://www.ghosty.studio/brief/r/abc.DEF-1?a=yes) · [No](https://www.ghosty.studio/brief/r/abc.DEF-1?a=no) · [Ya no me lo mandes](https://www.ghosty.studio/brief/r/abc.DEF-1?a=off)"

    func testFormaDeGs() throws {
        let text = "---\n*☀️ Brief de la mañana · lunes 2 de noviembre*\n\n**2 cosas en curso**\n\n- uno\n- dos\n\n" + footer
        let d = try XCTUnwrap(DigestMessage.split(text))
        XCTAssertEqual(d.dateLabel, "lunes 2 de noviembre")
        XCTAssertEqual(d.token, "abc.DEF-1")
        XCTAssertEqual(d.body, "**2 cosas en curso**\n\n- uno\n- dos")
    }

    /// Sin `---`, con el audio ya sacado por `BloqueEbFile` (renglones vacíos) y sin selector de variación.
    func testSinRayaYConHuecoDelAudio() throws {
        let text = "*☀ Brief de la mañana · 3 nov*\n\n\n\n**Nada urgente**\n- uno\n" + footer + "\n"
        let d = try XCTUnwrap(DigestMessage.split(text))
        XCTAssertEqual(d.dateLabel, "3 nov")
        XCTAssertEqual(d.body, "**Nada urgente**\n- uno")
        XCTAssertEqual(d.token, "abc.DEF-1")
    }

    func testConAudioSeQuitaComoEntrega() throws {
        let text = "*☀️ Brief de la mañana · hoy*\n```eb-audio\n{\"url\":\"https://x/a.mp3\",\"mime\":\"audio/mpeg\"}\n```\n**Hola**\n" + footer
        var visible = text
        let found = BloqueEbFile.buscar(text, agentID: "a", sesionID: "s")
        XCTAssertEqual(found.count, 1)
        for h in found.reversed() { visible.removeSubrange(h.rango) }
        let d = try XCTUnwrap(DigestMessage.split(visible))
        XCTAssertEqual(d.body, "**Hola**")
    }

    func testOtroMensajeNoEsBrief() {
        XCTAssertNil(DigestMessage.split("Hola, ¿qué tal?"))
        XCTAssertNil(DigestMessage.split("---\n*Terminó «x» · 8:12 a. m.*\n\nlisto"))
    }

    func testVistaPrevia() {
        let text = "---\n*☀️ Brief de la mañana · hoy*\n\n**2 cosas**\n" + footer
        XCTAssertEqual(DigestMessage.preview(text), "☀️ Brief de la mañana · hoy\n**2 cosas**")
    }

    func testPatchSoloLoQueCambio() {
        var b = DailyDigest()
        b.voice = false
        let p = DailyDigest.patch(from: DailyDigest(), to: b)
        XCTAssertEqual(p["voice"] as? Bool, false)
        XCTAssertNil(p["enabled"])
        XCTAssertNotNil(p["timeZone"])
    }
}
