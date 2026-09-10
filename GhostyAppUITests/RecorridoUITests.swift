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

        // 2. La hoja del agente y su historial.
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ghosty' OR label CONTAINS 'Nube'"))
            .firstMatch.tap()
        foto("03-hoja")

        let historial = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Historial'")).firstMatch
        if historial.waitForExistence(timeout: 3) { historial.tap() }
        foto("04-historial")

        // 3. Una conversación abierta: tocarla tiene que hacer algo. Éste es el toque que
        //    no funcionaba por tener un botón dentro de otro.
        // Se toca por su TEXTO, como lo haría una persona: un identificador puesto en un
        // contenedor de SwiftUI no siempre se expone como elemento.
        let fila = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'informe'")).firstMatch
        XCTAssertTrue(fila.waitForExistence(timeout: 3), "no se pintaron las conversaciones abiertas")
        fila.tap()
        foto("05-tras-tocar-abierta")
        // Tocar una conversación tiene que cerrar la hoja y llevarme a ella.
        XCTAssertFalse(app.staticTexts["Abiertas"].exists, "la hoja no se cerró al tocar la conversación")

        // 4. El botón de ir abajo: subir en el hilo y comprobar que aparece y que baja.
        app.swipeDown(); app.swipeDown()
        foto("06-arriba-del-hilo")
        let bajar = app.buttons["ir-abajo"]
        XCTAssertTrue(bajar.waitForExistence(timeout: 3), "el botón de ir abajo no apareció al subir")
        bajar.tap()
        foto("07-tras-bajar")

        // 5. El adjuntador de tres tarjetas.
        let mas = app.buttons["adjuntar"]
        XCTAssertTrue(mas.waitForExistence(timeout: 3), "no encontré el botón de adjuntar")
        mas.tap()
        foto("08-adjuntar")
        XCTAssertTrue(app.buttons["adjuntar-Cámara"].exists, "no salieron las tres tarjetas")
        mas.tap()

        // 6. La flota, con su campo de pedir.
        app.buttons["tab-fleet"].tap()
        foto("09-flota")

        // 7. Y que el campo de "pídele algo" acepte texto.
        let pedir = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'pedir-'")).firstMatch
        XCTAssertTrue(pedir.waitForExistence(timeout: 3), "no salió el campo de pedir en la flota")
        pedir.tap()
        pedir.typeText("hola")
        foto("10-flota-escribiendo")
    }
}
