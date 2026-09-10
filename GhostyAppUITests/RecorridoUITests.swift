import XCTest

/// Un recorrido que TOCA la app y la fotografía en cada paso.
///
/// ⚠️ No busca aserciones finas: busca que un toque haga algo y que la pantalla se vea
/// bien. Los fallos que ha tenido esta app no eran de lógica —eran filas que no respondían
/// al toque, un botón que no bajaba, una conversación duplicada— y ninguno lo habría
/// cazado un test unitario. Las capturas se vuelcan a `build-sim/capturas/` para poder
/// mirarlas antes de instalar nada en un teléfono.
final class RecorridoUITests: XCTestCase {

    private var app: XCUIApplication!
    /// Dónde se dejan las capturas para poder abrirlas fuera de Xcode.
    private lazy var carpeta: URL = {
        let d = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GHOSTY_CAPTURAS"]
                    ?? NSTemporaryDirectory() + "capturas")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launch()
    }

    private func foto(_ nombre: String) {
        let img = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: img)
        a.name = nombre
        a.lifetime = .keepAlways
        add(a)
        try? img.pngRepresentation.write(to: carpeta.appending(path: "\(nombre).png"))
    }

    func testRecorrido() {
        XCTAssertTrue(app.staticTexts["Ghosty"].waitForExistence(timeout: 10), "la app no arrancó en la demo")
        foto("01-chat")

        // 1. El chip de otra conversación tiene que llevarme a ella.
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chip-'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "no salió ningún chip de conversación viva")
        chip.tap()
        foto("02-chip-otro-agente")

        // 2. La hoja del agente y sus paneles.
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ghosty' OR label CONTAINS 'Nube'"))
            .firstMatch.tap()
        foto("03-hoja")

        app.buttons["cerrar-hoja"].firstMatch.tap()

        // 3. La pestaña de conversaciones: la lista de verdad. Tocar una tiene que
        //    llevarme a ella — es el toque que antes no funcionaba.
        app.buttons["tab-conversations"].tap()
        foto("04-conversaciones")

        let fila = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'conversacion-'")).firstMatch
        XCTAssertTrue(fila.waitForExistence(timeout: 3), "no se pintó la lista de conversaciones")
        fila.tap()
        XCTAssertTrue(app.buttons["adjuntar"].waitForExistence(timeout: 3),
                      "tocar una conversación no llevó al chat")
        foto("05-tras-tocar-conversacion")

        // 4. El botón de ir abajo: subir en el hilo y comprobar que aparece y que baja.
        app.swipeDown(); app.swipeDown()
        foto("06-arriba-del-hilo")
        let bajar = app.buttons["ir-abajo"]
        XCTAssertTrue(bajar.waitForExistence(timeout: 3), "el botón de ir abajo no apareció al subir")
        bajar.tap()
        foto("07-tras-bajar")

        // 4b. La conversación con foto: imagen de markdown y tarjeta de entrega. Aquí es
        //     donde se ve si una imagen grande respeta el ancho de la burbuja.
        let conFoto = app.buttons.matching(NSPredicate(format: "label CONTAINS 'solo me interesa'")).firstMatch
        if conFoto.waitForExistence(timeout: 3) {
            conFoto.tap()
            foto("07b-conversacion-con-imagen")
        }

        // 5. El adjuntador de tres tarjetas.
        let mas = app.buttons["adjuntar"]
        XCTAssertTrue(mas.waitForExistence(timeout: 3), "no encontré el botón de adjuntar")
        mas.tap()
        foto("08-adjuntar")
        XCTAssertTrue(app.buttons["adjuntar-Cámara"].exists, "no salieron las tres tarjetas")
        mas.tap()

        // 6. Pedirle algo sin entrar a la conversación.
        app.buttons["tab-conversations"].tap()
        let pedir = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'pedir-'")).firstMatch
        XCTAssertTrue(pedir.waitForExistence(timeout: 3), "no salió el campo de pedir")
        pedir.tap()
        pedir.typeText("hola")
        foto("09-pidele-algo")

        // 7. Y que «Guardadas» se despliegue sólo cuando se toca.
        let guardadas = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guardadas-'")).firstMatch
        XCTAssertTrue(guardadas.exists, "no salió el plegable de guardadas")
        guardadas.tap()
        foto("10-guardadas")
    }
}
