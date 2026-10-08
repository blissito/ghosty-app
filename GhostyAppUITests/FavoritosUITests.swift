import XCTest

/// Favoritos: un solo store para la lista y el chat. Marcar en el chat sale en la lista;
/// quitar en la lista se ve en el chat; y el PRIMER toque sirve (antes cada vista tenía
/// su copia y el chat ni siquiera marcaba sin sesión).
final class FavoritosUITests: XCTestCase {
    func testChatYListaComparten() {
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchArguments += ["-ai.consentGiven", "YES", "-app.chats.favoritas", "()"]
        app.launch()

        let fila = app.staticTexts["solo me interesa la foto"].firstMatch
        XCTAssertTrue(fila.waitForExistence(timeout: 8))
        fila.tap()
        // La estrella vive en el menú «⋯» de la cabecera.
        let mas = app.buttons["hilo-mas"]
        let estrella = app.buttons["hilo-favorito"]
        XCTAssertTrue(mas.waitForExistence(timeout: 4), "no está el menú del chat")
        mas.tap()
        XCTAssertTrue(estrella.waitForExistence(timeout: 2), "no está la estrella en el menú")
        XCTAssertEqual(estrella.label, "Agregar a favoritos")
        estrella.tap()
        mas.tap()
        XCTAssertEqual(estrella.label, "Quitar de favoritos", "el primer toque en el chat no marcó")
        foto(app, "f1-chat-marcado")
        app.tap() // cierra el menú

        app.buttons["volver-a-chats"].tap()
        XCTAssertTrue(app.images["Favorito"].firstMatch.waitForExistence(timeout: 3), "la lista no muestra la ★")
        foto(app, "f2-lista-con-estrella")

        // Quitar desde la lista (modo selección) y verlo en el chat.
        fila.press(forDuration: 0.6)
        let quitar = app.buttons["Quitar de favoritos"].firstMatch
        XCTAssertTrue(quitar.waitForExistence(timeout: 3), "la selección no ofrece quitar")
        quitar.tap()
        XCTAssertTrue(app.images["Favorito"].firstMatch.waitForNonExistence(timeout: 3), "la ★ siguió en la lista")
        fila.tap()
        XCTAssertTrue(mas.waitForExistence(timeout: 4))
        mas.tap()
        XCTAssertTrue(estrella.waitForExistence(timeout: 2))
        XCTAssertEqual(estrella.label, "Agregar a favoritos", "el chat no vio que se quitó en la lista")
        foto(app, "f3-chat-sin-estrella")
    }

    /// Lista recién abierta, sin favoritos: el PRIMER toque en ★ de la selección marca.
    func testPrimerToqueEnLaListaMarca() {
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchArguments += ["-ai.consentGiven", "YES", "-app.chats.favoritas", "()"]
        app.launch()

        let fila = app.staticTexts["solo me interesa la foto"].firstMatch
        XCTAssertTrue(fila.waitForExistence(timeout: 8))
        XCTAssertFalse(app.images["Favorito"].firstMatch.exists, "arrancó con favoritos")
        fila.press(forDuration: 0.6)
        let agregar = app.buttons["Agregar a favoritos"].firstMatch
        XCTAssertTrue(agregar.waitForExistence(timeout: 3))
        XCTAssertTrue(agregar.isEnabled, "la fila no quedó elegida tras el toque largo")
        agregar.tap()
        XCTAssertTrue(app.images["Favorito"].firstMatch.waitForExistence(timeout: 3),
                      "el primer toque en ★ no marcó")
        foto(app, "f4-primer-toque-lista")
    }

    private func foto(_ app: XCUIApplication, _ nombre: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = nombre
        a.lifetime = .keepAlways
        add(a)
    }
}
