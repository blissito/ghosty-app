import XCTest

/// La pestaña «Dev» en vivo: barra → lista → pendiente → sus cuatro pestañas, con capturas.
/// Sólo mira y navega: NUNCA manda notas, hace merge ni detiene. Usa la sesión que ya tenga la app
/// (o `TEST_RUNNER_GHOSTY_TOKEN`).
final class DevUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launchEnvironment["GHOSTY_TAB"] = "dev"
        if let t = ProcessInfo.processInfo.environment["GHOSTY_TOKEN"], !t.isEmpty { app.launchEnvironment["GHOSTY_TOKEN"] = t }
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testDevLive() {
        app.launch()
        let tab = app.buttons["tab-dev"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no apareció la pestaña «Dev»")
        tab.tap()
        // «Todos» para ver también los cerrados.
        Thread.sleep(forTimeInterval: 3)
        shot("d1-lista")
        let all = app.buttons["Todos"]
        if all.exists { all.tap(); Thread.sleep(forTimeInterval: 1); shot("d2-todos") }

        // Uno con conversación larga (para probar «ir abajo»): el #139 de mailmask.
        let row = app.buttons["dev-run-cmwruyl0w09m4g868bnhazyqk"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "la lista no enseña ningún pendiente")
        row.tap()
        // Al abrir tiene que estar ya abajo: si saliera arriba, el botón «ir abajo» estaría a la vista.
        for (t, n) in [(0.6, "d3a-0.6s"), (1.4, "d3a-2s")] {
            Thread.sleep(forTimeInterval: t)
            shot(n)
        }
        XCTAssertFalse(app.buttons["ir-abajo"].exists, "la conversación abrió arriba (se ve «ir abajo»)")
        Thread.sleep(forTimeInterval: 3)
        shot("d3-conversacion")
        // Es el chat de la app: abre abajo y, al subir a releer, sale «ir abajo» y funciona.
        // Deslizar SOBRE el hilo (la mitad baja), no sobre el encabezado fijo.
        for _ in 0..<3 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        }
        Thread.sleep(forTimeInterval: 1)
        let down = app.buttons["ir-abajo"]
        XCTAssertTrue(down.waitForExistence(timeout: 5), "al subir no salió el botón para bajar")
        shot("d3b-releyendo")
        down.tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(down.exists, "el botón para bajar sigue ahí después de bajar")
        shot("d3c-abajo")

        // Volver a Conversación desde otra pestaña, y salir y volver a entrar: también abajo.
        app.buttons["Cambios"].tap(); Thread.sleep(forTimeInterval: 1)
        app.buttons["Conversación"].tap(); Thread.sleep(forTimeInterval: 2)
        shot("d3d-regreso-pestana")
        XCTAssertFalse(app.buttons["ir-abajo"].exists, "al regresar a Conversación abrió arriba")
        app.navigationBars.buttons.firstMatch.tap(); Thread.sleep(forTimeInterval: 1.5)
        row.tap(); Thread.sleep(forTimeInterval: 2.5)
        shot("d3e-reabrir")
        XCTAssertFalse(app.buttons["ir-abajo"].exists, "al reabrir el pendiente abrió arriba")
        XCTAssertFalse(tab.isHittable, "la barra sigue encima del pendiente")

        for (label, name) in [("Cambios", "d4-cambios"), ("Verificación", "d5-verificacion"), ("Actividad", "d7-actividad")] {
            let seg = app.buttons[label]
            XCTAssertTrue(seg.waitForExistence(timeout: 5), "no está la pestaña «\(label)»")
            seg.tap()
            Thread.sleep(forTimeInterval: 2)
            shot(name)
            if label == "Verificación" {
                app.swipeUp()
                Thread.sleep(forTimeInterval: 1)
                shot("d6-verificacion-abajo")
            }
        }
    }

    /// Pendientes cerrados (merge hecho y «listo · sin cambios»), abiertos directo con `GHOSTY_DEV`.
    /// Sólo mira: un cerrado no debe ofrecer Merge ni caja para escribir.
    func testDevClosed() {
        for (run, tag) in [("cmwr44fdg000vg8fabyy69225", "m"), ("cmwqrw17u001tg8nnh2dj4tsj", "n")] {
            app.launchEnvironment["GHOSTY_DEV"] = run
            app.launch()
            XCTAssertTrue(app.buttons["Conversación"].waitForExistence(timeout: 20), "no abrió el pendiente \(run)")
            Thread.sleep(forTimeInterval: 4)
            shot("c\(tag)1-conversacion")
            XCTAssertFalse(app.buttons["Merge"].exists, "un pendiente cerrado ofrece Merge")
            XCTAssertTrue(app.staticTexts["El pendiente ya cerró: aquí sólo se lee lo que habló el agente."].exists, "un pendiente cerrado ofrece la caja para escribir")
            for (label, n) in [("Cambios", 2), ("Verificación", 3), ("Actividad", 4)] {
                app.buttons[label].tap()
                Thread.sleep(forTimeInterval: 1.5)
                shot("c\(tag)\(n)-\(label)")
            }
            app.terminate()
        }
    }

    /// Tocar el aviso de un pendiente abre su detalle en Dev, no un chat nuevo.
    func testNoticeOpensRun() {
        app.launchEnvironment["GHOSTY_TAB"] = "chat"
        app.launchEnvironment["GHOSTY_NOTICE_DEVRUN"] = "cmwruyl0w09m4g868bnhazyqk"
        app.launch()
        XCTAssertTrue(app.buttons["Conversación"].waitForExistence(timeout: 20), "el aviso no abrió el pendiente")
        XCTAssertTrue(app.navigationBars["PR #139"].exists || app.staticTexts["PR #139"].exists, "abrió otro pendiente")
        Thread.sleep(forTimeInterval: 2)
        shot("n1-aviso-abre-pendiente")
    }

    /// Sin pendientes: el vacío explica qué es Dev, en «Activos» y en «Todos».
    func testDevEmpty() {
        app.launchEnvironment["GHOSTY_DEV_EMPTY"] = "1"
        app.launch()
        let tab = app.buttons["tab-dev"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "con GitHub conectado la pestaña sale aunque no haya pendientes")
        tab.tap()
        Thread.sleep(forTimeInterval: 2.5)
        shot("e1-vacio-activos")
        app.buttons["Todos"].tap()
        Thread.sleep(forTimeInterval: 1)
        shot("e2-vacio-todos")
    }

    /// Recién creado: sin PR, sin cambios. Nada de Merge; los vacíos dicen qué falta.
    func testDevFresh() {
        app.launchEnvironment["GHOSTY_DEV"] = ProcessInfo.processInfo.environment["DEV_FRESH_RUN"] ?? "cmwrzl40100qvge8aizjsko19"
        app.launch()
        XCTAssertTrue(app.buttons["Conversación"].waitForExistence(timeout: 20), "no abrió el pendiente")
        Thread.sleep(forTimeInterval: 4)
        shot("f1-conversacion")
        XCTAssertFalse(app.buttons["Merge"].exists, "sin PR no hay Merge")
        for (label, n) in [("Cambios", 2), ("Verificación", 3), ("Actividad", 4)] {
            app.buttons[label].tap()
            Thread.sleep(forTimeInterval: 1.5)
            shot("f\(n)-\(label)")
        }
    }
}
