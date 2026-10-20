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

    /// `accion` nil = el pedido real puede estar en cualquier etapa: sólo se exige su detalle
    /// (el botón depende del estado que tenga hoy, y la prueba en vivo no lo controla).
    private func recorrer(pedido: String, pausa: Double, accion: String?, confirmarYCancelar: Bool = false) {
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
        if let accion {
            XCTAssertTrue(app.buttons[accion].waitForExistence(timeout: 15), "no salió el botón «\(accion)»")
        } else {
            XCTAssertTrue(app.buttons["plan-encabezado"].waitForExistence(timeout: 15), "el detalle no trae el plan")
        }
        XCTAssertFalse(pestana.exists, "la barra sigue encima del pedido")
        Thread.sleep(forTimeInterval: pausa + 0.8)
        foto("f3-pedido")
        if confirmarYCancelar, let accion {
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

    /// Escalado → «¿Qué hago?» → la recomendación con la nota editable → «Aplicar» decide.
    func testQueHagoDemo() {
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launch()
        let pestana = app.buttons["tab-fabrica"]
        XCTAssertTrue(pestana.waitForExistence(timeout: 20), "no apareció la pestaña «Fábrica»")
        pestana.tap()
        let fila = app.buttons["pedido-41"]
        XCTAssertTrue(fila.waitForExistence(timeout: 15), "la lista no enseña el pedido escalado")
        fila.tap()

        let queHago = app.buttons["que-hago"]
        if !queHago.waitForExistence(timeout: 5) || !queHago.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(queHago.waitForExistence(timeout: 5), "el escalado no trae «¿Qué hago?»")
        queHago.tap()
        XCTAssertTrue(app.staticTexts["recomendacion"].waitForExistence(timeout: 5), "«¿Qué hago?» no enseñó la recomendación")
        XCTAssertTrue(app.textViews["nota-recomendada"].exists, "la nota no se puede editar")
        foto("q1-recomendacion")
        app.buttons["aplicar"].tap()
        XCTAssertTrue(app.staticTexts["recomendacion"].waitForNonExistence(timeout: 3), "«Aplicar» no cerró la hoja")
        XCTAssertTrue(app.otherElements["aviso-pedido"].waitForExistence(timeout: 3) || app.staticTexts["Listo (demo)"].exists,
                      "«Aplicar» no decidió nada")
        foto("q2-aplicado")
    }

    /// El #40 con @build a media vuelta: lo que hace ahora, los últimos pasos, «Ver todo» y el atasco
    /// dentro de la tarjeta; en la bitácora, la nota firmada y ningún tipo crudo («stuck notified»).
    func testPedidoTrabajandoDemo() {
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launch()
        let pestana = app.buttons["tab-fabrica"]
        XCTAssertTrue(pestana.waitForExistence(timeout: 20), "no apareció la pestaña «Fábrica»")
        pestana.tap()
        let fila = app.buttons["pedido-40"]
        XCTAssertTrue(fila.waitForExistence(timeout: 15), "la lista no enseña el pedido en construcción")
        // Va abajo de la lista: la barra de pestañas lo tapa aunque XCUITest lo dé por tocable.
        app.swipeUp(velocity: .slow)
        fila.tap()

        let ahora = app.descendants(matching: .any)["paso-ahora"]
        XCTAssertTrue(ahora.waitForExistence(timeout: 5), "no se ve qué hace @build ahora")
        XCTAssertTrue(ahora.label.contains("npm install"), "la línea de ahora no dice el comando: \(ahora.label)")
        XCTAssertTrue(app.descendants(matching: .any)["atasco"].exists, "el atasco no sale en la tarjeta")
        foto("v1-en-vivo")

        let verTodo = app.buttons["ver-todos-los-pasos"]
        XCTAssertTrue(verTodo.exists, "no hay «Ver todo»")
        verTodo.tap()
        XCTAssertTrue(app.buttons["cerrar-pasos"].waitForExistence(timeout: 3), "«Ver todo» no abrió los pasos")
        XCTAssertTrue(app.staticTexts["Repasé mi guía · factory build"].exists, "la hoja no trae el primer paso")
        foto("v2-todos-los-pasos")
        app.buttons["cerrar-pasos"].tap()

        app.swipeUp(velocity: .slow)
        XCTAssertTrue(app.buttons["nota-firmada"].waitForExistence(timeout: 3), "la nota firmada no sale en la bitácora")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'stuck'")).firstMatch.exists,
                       "la bitácora enseña un tipo crudo")
        foto("v3-bitacora")
    }

    /// Abrir el #40 (trabajando) prende su Live Activity: al ir al inicio se ve en la Dynamic Island.
    func testLiveActivityDemo() {
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launch()
        let pestana = app.buttons["tab-fabrica"]
        XCTAssertTrue(pestana.waitForExistence(timeout: 20), "no apareció la pestaña «Fábrica»")
        pestana.tap()
        let fila = app.buttons["pedido-40"]
        XCTAssertTrue(fila.waitForExistence(timeout: 15))
        app.swipeUp(velocity: .slow)
        fila.tap()
        XCTAssertTrue(app.descendants(matching: .any)["paso-ahora"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        sleep(3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let shot = XCTAttachment(screenshot: springboard.screenshot())
        shot.name = "la1-isla"
        shot.lifetime = .keepAlways
        add(shot)
        // La pantalla de bloqueo: bajar el centro de notificaciones desde arriba.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.001))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
        sleep(2)
        let lock = XCTAttachment(screenshot: springboard.screenshot())
        lock.name = "la2-bloqueo"
        lock.lifetime = .keepAlways
        add(lock)
    }

    func testFabricaEnVivo() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["GHOSTY_TOKEN"], !token.isEmpty else {
            throw XCTSkip("sin TEST_RUNNER_GHOSTY_TOKEN")
        }
        app.launchEnvironment["GHOSTY_TOKEN"] = token
        app.launch()
        // La acción sólo se exige si quien corre la prueba dice en qué etapa está su pedido.
        recorrer(pedido: env["FABRICA_PEDIDO"] ?? "114", pausa: 1.6, accion: env["FABRICA_ACCION"])
    }
}
