import XCTest
@testable import GhostyCore

/// `intro` y `manage` de `GET /api/v2/me/connectors`: opcionales, para que un servidor
/// viejo (sin los campos) o uno que manda `null` sigan pintando la lista.
final class ConectorDecodingTests: XCTestCase {
    // Copy de GitHub sólo como dato de prueba: el de verdad lo manda gs.
    private let introGitHub: [String: Any] = [
        "title": "Conectar GitHub",
        "subtitle": "Antes de ir a GitHub, un minuto.",
        "items": [
            ["title": "Deja marcado «All repositories».", "body": "Así Ghosty crea repos para ti y trabaja en ellos. Con «Only select» puede crear el repo pero no escribir en él: tendrías que agregarlo a mano cada vez."],
            ["title": "Por qué es seguro.", "body": "Ghosty es una GitHub App con permisos fijos (código, PRs y workflows), no una llave a toda tu cuenta. Tu sesión de GitHub vive en nuestro servidor y nunca entra a la computadora del agente."],
            ["title": "Tú decides qué entra.", "body": "En repos que ya existen trabaja en una rama y te abre un PR; sólo empuja directo al publicar una app en un repo que él creó. Cada cambio queda en el historial de GitHub."],
            ["title": "Lo quitas cuando quieras.", "body": "Desde «Repos» en esta tarjeta o en GitHub → Settings → Applications."],
        ],
        "continueLabel": "Continuar a GitHub",
        "cancelLabel": "Ahora no",
    ]

    func testIntroPresente() throws {
        let c = try XCTUnwrap(Conector.desdeJSON([
            "id": "github", "name": "GitHub", "connected": true,
            "intro": introGitHub,
            "manage": ["label": "Repos", "href": "/connectors/github/repos"],
        ]))
        let intro = try XCTUnwrap(c.intro)
        XCTAssertEqual(intro.title, "Conectar GitHub")
        XCTAssertEqual(intro.subtitle, "Antes de ir a GitHub, un minuto.")
        XCTAssertEqual(intro.items.count, 4)
        XCTAssertEqual(intro.items[1].title, "Por qué es seguro.")
        XCTAssertEqual(intro.continueLabel, "Continuar a GitHub")
        XCTAssertEqual(intro.cancelLabel, "Ahora no")
        XCTAssertEqual(c.manage?.label, "Repos")
        // Relativa se resuelve contra gs; absoluta queda igual.
        XCTAssertEqual(c.manage?.url?.host, Session.base.host)
        XCTAssertTrue(c.manage?.url?.absoluteString.hasSuffix("/connectors/github/repos") ?? false)
        let abs = GestionDeConector(label: "Repos", href: "https://github.com/settings/installations")
        XCTAssertEqual(abs.url?.absoluteString, "https://github.com/settings/installations")
    }

    func testIntroNull() throws {
        let c = try XCTUnwrap(Conector.desdeJSON(["id": "github", "intro": NSNull(), "manage": NSNull()]))
        XCTAssertNil(c.intro)
        XCTAssertNil(c.manage)
    }

    func testCampoAusente() throws {
        let c = try XCTUnwrap(Conector.desdeJSON(["id": "drive", "nombre": "Drive", "conectado": false]))
        XCTAssertNil(c.intro)
        XCTAssertNil(c.manage)
        XCTAssertEqual(c.nombre, "Drive")
        XCTAssertTrue(c.disponible)
    }

    func testIntroIncompletaNoSeEnsena() throws {
        let c = try XCTUnwrap(Conector.desdeJSON(["id": "github", "intro": ["title": "x"]]))
        XCTAssertNil(c.intro)
        XCTAssertNil(Conector.desdeJSON(["name": "sin id"]))
    }
}
