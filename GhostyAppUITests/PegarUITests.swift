import XCTest
import UIKit

/// Pegar en el compositor VACÍO: el `TextField` vertical de SwiftUI no sacaba el menú
/// (reporte 2026-09-30). Y el teclado no puede tapar el botón de mandar.
final class PegarUITests: XCTestCase {
    func testPegarEnCampoVacio() {
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchEnvironment["GHOSTY_AVISO"] = "demo-1/s-larga"
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launch()
        UIPasteboard.general.string = "texto pegado"
        let campo = app.textViews["campo-mensaje"].firstMatch
        XCTAssertTrue(campo.waitForExistence(timeout: 6), "sin campo")
        campo.tap(); sleep(1)
        campo.tap(); sleep(1)
        let pegar = app.menuItems.matching(NSPredicate(format: "label IN {'Paste', 'Pegar'}")).firstMatch
        if !pegar.exists { campo.press(forDuration: 1.0) }
        XCTAssertTrue(pegar.waitForExistence(timeout: 3), "con el campo vacío no sale «Pegar»")
        pegar.tap()
        XCTAssertEqual(campo.value as? String, "texto pegado")
        // Con el teclado arriba, el botón de mandar se puede tocar (nada flota encima).
        let enviar = app.buttons["enviar"].firstMatch
        XCTAssertTrue(enviar.waitForExistence(timeout: 2))
        XCTAssertTrue(enviar.isHittable, "algo tapa el botón de mandar")
        XCTAssertFalse(app.buttons["Listo"].exists, "volvió la barra «Listo» sobre el teclado")
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "pegado"; s.lifetime = .keepAlways; add(s)
    }
}
