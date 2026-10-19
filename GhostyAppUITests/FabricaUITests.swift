import XCTest

/// La fábrica como pestaña: barra → lista → pedido (push) → de vuelta. Toca de verdad (la regla de
/// esta app: un toque que no hace nada tiene que salir rojo).
///
/// - `testFabricaDemo`: modo demo, sin red (corre en `capturas.sh`).
/// - `testFabricaEnVivo`: contra gs con `TEST_RUNNER_GHOSTY_TOKEN=<bearer>` (y opcional
///   `TEST_RUNNER_FABRICA_PEDIDO=114`). Sólo mira y navega: NUNCA firma, mergea ni pide cambios.
///   Va lento a propósito: sirve también para grabar el simulador.
final class FabricaUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launchEnvironment["GHOSTY_TAB"] = "chat"
    }

    private func foto(_ nombre: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = nombre
        a.lifetime = .keepAlways
        add(a)
    }

    private func recorrer(pedido: String, pausa: Double, accion: String, confirmarYCancelar: Bool = false) {
        let pestana = app.buttons["tab-fabrica"]
        // La pestaña nace cuando gs contesta que hay pedidos.
        XCTAssertTrue(pestana.waitForExistence(timeout: 20), "no apareció la pestaña «Fábrica»")
        Thread.sleep(forTimeInterval: pausa)
        foto("f1-chats")
        pestana.tap()

        let fila = app.buttons["pedido-\(pedido)"]
        XCTAssertTrue(fila.waitForExistence(timeout: 15), "la lista no enseña el pedido #\(pedido)")
        Thread.sleep(forTimeInterval: pausa + 0.6)
        foto("f2-lista")
        fila.tap()

        XCTAssertTrue(app.staticTexts["pedido-titulo"].waitForExistence(timeout: 5), "tocar el pedido no abrió su detalle")
        XCTAssertTrue(app.buttons[accion].waitForExistence(timeout: 15), "no salió el botón «\(accion)»")
        XCTAssertFalse(pestana.exists, "la barra sigue encima del pedido")
        Thread.sleep(forTimeInterval: pausa + 0.8)
        foto("f3-pedido")
        if confirmarYCancelar {
            app.buttons[accion].tap()
            XCTAssertTrue(app.buttons["confirmar-cancelar"].waitForExistence(timeout: 3), "«\(accion)» no pidió confirmar")
            foto("f3b-confirmar")
            app.buttons["confirmar-cancelar"].tap()
            XCTAssertTrue(app.buttons["confirmar-cancelar"].waitForNonExistence(timeout: 3), "Cancelar no cerró la hoja")
        }

        // Leer lo que encontró @check / el plan, despacio.
        for i in 0..<3 {
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: pausa)
            if i == 1 { foto("f4-hallazgos") }
        }
        foto("f5-bitacora")
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: pausa)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(fila.waitForExistence(timeout: 5), "la flecha no regresó a la lista")
        XCTAssertTrue(pestana.waitForExistence(timeout: 3), "la barra no volvió al salir del pedido")
        Thread.sleep(forTimeInterval: pausa + 0.5)
        foto("f6-de-vuelta")
    }

    func testFabricaDemo() {
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launch()
        recorrer(pedido: "41", pausa: 0.3, accion: "otra-vuelta", confirmarYCancelar: true)
    }

    func testFabricaEnVivo() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["GHOSTY_TOKEN"], !token.isEmpty else {
            throw XCTSkip("sin TEST_RUNNER_GHOSTY_TOKEN")
        }
        app.launchEnvironment["GHOSTY_TOKEN"] = token
        app.launch()
        recorrer(pedido: env["FABRICA_PEDIDO"] ?? "114", pausa: 1.6, accion: "otra-vuelta")
    }
}
