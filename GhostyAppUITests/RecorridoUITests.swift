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

    /// El botón de detener del compositor. Va aparte porque necesita la app arrancada con
    /// un turno vivo, y el recorrido normal no lo tiene.
    func testDetener() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO_TRABAJANDO"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["detener"].waitForExistence(timeout: 10),
                      "no salió el botón de detener con un turno vivo")
        foto("20-detener")
        app.buttons["detener"].tap()
        XCTAssertTrue(app.buttons["adjuntar"].waitForExistence(timeout: 3))
        foto("21-detenido")
    }

    /// El hilo que dejaste trabajando cuando iOS suspendió la app.
    ///
    /// ⚠️ Esto es lo que NO se veía nunca: el corte se clasificaba como fallo del agente y
    /// la conversación quedaba diciendo «vuelve a intentarlo» para siempre. La prueba mira
    /// que salga el cartel de que sigue trabajando, no un error.
    func testInterrumpido() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO_INTERRUMPIDO"] = "1"
        app.launch()
        let cartel = app.staticTexts["Tu agente sigue con esto. Te aviso en cuanto termine."]
        XCTAssertTrue(cartel.waitForExistence(timeout: 10),
                      "no salió el cartel del turno interrumpido")
        foto("22-interrumpido")
        // Y en la lista tiene que verse igual de tranquilo: gris, no rojo de fallo.
        app.buttons["tab-conversations"].tap()
        XCTAssertTrue(app.staticTexts["Sigue en tu agente · al volver lo traigo"]
                        .waitForExistence(timeout: 5),
                      "la lista no dice que el hilo sigue en el agente")
        foto("23-interrumpido-lista")
    }

    /// El filtro por tipo de Artefactos.
    ///
    /// ⚠️ Esta pantalla se dio por hecha dos veces —el filtro se escribió, se perdió en un
    /// script a medias, y se volvió a escribir— sin que nadie la mirara. Ahora se mira.
    func testFiltroDeArtefactos() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO_ENTREGAS"] = "1"
        app.launchEnvironment["GHOSTY_TAB"] = "artifacts"
        app.launch()
        XCTAssertTrue(app.buttons["filtro-todo"].waitForExistence(timeout: 10),
                      "no salió la barra de filtros en Artefactos")
        foto("30-artefactos")
        // Un cajón concreto: tiene que quedarse sólo con lo suyo.
        let audio = app.buttons["filtro-audio"]
        if audio.waitForExistence(timeout: 2) {
            audio.tap()
            // Con la animación TERMINADA: una foto tomada durante la transición enseña
            // fantasmas que no son un fallo, y esconde los que sí lo son.
            Thread.sleep(forTimeInterval: 1.2)
            foto("31-artefactos-audio")
        }
    }

    func testRecorrido() {
        XCTAssertTrue(app.staticTexts["Ghosty"].waitForExistence(timeout: 10), "la app no arrancó en la demo")
        foto("01-chat")

        // 1. El chip de otra conversación tiene que llevarme a ella.
        // ⚠️ El primero que se pueda TOCAR, no el primero de la lista: la barra centra la
        // conversación activa, así que los chips de su izquierda quedan fuera de pantalla.
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chip-'"))
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 3), "no salió ningún chip de conversación")
        // `isHittable` revienta con un elemento fuera de pantalla, así que se mira el marco.
        let ancho = app.frame.width
        let chip = (0..<chips.count).map { chips.element(boundBy: $0) }
            .first { $0.frame.minX >= 0 && $0.frame.maxX <= ancho }
        XCTAssertNotNil(chip, "ningún chip quedó a la vista")
        chip?.tap()
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

            // Tocar una imagen de la respuesta tiene que abrirla a pantalla completa.
            // La imagen grande de la respuesta: la más alta de la pantalla.
            let todas = app.images
            let imagen = (0..<todas.count).map { todas.element(boundBy: $0) }
                .filter { $0.frame.height > 100 }
                .max { $0.frame.height < $1.frame.height }
            if let imagen, imagen.exists, imagen.isHittable {
                imagen.tap()
                foto("07c-imagen-abierta")
                app.buttons["cerrar-visor"].firstMatch.tap()
            }
        }

        // 5. El adjuntador de tres tarjetas.
        let mas = app.buttons["adjuntar"]
        XCTAssertTrue(mas.waitForExistence(timeout: 3), "no encontré el botón de adjuntar")
        mas.tap()
        foto("08-adjuntar")
        XCTAssertTrue(app.buttons["adjuntar-Cámara"].exists, "no salieron las tres tarjetas")
        mas.tap()

        // 6. Empezar una conversación desde la lista: tiene que LLEVARTE al chat.
        app.buttons["tab-conversations"].tap()
        let nueva = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'nueva-'")).firstMatch
        XCTAssertTrue(nueva.waitForExistence(timeout: 3), "no salió el botón de nueva conversación")
        nueva.tap()
        XCTAssertTrue(app.buttons["adjuntar"].waitForExistence(timeout: 3),
                      "nueva conversación no llevó al chat")
        foto("09-nueva-conversacion")

        // 6b. Toque largo sobre una conversación: menú y confirmación de borrado.
        app.buttons["tab-conversations"].tap()
        // Sin teclado: si queda abierto empuja el popover y tapa media pantalla.
        if app.keyboards.count > 0 { app.swipeDown() }
        let paraBorrar = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'conversacion-'")).element(boundBy: 2)
        let antes = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'conversacion-'")).count
        if paraBorrar.exists {
            paraBorrar.press(forDuration: 1.1)
            foto("11-menu-borrar")
            let borrar = app.buttons["Borrar"].firstMatch
            XCTAssertTrue(borrar.waitForExistence(timeout: 3), "el toque largo no ofreció borrar")
            borrar.tap()
            foto("12-confirmar-borrado")
            // Y se borra de verdad: la captura inmediata tiene que pillar la fila A MEDIO
            // IRSE. Si sale entera o ya no sale, es que no hay animación — que es
            // justamente lo que faltaba.
            app.buttons.matching(NSPredicate(format: "label == 'Borrar'")).firstMatch.tap()
            foto("13-borrando")
            // Y de verdad tiene que haberse ido: sin esto el test pasaba con la fila
            // intacta, que fue justo lo que ocultó que se borraba el canal equivocado.
            // Se comprueba que baje el número de filas, no un texto concreto: el paso
            // anterior crea una conversación nueva y habría dos con el mismo nombre.
            let quedan = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'conversacion-'")).count
            XCTAssertLessThan(quedan, antes, "la conversación no se borró")
            foto("14-borrado")
        }

        // 7. Y que «Guardadas» se despliegue sólo cuando se toca.
        if app.keyboards.count > 0 { app.swipeDown() }
        app.buttons["tab-conversations"].tap()
        let guardadas = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guardadas-'")).firstMatch
        XCTAssertTrue(guardadas.exists, "no salió el plegable de guardadas")
        guardadas.tap()
        foto("10-guardadas")
    }
}
