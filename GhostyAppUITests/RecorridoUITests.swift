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

    /// La pantalla de entrar: lo primero que ve un revisor. Tiene que decir qué es esto y
    /// ofrecer las tres vías (Apple, Google, correo).
    func testLogin() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO"] = nil
        app.launchEnvironment["GHOSTY_SIN_SESION"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Tu agente, en tu bolsillo."].waitForExistence(timeout: 3),
                      "no salió la pantalla de entrar")
        XCTAssertTrue(app.staticTexts["Necesitas una cuenta de ghosty.studio."].exists,
                      "el login no dice que hace falta cuenta")
        XCTAssertTrue(app.buttons["Continuar con Google"].exists, "falta el botón de Google")
        XCTAssertTrue(app.buttons["Continuar con Apple"].exists, "falta el botón de Apple")
        foto("00-login")
    }

    /// El botón de detener del compositor. Va aparte porque necesita la app arrancada con
    /// un turno vivo, y el recorrido normal no lo tiene.
    /// Mandar con el teclado abierto: el mensaje sube hasta arriba y la respuesta crece
    /// debajo (como Claude). Se fotografía con el teclado recién cerrado, que es cuando
    /// el alto visible cambia y el aire de abajo se recalcula.
    func testMandarSubeElMensaje() {
        XCTAssertTrue(app.staticTexts["Ghosty"].waitForExistence(timeout: 10))
        let campo = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(campo.waitForExistence(timeout: 3), "no hay campo de mensaje")
        campo.tap()
        campo.typeText("investiga qué es Clay")
        app.buttons["enviar"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.9)
        foto("50-mandado")
        let mio = app.staticTexts["investiga qué es Clay"].firstMatch
        XCTAssertTrue(mio.waitForExistence(timeout: 3))
        // Arriba del todo: justo bajo la cabecera (que acaba hacia y≈100 en puntos) y
        // nunca tapado por ella.
        let y = mio.frame.minY
        XCTAssertTrue(y > 90 && y < 160, "el mensaje mandado quedó en y=\(y), no pegado arriba")
        Thread.sleep(forTimeInterval: 9)
        foto("51-respondido")
    }

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
        let cartel = app.staticTexts["Sigo con esto. Te aviso en cuanto termine."]
        XCTAssertTrue(cartel.waitForExistence(timeout: 10),
                      "no salió el cartel del turno interrumpido")
        foto("22-interrumpido")
        // Y en la lista tiene que verse igual de tranquilo: gris, no rojo de fallo.
        app.buttons["tab-conversations"].tap()
        XCTAssertTrue(app.staticTexts["Sigo trabajando · te aviso"]
                        .waitForExistence(timeout: 5),
                      "la lista no dice que el hilo sigue en el agente")
        foto("23-interrumpido-lista")
    }

    /// El filtro por tipo de Artefactos.
    ///
    /// ⚠️ Esta pantalla se dio por hecha dos veces —el filtro se escribió, se perdió en un
    /// script a medias, y se volvió a escribir— sin que nadie la mirara. Ahora se mira.
    /// Tocar un aviso con la app CERRADA: el destino llega antes de que exista nada y
    /// tiene que aplicarse igual, en la pestaña de chat y en ESA conversación.
    func testAvisoEnFrio() {
        app.terminate()
        app.launchEnvironment["GHOSTY_TAB"] = "artifacts"
        app.launchEnvironment["GHOSTY_AVISO"] = "demo-2/s-vivo"
        app.launch()
        XCTAssertTrue(app.staticTexts["resume el trimestre"].waitForExistence(timeout: 10),
                      "el aviso no llevó a la conversación de Nube")
        XCTAssertTrue(app.staticTexts["Nube"].exists, "el aviso no cambió de agente")
        foto("40-aviso-en-frio")
    }

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

        // 1. Nueva conversación desde la cabecera: tiene que dejarte en un hilo vacío.
        app.buttons["nueva-conversacion-cabecera"].tap()
        XCTAssertTrue(app.staticTexts["¿En qué te ayudo?"].waitForExistence(timeout: 3),
                      "el chip de nueva conversación no abrió un hilo vacío")
        foto("02-nueva-desde-cabecera")

        // 2. La hoja del agente y sus paneles.
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ghosty' OR label CONTAINS 'Nube'"))
            .firstMatch.tap()
        foto("03-hoja")

        app.buttons["cerrar-hoja"].firstMatch.tap()

        // 3. La pestaña de conversaciones: la lista de verdad. Tocar una tiene que
        //    llevarme a ella — es el toque que antes no funcionaba.
        app.buttons["tab-conversations"].tap()
        foto("04-conversaciones")

        // La del informe (larga): la primera fila ahora es la vacía que se acaba de crear.
        let fila = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'conversacion-' AND label CONTAINS 'El informe'")).firstMatch
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
        // Con la animación terminada: fotografiar a media bajada enseña el último mensaje
        // cortado y parece un fallo de layout que no es.
        Thread.sleep(forTimeInterval: 1.0)
        foto("07-tras-bajar")
        // ⚠️ Que el botón se esconda no prueba nada: se esconde al tocarlo. Lo que prueba
        // que bajó es que la ÚLTIMA respuesta esté en pantalla.
        let ultima = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Respuesta 12.'")).firstMatch
        XCTAssertTrue(ultima.exists && ultima.isHittable, "el botón de ir abajo no bajó al último mensaje")
        XCTAssertFalse(bajar.exists, "el botón de ir abajo sigue tras bajar")

        // 4-bis. Copiar la última respuesta: el botón tiene que estar y confirmar.
        let copiar = app.buttons.matching(identifier: "copiar-respuesta").allElementsBoundByIndex
            .last { $0.isHittable }
        XCTAssertNotNil(copiar, "no hay botón de copiar bajo la respuesta")
        copiar?.tap()
        XCTAssertTrue(app.buttons["Copiado"].waitForExistence(timeout: 2),
                      "copiar la respuesta no confirmó nada")
        foto("07-bis-copiado")

        // 4a. Las fuentes de la última respuesta: la barra tiene que estar Y tiene que
        //     abrir la hoja. Una barra que no abre nada es el fallo de siempre.
        let fuentes = app.buttons["barra-de-fuentes"].firstMatch
        XCTAssertTrue(fuentes.waitForExistence(timeout: 3), "no se pintó la barra de fuentes")
        fuentes.tap()
        XCTAssertTrue(app.staticTexts["causo.io"].waitForExistence(timeout: 3),
                      "la barra de fuentes no abrió la hoja")
        foto("07a-fuentes")
        app.buttons["Cerrar"].firstMatch.tap()

        // 4b. La conversación con foto: imagen de markdown y tarjeta de entrega. Aquí es
        //     donde se ve si una imagen grande respeta el ancho de la burbuja.
        // Se llega por la lista (la barra de chips ya no existe).
        app.buttons["tab-conversations"].tap()
        let conFoto = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'conversacion-' AND label CONTAINS 'solo me interesa'")).firstMatch
        XCTAssertTrue(conFoto.waitForExistence(timeout: 3), "no está la conversación con foto")
        if conFoto.exists {
            conFoto.tap()
            XCTAssertTrue(app.buttons["adjuntar"].waitForExistence(timeout: 3))
            foto("07b-conversacion-con-imagen")

            // Tocar una imagen de la respuesta tiene que abrirla a pantalla completa.
            // La imagen grande de la respuesta: la más alta de la pantalla.
            let todas = app.images
            let imagen = (0..<todas.count).map { todas.element(boundBy: $0) }
                .filter { $0.frame.height > 100 }
                .max { $0.frame.height < $1.frame.height }
            if let imagen, imagen.exists, imagen.isHittable {
                imagen.tap()
                // Con la presentación terminada: tocar ✕ a media animación se pierde.
                XCTAssertTrue(app.buttons["cerrar-visor"].waitForExistence(timeout: 3))
                Thread.sleep(forTimeInterval: 0.8)
                foto("07c-imagen-abierta")
                app.buttons["cerrar-visor"].firstMatch.tap()
                XCTAssertTrue(app.buttons["cerrar-visor"].waitForNonExistence(timeout: 3), "el visor no cerró")
            }
            // La nota de voz (` ```eb-audio `) sale como reproductor y play la baja y la
            // reproduce: antes era JSON crudo, y un mp3 por URL decía «No tengo el audio».
            // Con el visor ya cerrado del todo: tocar mientras se va aterrizaba en la
            // tarjeta de la imagen y volvía a abrirlo.
            Thread.sleep(forTimeInterval: 0.8)
            let play = app.buttons["reproducir-audio"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 3), "la nota de voz no salió como reproductor")
            play.tap()
            Thread.sleep(forTimeInterval: 1.0)
            foto("07d-nota-de-voz")
            XCTAssertEqual(play.label, "Pausar", "play no puso a sonar la nota de voz")
            XCTAssertFalse(app.staticTexts["Ese enlace ya no sirve."].exists, "la nota de voz no se pudo bajar")
            XCTAssertFalse(app.staticTexts["No pude reproducirlo."].exists, "la nota de voz no sonó")
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

        app.buttons["tab-conversations"].tap()
        // Sin teclado: si queda abierto empuja el popover y tapa media pantalla.
        if app.keyboards.count > 0 { app.swipeDown() }

        // 6a. Deslizar una conversación: asoma «Borrar» y pide confirmación. Se cancela,
        // para que el borrado de verdad (6b) siga yendo por el toque largo y queden
        // cubiertos los dos caminos.
        // Por nombre, no por posición: el recorrido ya creó conversaciones nuevas (sin
        // sesión) y ésas van primero.
        let paraDeslizar = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'conversacion-' AND label CONTAINS 'solo me interesa'")).firstMatch
        if paraDeslizar.exists {
            paraDeslizar.swipeLeft()
            let rojo = app.buttons["borrar-deslizado"].firstMatch
            XCTAssertTrue(rojo.waitForExistence(timeout: 3), "deslizar no descubrió el botón de borrar")
            foto("11a-deslizado")
            rojo.tap()
            XCTAssertTrue(app.staticTexts["Se borra también de tu agente. No se puede deshacer."]
                            .waitForExistence(timeout: 3), "el botón rojo no pidió confirmación")
            foto("11b-deslizado-confirmar")
            // El «Cancelar» de un confirmationDialog no siempre entra en la jerarquía de
            // accesibilidad: tocar fuera lo cierra igual.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            Thread.sleep(forTimeInterval: 0.8)
        }

        // 6a2. Toque largo → «Renombrar»: el campo, guardar, y el nombre nuevo en la fila.
        let paraNombrar = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'conversacion-' AND label CONTAINS 'El informe'")).firstMatch
        if paraNombrar.exists {
            paraNombrar.press(forDuration: 1.1)
            let renombrar = app.buttons["Renombrar"].firstMatch
            XCTAssertTrue(renombrar.waitForExistence(timeout: 3), "el toque largo no ofreció renombrar")
            renombrar.tap()
            let campo = app.textFields.firstMatch
            XCTAssertTrue(campo.waitForExistence(timeout: 3), "renombrar no abrió el campo")
            campo.tap()
            // Viene con el nombre actual: se borra tecleando retrocesos.
            let actual = (campo.value as? String) ?? ""
            campo.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: actual.count))
            campo.typeText("Lista del súper")
            foto("11c-renombrar")
            app.buttons["Guardar"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Lista del súper"].waitForExistence(timeout: 3),
                          "el nombre nuevo no apareció en la lista")
            foto("11d-renombrada")
        }

        // 6b. Toque largo sobre una conversación: menú y confirmación de borrado.
        let paraBorrar = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'conversacion-' AND label CONTAINS 'solo me interesa'")).firstMatch
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

        // 8. Borrar la cuenta EXISTE y pide confirmación (Apple 5.1.1). Se cancela: en demo
        //    no hay red y no hay cuenta que borrar.
        let cuenta = app.buttons["cuenta"].firstMatch
        XCTAssertTrue(cuenta.waitForExistence(timeout: 3), "no está el botón de cuenta")
        cuenta.tap()
        let borrarCuenta = app.buttons["borrar-cuenta"].firstMatch
        XCTAssertTrue(borrarCuenta.waitForExistence(timeout: 3), "no está «Borrar mi cuenta» en Ajustes")
        app.swipeUp()
        borrarCuenta.tap()
        // El botón rojo de confirmar es la prueba de que se pidió confirmación. Se cierra
        // sin tocarlo: con «Cancelar» si el diálogo lo trae (hoja) o tocando fuera (popover).
        let confirmar = app.buttons.matching(NSPredicate(format: "label == 'Borrar mi cuenta'")).allElementsBoundByIndex
        XCTAssertTrue(confirmar.count >= 2 || app.buttons["Cancelar"].exists, "borrar la cuenta no pidió confirmación")
        foto("15-borrar-cuenta")
        let cancelar = app.buttons["Cancelar"].firstMatch
        if cancelar.exists { cancelar.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap() }
    }
}

