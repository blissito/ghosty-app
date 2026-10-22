import XCTest

/// El resumen de la mañana: la oferta de Chats, el renglón de Perfil con su hoja y el hilo con
/// tarjetas, 👍/👎 y la barra «Escúchalo · Ajustar · Apagar». Todo en demo, sin red.
final class MorningBriefUITests: XCTestCase {

    private func launch(_ resumen: String) -> XCUIApplication {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchEnvironment["GHOSTY_DEMO_RESUMEN"] = resumen
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launch()
        return app
    }

    private func foto(_ app: XCUIApplication, _ nombre: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = nombre
        a.lifetime = .keepAlways
        add(a)
    }

    /// La oferta sale arriba de Chats; «Ahora no» la quita y no vuelve.
    func testOfertaResumen() {
        let app = launch("oferta")
        let oferta = app.otherElements["resumen-oferta"]
        XCTAssertTrue(oferta.waitForExistence(timeout: 10), "no salió la oferta del resumen en Chats")
        foto(app, "resumen-1-oferta")
        app.buttons["resumen-oferta-no"].tap()
        XCTAssertTrue(oferta.waitForNonExistence(timeout: 3), "«Ahora no» no quitó la oferta")
    }

    /// «Sí, a las 8» lo prende y Perfil lo dice.
    func testOfertaSiPrendeYPerfilLoDice() {
        let app = launch("oferta")
        let si = app.buttons["resumen-oferta-si"]
        XCTAssertTrue(si.waitForExistence(timeout: 10))
        si.tap()
        XCTAssertTrue(app.otherElements["resumen-oferta"].waitForNonExistence(timeout: 3))
        app.buttons["tab-perfil"].tap()
        let renglon = app.buttons["ajuste-resumen-manana"].firstMatch
        XCTAssertTrue(renglon.waitForExistence(timeout: 3), "no está el renglón del resumen en Perfil")
        for _ in 0..<4 where !renglon.isHittable { app.swipeUp() }
        XCTAssertTrue(renglon.label.contains("8:00"), "Perfil no dice la hora: \(renglon.label)")
        renglon.tap()
        let toggle = app.switches["resumen-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "la hoja del resumen no abrió")
        XCTAssertTrue(app.buttons["resumen-probar"].exists, "falta «Probar ahora» con el resumen prendido")
        foto(app, "resumen-2-ajustes")
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["resumen-probar"].waitForNonExistence(timeout: 3), "apagarlo no escondió las opciones")
        app.buttons["resumen-listo"].tap()
        XCTAssertTrue(renglon.waitForExistence(timeout: 3))
        XCTAssertTrue(renglon.label.contains("Apagado"), "Perfil no dice «Apagado»: \(renglon.label)")
    }

    /// El hilo del resumen: barra con audio, tarjetas con 👍 que se queda y «Apagar».
    func testResumenDemo() {
        let app = launch("1")
        let fila = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'h-demo-1-' AND label BEGINSWITH 'Resumen de la mañana'")).firstMatch
        XCTAssertTrue(fila.waitForExistence(timeout: 10), "no está «Resumen de la mañana» en Chats")
        fila.tap()
        XCTAssertTrue(app.buttons["volver-a-chats"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)

        XCTAssertTrue(app.buttons["resumen-ajustar"].waitForExistence(timeout: 3), "falta la barra del resumen")
        XCTAssertTrue(app.buttons["reproducir-audio"].firstMatch.exists, "falta «Escúchalo»")
        XCTAssertTrue(app.otherElements["resumen-tarjeta-0"].exists || app.staticTexts["Laura pidió la cotización con IVA"].exists,
                      "las tarjetas no se pintaron")
        XCTAssertTrue(app.staticTexts["resumen-fin"].exists, "falta «Eso es todo por hoy»")
        foto(app, "resumen-3-hilo")

        let up = app.buttons["resumen-up-0"]
        XCTAssertTrue(up.waitForExistence(timeout: 3))
        up.tap()
        XCTAssertEqual(up.value as? String, "seleccionado", "el 👍 de la tarjeta no se quedó")

        app.buttons["resumen-apagar"].tap()
        XCTAssertTrue(app.buttons["resumen-prender"].waitForExistence(timeout: 3), "«Apagar» no lo apagó")
        foto(app, "resumen-4-apagado")
    }
}
