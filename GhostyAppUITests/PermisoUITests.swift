import XCTest

/// La tarjeta del permiso en el chat: contestarla tiene que quitarla.
final class PermisoUITests: XCTestCase {
    func testContestarQuitaLaTarjeta() {
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchEnvironment["GHOSTY_AVISO"] = "demo-1/s-foto"
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launch()
        let si = app.buttons["Sí, dale"]
        XCTAssertTrue(si.waitForExistence(timeout: 5), "no salió la tarjeta del permiso")
        si.tap()
        XCTAssertTrue(si.waitForNonExistence(timeout: 3), "contesté y la tarjeta sigue ahí")
    }
}

final class PermisoSoloEnSuHiloUITests: XCTestCase {
    /// En otra conversación del mismo agente la tarjeta NO sale.
    func testNoSaleEnOtraConversacion() {
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchEnvironment["GHOSTY_AVISO"] = "demo-1/s-larga"
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launch()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5) || app.textViews.firstMatch.exists)
        XCTAssertFalse(app.buttons["Sí, dale"].waitForExistence(timeout: 2), "el permiso de otra conversación salió aquí")
    }
}
