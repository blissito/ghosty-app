import XCTest

/// Tomas GUIONADAS para video (no son pruebas de recorrido): cada paso dura lo que dice el guion
/// y el scroll llega exacto a su destino, nunca a ciegas. Se graban con
/// `xcrun simctl io booted recordVideo` mientras corren.
///
/// - `testToma115Building`: pestaña Fábrica (1.5 s) → #115 (2 s en la barra y «@build está
///   construyendo») → un scroll exacto al plan (2 s) → regresar (1 s).
///   `TEST_RUNNER_GHOSTY_TOKEN=<bearer>`; opcional `TEST_RUNNER_FABRICA_PEDIDO=115`.
/// - `testTomaMerge`: el pedido en `pr_review` → Merge → confirmar → confeti. ⚠️ MERGEA DE VERDAD:
///   sólo corre con `TEST_RUNNER_FABRICA_MERGE=<id>` igual al pedido, y sólo cuando bliss lo decide.
final class FabricaGuionUITests: XCTestCase {

    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var pedido: String { env["FABRICA_PEDIDO"] ?? "115" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let token = env["GHOSTY_TOKEN"], !token.isEmpty else { throw XCTSkip("sin TEST_RUNNER_GHOSTY_TOKEN") }
        app = XCUIApplication()
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launchEnvironment["GHOSTY_TOKEN"] = token
        // Arranca YA en la Fábrica: ni un cuadro de Chats (conversaciones reales) en la toma.
        app.launchEnvironment["GHOSTY_TAB"] = "fabrica"
        // Fuera de cuadro lo que no es de la historia (p. ej. `business/114`).
        app.launchEnvironment["GHOSTY_FABRICA_OCULTAR"] = env["FABRICA_OCULTAR"] ?? "business/114"
    }

    private func hold(_ s: Double) { Thread.sleep(forTimeInterval: s) }

    /// Un solo arrastre lento que deja `el` a `alto` pt del borde superior. Mide antes de mover.
    private func scrollExacto(hasta el: XCUIElement, alto: CGFloat = 150) {
        let ventana = app.windows.firstMatch.frame
        let distancia = el.frame.minY - (ventana.minY + alto)
        guard distancia > 4 else { return }
        let x = ventana.midX
        let desdeY = min(ventana.maxY - 160, ventana.minY + alto + distancia)
        let origen = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: desdeY))
        let destino = origen.withOffset(CGVector(dx: 0, dy: -min(distancia, desdeY - ventana.minY - 80)))
        origen.press(forDuration: 0.05, thenDragTo: destino, withVelocity: .slow, thenHoldForDuration: 0.25)
    }

    func testToma115Building() {
        app.launch()
        // (a) La pestaña con la lista asentada.
        let fila = app.buttons["pedido-\(pedido)"]
        XCTAssertTrue(fila.waitForExistence(timeout: 25), "no está el #\(pedido) en la lista")
        hold(1.5)

        // (b) El pedido: barra de pasos y quién trabaja.
        fila.tap()
        XCTAssertTrue(app.staticTexts["pedido-titulo"].waitForExistence(timeout: 5))
        // Quien tenga la estafeta hoy (@build construye, @check revisa, @plan planea).
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'construyendo' OR label CONTAINS 'revisando' OR label CONTAINS 'escribiendo'")).firstMatch
            .waitForExistence(timeout: 15), "no dice quién trabaja en el pedido")
        hold(2.0)

        // (c) Se abre el plan y UN scroll exacto lo deja arriba (medido, no a ciegas: si ya
        //     cabe, no se mueve).
        let plan = app.buttons["plan-encabezado"]
        XCTAssertTrue(plan.waitForExistence(timeout: 10), "no llegó el plan")
        plan.tap()
        hold(0.6)
        scrollExacto(hasta: plan, alto: 110)
        hold(2.0)

        // (d) De vuelta a la lista.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(fila.waitForExistence(timeout: 5))
        hold(1.0)
    }

    func testTomaMerge() throws {
        guard env["FABRICA_MERGE"] == pedido else {
            throw XCTSkip("mergea de verdad: sólo con TEST_RUNNER_FABRICA_MERGE=\(pedido)")
        }
        app.launchEnvironment["GHOSTY_FABRICA"] = "business/\(pedido)"
        app.launch()
        let merge = app.buttons["merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 25), "el #\(pedido) no está en pr_review (sin botón Merge)")
        hold(2.0)
        merge.tap()
        let confirmar = app.buttons["confirmar-merge"]
        XCTAssertTrue(confirmar.waitForExistence(timeout: 3))
        hold(1.2)
        confirmar.tap()
        XCTAssertTrue(app.otherElements["aviso-pedido"].waitForExistence(timeout: 20)
                      || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Merge'")).firstMatch.exists,
                      "no confirmó el merge")
        hold(3.0)
    }
}
