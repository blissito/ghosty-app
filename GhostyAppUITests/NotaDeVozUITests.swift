import XCTest

/// Tocar ▶ en una nota de voz la hace sonar: aparece la pastilla de velocidad.
/// Existe porque «las notas de voz ya no se reproducen» (2026-09-29) no lo caza nada más.
final class NotaDeVozUITests: XCTestCase {
    func testPlaySuena() {
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launch()

        let fila = app.staticTexts["solo me interesa la foto"].firstMatch
        XCTAssertTrue(fila.waitForExistence(timeout: 8), "no está la conversación de la demo")
        fila.tap()

        let play = app.buttons["voz-play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 6), "no hay nota de voz en el hilo")
        // Queda arriba en el hilo: se baja hasta verla.
        for _ in 0..<5 where !play.isHittable { app.swipeDown() }
        let foto1 = XCUIScreen.main.screenshot()
        add(XCTAttachment(screenshot: foto1))
        play.tap()
        let velocidad = app.buttons["voz-velocidad"].firstMatch
        let sono = velocidad.waitForExistence(timeout: 6)
        let foto2 = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: foto2); a.lifetime = .keepAlways; add(a)
        try? foto2.pngRepresentation.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "nota-de-voz.png"))
        XCTAssertTrue(sono, "tocar ▶ no hizo sonar la nota")
    }
}

/// Deslizar una fila de Chats a la izquierda enseña su botón, y NO cambia de pestaña.
final class DeslizarChatUITests: XCTestCase {
    func testDeslizarFila() {
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launch()
        let fila = app.staticTexts["solo me interesa la foto"].firstMatch
        XCTAssertTrue(fila.waitForExistence(timeout: 8))
        fila.swipeLeft()
        Thread.sleep(forTimeInterval: 0.8)
        let foto = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: foto); a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(app.staticTexts["Chats"].firstMatch.exists, "el deslizar cambió de pestaña")
        // Y a la derecha: Leído/No leído y Fijar, sin irse a Archivos.
        fila.tap()   // cierra la izquierda
        Thread.sleep(forTimeInterval: 0.5)
        app.staticTexts["El informe"].firstMatch.swipeRight()
        Thread.sleep(forTimeInterval: 0.8)
        let foto2 = XCUIScreen.main.screenshot()
        let b = XCTAttachment(screenshot: foto2); b.lifetime = .keepAlways; add(b)
        XCTAssertTrue(app.buttons["Fijar"].firstMatch.exists, "no salió Fijar al deslizar a la derecha")
    }
}

/// Tocar un aviso con la app cerrada abre SU conversación (no la lista ni otra).
final class AvisoAbreConversacionUITests: XCTestCase {
    func testArranqueEnFrioPorAviso() {
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchEnvironment["GHOSTY_AVISO"] = "demo-1/s-foto"
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launch()
        let atras = app.buttons["volver-a-chats"]
        XCTAssertTrue(atras.waitForExistence(timeout: 8), "el aviso no abrió el hilo")
        let foto = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: foto); a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(app.staticTexts["solo me interesa la foto"].firstMatch.waitForExistence(timeout: 4),
                      "abrió otra conversación")
    }
}
