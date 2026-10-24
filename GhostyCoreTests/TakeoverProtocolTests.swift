import XCTest
@testable import GhostyCore

/// Los mismos casos que `~/ghosty-studio/packages/computer/src/computer.test.ts` («protocol: …»):
/// si el contrato cambia allá y no aquí, esto se pone rojo.
final class TakeoverProtocolTests: XCTestCase {
    private func json(_ s: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) }

    func testIdaYVueltaConservaElEvento() {
        let ev = HumanInput.mouse(.down, x: 10, y: 20, clickCount: 2)
        XCTAssertEqual(HumanInput.decode(ev.encoded()), ev)
        XCTAssertEqual(HumanInput.decode(#"{"type":"key","key":"Shift+ArrowUp"}"#), .key("Shift+ArrowUp"))
    }

    func testNormalizaCoordenadasTopesYClickCount() {
        XCTAssertEqual(HumanInput.normalize(json(#"{"type":"mouse","action":"up","x":10.6,"y":-4}"#)),
                       .mouse(.up, x: 11, y: 0, clickCount: 1))
        XCTAssertEqual(HumanInput.normalize(json(#"{"type":"mouse","action":"move","x":1,"y":2,"clickCount":3}"#)),
                       .mouse(.move, x: 1, y: 2))
        XCTAssertEqual(HumanInput.normalize(json(#"{"type":"mouse","action":"down","x":1,"y":1,"clickCount":9}"#)),
                       .mouse(.down, x: 1, y: 1, clickCount: 3))
        guard case .type(let t)? = HumanInput.normalize(["type": "type", "text": String(repeating: "a", count: 5000)]) else {
            return XCTFail("type")
        }
        XCTAssertEqual(t.count, TakeoverProtocol.Limits.text)
        XCTAssertEqual(HumanInput.normalize(json(#"{"type":"scroll","dy":-99999}"#)), .scroll(dy: -TakeoverProtocol.Limits.scroll))
    }

    func testLoQueNoCuadraSeIgnora() {
        let malos = [
            "null", #""x""#, #"{"type":"eval","code":"1"}"#, #"{"type":"mouse","action":"drag","x":1,"y":1}"#,
            #"{"type":"mouse","action":"down","x":"1","y":1}"#, #"{"type":"key","key":"Enter; rm -rf"}"#,
            #"{"type":"type","text":""}"#, #"{"type":"scroll","dy":0}"#,
        ]
        for m in malos { XCTAssertNil(HumanInput.normalize(json(m)), m) }
        // `NaN` no existe en JSON: se prueba directo (en JS es `{ type: "click", x: NaN, y: 1 }`).
        XCTAssertNil(HumanInput.normalize(["type": "click", "x": Double.nan, "y": 1]))
        XCTAssertNil(HumanInput.decode("{no es json"))
        // Un booleano no es número (en JS `typeof true` es «boolean»).
        XCTAssertNil(HumanInput.normalize(json(#"{"type":"click","x":true,"y":1}"#)))
    }

    func testLaColaCompactaMovimientosYSumaLaRueda() {
        var q: [HumanInput] = []
        q = HumanInput.enqueue(q, .mouse(.move, x: 1, y: 1))
        q = HumanInput.enqueue(q, .mouse(.move, x: 2, y: 2))
        q = HumanInput.enqueue(q, .mouse(.down, x: 2, y: 2))
        q = HumanInput.enqueue(q, .scroll(dy: 100))
        q = HumanInput.enqueue(q, .scroll(dy: 50))
        q = HumanInput.enqueue(q, .type("a"))
        q = HumanInput.enqueue(q, .type("b"))
        XCTAssertEqual(q, [.mouse(.move, x: 2, y: 2), .mouse(.down, x: 2, y: 2), .scroll(dy: 150), .type("a"), .type("b")])
    }

    /// Lo propio del teléfono: el toque y la conversión de coordenadas con zoom local.
    func testDeLaPantallaAlViewport() {
        // Página 1280×800 mostrada a 640×400 con 10 pt de margen arriba: el centro es el centro.
        let m = TakeoverGeometry(viewport: CGSize(width: 1280, height: 800), container: CGSize(width: 640, height: 420))
        XCTAssertEqual(m.toPage(CGPoint(x: 320, y: 210)), CGPoint(x: 640, y: 400))
        XCTAssertNil(m.toPage(CGPoint(x: 320, y: 5)), "fuera del video no es un clic")
        // Con zoom 2× anclado en el centro, el mismo punto sigue siendo el centro y la esquina
        // visible es un cuarto de la página.
        var z = m
        z.zoom = 2
        XCTAssertEqual(z.toPage(CGPoint(x: 320, y: 210)), CGPoint(x: 640, y: 400))
        XCTAssertEqual(z.toPage(CGPoint(x: 0, y: 10)), CGPoint(x: 320, y: 200))
        // Arrastrar el dedo 100 pt hacia arriba baja la página 200 px (la escala del video).
        XCTAssertEqual(m.scrollDelta(forDrag: -100), 200)
    }
}
