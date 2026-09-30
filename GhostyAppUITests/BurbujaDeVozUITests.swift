import XCTest

/// Fotografía las notas de voz (la tuya y la del agente) para revisar su diseño.
final class BurbujaDeVozUITests: XCTestCase {
    func testFoto() {
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launch()
        let fila = app.staticTexts["solo me interesa la foto"].firstMatch
        XCTAssertTrue(fila.waitForExistence(timeout: 8))
        fila.tap()
        Thread.sleep(forTimeInterval: 1)
        for _ in 0..<14 { app.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 0.6)
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.lifetime = .keepAlways; add(a)
    }
}
