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

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dev-run-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "la lista no enseña ningún pendiente")
        row.tap()
        Thread.sleep(forTimeInterval: 5)
        shot("d3-conversacion")
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
}
