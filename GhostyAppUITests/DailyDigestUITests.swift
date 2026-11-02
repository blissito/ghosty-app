import XCTest

/// El brief de la mañana: el renglón de Perfil con su panel (prendido, «Con voz», hora y días) y el
/// mensaje en el hilo (etiqueta ámbar, audio aparte y pie de un toque). Todo en demo, sin red.
final class DailyDigestUITests: XCTestCase {

    private func launch(brief: Bool = false, principal: Bool = false) -> XCUIApplication {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        if principal { app.launchEnvironment["GHOSTY_DEMO_PRINCIPAL"] = "1" }
        if brief { app.launchEnvironment["GHOSTY_DEMO_BRIEF"] = "1" }
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

    /// Perfil dice la hora; el panel enseña «Con voz», hora y días, y apagarlo los esconde.
    func testPanelDelBrief() {
        let app = launch()
        app.buttons["tab-perfil"].tap()
        let renglon = app.buttons["ajuste-brief-manana"].firstMatch
        XCTAssertTrue(renglon.waitForExistence(timeout: 5), "no está el renglón del brief en Perfil")
        app.swipeUp()
        XCTAssertTrue(renglon.label.contains("7:30"), "Perfil no dice la hora: \(renglon.label)")
        renglon.tap()
        let toggle = app.switches["brief-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "el panel del brief no abrió")
        XCTAssertTrue(app.switches["brief-voz"].exists, "falta «Con voz»")
        XCTAssertEqual(app.switches["brief-voz"].value as? String, "1", "«Con voz» debería venir prendido")
        foto(app, "brief-1-panel")
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.switches["brief-voz"].waitForNonExistence(timeout: 3), "apagarlo no escondió las opciones")
        app.buttons["brief-listo"].tap()
        XCTAssertTrue(renglon.waitForExistence(timeout: 3))
        XCTAssertTrue(renglon.label.contains("Apagado"), "Perfil no dice «Apagado»: \(renglon.label)")
    }

    /// Agente principal: Perfil lo dice, cambiarlo pasa por la advertencia y Perfil se entera.
    func testAgentePrincipalConAdvertencia() {
        let app = launch(principal: true)
        app.buttons["tab-perfil"].tap()
        let renglon = app.buttons["ajuste-agente-principal"].firstMatch
        XCTAssertTrue(renglon.waitForExistence(timeout: 5), "no está «Agente principal» en Perfil")
        // Queda debajo de la barra de pestañas aunque XCUI lo dé por tocable: subir siempre.
        app.swipeUp()
        XCTAssertTrue(renglon.label.contains("Ghosty"), "el principal de la demo debería ser Ghosty: \(renglon.label)")
        renglon.tap()
        let otro = app.buttons["principal-demo-3"]
        XCTAssertTrue(otro.waitForExistence(timeout: 3), "la lista de agentes no abrió")
        XCTAssertTrue(app.staticTexts["agente-principal-insignia"].exists || app.otherElements["agente-principal-insignia"].exists
                      || app.descendants(matching: .any)["agente-principal-insignia"].exists, "falta la insignia «Principal»")
        foto(app, "principal-1-lista")
        otro.tap()
        XCTAssertTrue(app.buttons["principal-confirmar"].waitForExistence(timeout: 3), "no salió la advertencia")
        foto(app, "principal-2-advertencia")
        app.buttons["principal-cancelar"].tap()
        XCTAssertTrue(otro.waitForExistence(timeout: 3), "«Cancelar» no regresó a la lista")
        otro.tap()
        app.buttons["principal-confirmar"].tap()
        XCTAssertTrue(app.buttons["principal-confirmar"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(renglon.waitForExistence(timeout: 3))
        XCTAssertTrue(renglon.label.contains("Luna"), "Perfil no dice el nuevo principal: \(renglon.label)")
    }

    /// El brief en el hilo: etiqueta, audio con reproductor y «Ya no me lo mandes» sin salir del chat.
    func testBriefEnElHilo() {
        let app = launch(brief: true)
        let fila = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'h-demo-1-' AND label BEGINSWITH 'Pendientes de hoy'")).firstMatch
        XCTAssertTrue(fila.waitForExistence(timeout: 10), "no está el hilo del brief en Chats")
        fila.tap()
        XCTAssertTrue(app.buttons["volver-a-chats"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)

        XCTAssertTrue(app.descendants(matching: .any)["digest-label"].waitForExistence(timeout: 3), "falta la etiqueta del brief")
        XCTAssertTrue((app.buttons["voz-play"].firstMatch.exists || app.buttons["reproducir-audio"].firstMatch.exists), "falta el reproductor del audio")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '/brief/r/'")).firstMatch.exists,
                       "el pie salió como ligas crudas")
        XCTAssertFalse(app.staticTexts["3 fuentes"].exists, "las ligas del pie salieron como fuentes")
        foto(app, "brief-2-hilo")

        let off = app.buttons["digest-off"]
        XCTAssertTrue(off.waitForExistence(timeout: 3), "falta «Ya no me lo mandes»")
        off.tap()
        XCTAssertTrue(app.buttons["digest-on"].waitForExistence(timeout: 3), "no salió «Volver a prenderlo»")
        XCTAssertTrue(app.buttons["volver-a-chats"].exists, "el pie sacó de la conversación")
        foto(app, "brief-3-apagado")
        app.buttons["digest-on"].tap()
        XCTAssertTrue(app.staticTexts["Listo, mañana te llega otra vez."].waitForExistence(timeout: 3))
    }
}