extension RecorridoUITests {
    /// El agente trabajando desde OTRA superficie (la Mac, la web).
    ///
    /// ⚠️ Es el fallo que originó esto: llegaban los push de las respuestas y la lista
    /// seguía diciendo «En reposo», porque el estado salía de los turnos que había abierto
    /// ESTE teléfono. Un test que sólo compilara no lo habría visto nunca.
    func testTrabajoRemoto() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchEnvironment["GHOSTY_DEMO_REMOTO"] = "1"
        app.launchEnvironment["GHOSTY_TAB"] = "conversations"
        app.launch()

        // 1. La cabecera del agente lo dice, aunque el turno no lo abrimos aquí.
        // ⚠️ El permiso GANA sobre el trabajo: es lo único detenido esperándote, y ahora
        // también cuenta el que se pidió desde otra superficie.
        let estado = app.staticTexts["estado-demo-1"]
        XCTAssertTrue(estado.waitForExistence(timeout: 5), "no se pintó el estado del agente")
        XCTAssertTrue(estado.label.contains("visto bueno"),
                      "un permiso pedido desde otro lado no sale en la lista: «\(estado.label)»")
        foto("20-estado-remoto")

        // 2. Las guardadas: la que corre dice «Trabajando…» y la que lleva tres horas
        //    muda NO — si no, la lista miente toda la tarde.
        app.buttons["guardadas-demo-1"].tap()
        XCTAssertTrue(app.staticTexts["Trabajando…"].waitForExistence(timeout: 3),
                      "la conversación que sí corre no dice que trabaja")
        let sinNoticias = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Sin noticias'")).firstMatch
        XCTAssertTrue(sinNoticias.exists, "el turno mudo de hace tres horas sigue diciendo que trabaja")
        let permiso = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Espera tu visto bueno'")).firstMatch
        XCTAssertTrue(permiso.exists, "la conversación detenida por un permiso no lo dice")
        foto("21-guardadas-remotas")
    }

    /// El indicador entre una herramienta y la siguiente, y al volver de otra pestaña.
    ///
    /// ⚠️ Es el fallo que reportó Héctor: el `.typing` lo borraba la primera herramienta y
    /// lo que quedaba sólo salía mientras una herramienta estaba literalmente corriendo.
    /// En el hueco —el modelo pensando, que es donde más se tarda— la pantalla parecía
    /// terminada, y volver de otra pestaña además tiraba el aire que sube tu pregunta.
    func testSigueTrabajandoEntreHerramientas() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchEnvironment["GHOSTY_DEMO_HERRAMIENTAS"] = "1"
        app.launch()

        let pensando = app.descendants(matching: .any).matching(identifier: "pensando").firstMatch
        XCTAssertTrue(pensando.waitForExistence(timeout: 5),
                      "sin herramienta corriendo no queda ningún indicador de carga")
        foto("24-entre-herramientas")

        // Y al volver de otra pestaña: el indicador sigue y la pregunta sigue arriba.
        app.buttons["tab-artifacts"].tap()
        app.buttons["tab-chat"].tap()
        XCTAssertTrue(pensando.waitForExistence(timeout: 5),
                      "al volver al chat se perdió el indicador de carga")
        foto("25-de-vuelta-al-chat")
    }

    /// Mandarle algo MÁS mientras trabaja, sin detenerlo.
    func testMandarMientrasTrabaja() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchEnvironment["GHOSTY_DEMO_STEER"] = "acp"
        app.launch()

        let campo = app.textFields.firstMatch
        XCTAssertTrue(campo.waitForExistence(timeout: 5), "no hay compositor")
        // Con el campo VACÍO y el agente trabajando, el control es detener.
        XCTAssertTrue(app.buttons["detener"].exists, "con el campo vacío falta el detener")
        campo.tap()
        campo.typeText("mejor el de marzo")
        // Y en cuanto escribes, ese mismo sitio pasa a mandar: un solo control.
        let enviar = app.windows.firstMatch.buttons["enviar"]
        XCTAssertTrue(enviar.waitForExistence(timeout: 2),
                      "con el agente trabajando no se puede mandar nada")
        XCTAssertFalse(app.buttons["detener"].exists,
                       "con texto escrito no debería quedar el botón de detener")
        foto("26-mandar-mientras-trabaja")
        enviar.tap()
        XCTAssertTrue(app.staticTexts["añadido a lo que está haciendo"].waitForExistence(timeout: 3),
                      "no se dice que el mensaje entró en el turno en marcha")
        foto("27-steer-hecho")
    }

    /// Y con un agente que NO sabe steerear: se avisa antes de tirarle el trabajo.
    func testMandarleAUnAgenteQueNoSteerea() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchEnvironment["GHOSTY_DEMO_STEER"] = "nativo"
        app.launch()

        let campo = app.textFields.firstMatch
        XCTAssertTrue(campo.waitForExistence(timeout: 5), "no hay compositor")
        campo.tap()
        campo.typeText("mejor el de marzo")
        app.windows.firstMatch.buttons["enviar"].tap()
        XCTAssertTrue(app.buttons["Mandar y empezar de nuevo"].waitForExistence(timeout: 3),
                      "se le tiró el trabajo al agente sin avisar")
        foto("28-aviso-de-corte")
        // ⚠️ El botón de cancelar lo LOCALIZA iOS por su cuenta (rol `.cancel`), así que
        // su texto depende del idioma del teléfono: se busca por rol, no por palabra.
        let cancelar = app.buttons.matching(
            NSPredicate(format: "label IN {'Cancelar', 'Cancel'}")).firstMatch
        XCTAssertTrue(cancelar.exists, "el aviso no ofrece salida")
        cancelar.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3),
                      "cancelar no devolvió al compositor")
    }

    func testVisorCierra() {
        XCTAssertTrue(app.staticTexts["Ghosty"].waitForExistence(timeout: 10))
        app.buttons["tab-conversations"].tap()
        let fila = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'conversacion-' AND label CONTAINS 'solo me interesa'")).firstMatch
        XCTAssertTrue(fila.waitForExistence(timeout: 3)); fila.tap()
        XCTAssertTrue(app.buttons["adjuntar"].waitForExistence(timeout: 3))
        let todas = app.images
        let imagen = (0..<todas.count).map { todas.element(boundBy: $0) }
            .filter { $0.frame.height > 100 }.max { $0.frame.height < $1.frame.height }!
        imagen.tap()
        XCTAssertTrue(app.buttons["cerrar-visor"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.8)
        app.buttons["cerrar-visor"].firstMatch.tap()
        let cerrado = app.buttons["cerrar-visor"].waitForNonExistence(timeout: 3)
        foto("60-tras-cerrar-visor")
        XCTAssertTrue(cerrado, "el visor no cerró")
    }
}
