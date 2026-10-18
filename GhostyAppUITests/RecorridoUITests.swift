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
        // El permiso de IA de terceros, dado: el recorrido prueba el chat, no la hoja.
        app.launchArguments += ["-ai.consentGiven", "YES"]
        app.launch()
    }

    /// La fila de «Chats» de esa conversación, por su título (y su agente). Las filas son
    /// `h-<agente>-…` (abiertas en el teléfono) o `s-<agente>-…` (guardadas en la caja).
    private func filaDeChat(_ titulo: String, agente: String = "demo-1") -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "(identifier BEGINSWITH %@ OR identifier BEGINSWITH %@) AND label BEGINSWITH %@",
            "h-\(agente)-", "s-\(agente)-", titulo)).firstMatch
    }

    /// Todas las filas de «Chats», para contarlas.
    private var filasDeChats: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'h-' OR identifier BEGINSWITH 's-'"))
    }

    /// Chats es el inicio (rediseño estilo WhatsApp): para mirar un hilo hay que tocar su
    /// fila. Comprueba que el toque entró (la flecha de regreso), que es el fallo de siempre.
    private func abrirChat(_ titulo: String, agente: String = "demo-1",
                           file: StaticString = #filePath, line: UInt = #line) {
        let fila = filaDeChat(titulo, agente: agente)
        XCTAssertTrue(fila.waitForExistence(timeout: 10), "no está «\(titulo)» en Chats", file: file, line: line)
        fila.tap()
        XCTAssertTrue(app.buttons["volver-a-chats"].waitForExistence(timeout: 3),
                      "tocar «\(titulo)» no entró al hilo", file: file, line: line)
        // Con el hilo asentado: entra deslizándose y un toque a media animación se pierde.
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// La flecha del hilo: de vuelta a «Chats».
    private func volverAChats(file: StaticString = #filePath, line: UInt = #line) {
        if app.keyboards.count > 0 { app.swipeDown() }
        app.buttons["volver-a-chats"].tap()
        XCTAssertTrue(app.buttons["volver-a-chats"].waitForNonExistence(timeout: 3),
                      "la flecha no regresó a Chats", file: file, line: line)
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// «Cambiar de agente»: el avatar de la barra abre la hoja, elegir otro agente lleva
    /// a «Chats» con SUS conversaciones (su chip puesto), y el velo la cierra.
    func testCambiarDeAgente() {
        XCTAssertTrue(app.buttons["tab-agente"].waitForExistence(timeout: 10))
        // Desde otra pestaña: elegir agente tiene que traerte de vuelta a Chats.
        app.buttons["tab-memorias"].tap()
        app.buttons["tab-agente"].tap()
        XCTAssertTrue(app.staticTexts["Cambiar de agente"].waitForExistence(timeout: 3),
                      "el avatar de la barra no abrió la hoja")
        foto("60-cambiar-agente")
        let nube = app.buttons["agente-demo-2"]
        XCTAssertTrue(nube.waitForExistence(timeout: 3), "no está el otro agente en la hoja")
        nube.tap()
        XCTAssertTrue(app.staticTexts["Cambiar de agente"].waitForNonExistence(timeout: 3),
                      "elegir un agente no cerró la hoja")
        XCTAssertTrue(app.buttons["tab-chat"].waitForExistence(timeout: 3) && app.buttons["tab-chat"].isSelected,
                      "elegir un agente no llevó a Chats")
        XCTAssertTrue(app.buttons["chip-demo-2"].waitForExistence(timeout: 3) && app.buttons["chip-demo-2"].isSelected,
                      "no cambió de agente: el chip de Nube no quedó puesto")
        XCTAssertTrue(filaDeChat("resume el trimestre", agente: "demo-2").exists, "no salen las conversaciones de Nube")
        XCTAssertFalse(filaDeChat("solo me interesa la foto").exists, "siguen saliendo las conversaciones de Ghosty")
        foto("61-agente-cambiado")
        // El velo cierra.
        app.buttons["tab-agente"].tap()
        XCTAssertTrue(app.staticTexts["Cambiar de agente"].waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.staticTexts["Cambiar de agente"].waitForNonExistence(timeout: 3),
                      "tocar el velo no cerró la hoja")
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
        XCTAssertTrue(app.staticTexts["Encárgame trabajo y te lo entrego hecho."].waitForExistence(timeout: 3),
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
        abrirChat("El informe")
        let campo = app.textViews["campo-mensaje"].firstMatch
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

    /// El bug del 7-oct: si subías a releer y luego mandabas, el hilo no bajaba a tu mensaje
    /// (el arrastre apagaba «seguir el final» y el envío no lo volvía a prender).
    func testSendAfterScrollingUp() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO_CHAT"] = "1"
        app.launch()
        let field = app.textViews["campo-mensaje"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no hay campo de mensaje")
        // Subir a releer: arrastrar el hilo hacia abajo.
        let thread = app.scrollViews.firstMatch
        thread.swipeDown()
        Thread.sleep(forTimeInterval: 0.6)
        foto("52-releyendo")
        field.tap()
        field.typeText("y ahora resúmelo")
        app.buttons["enviar"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.2)
        foto("53-mandado-tras-releer")
        let mine = app.staticTexts["y ahora resúmelo"].firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 3))
        let y = mine.frame.minY
        XCTAssertTrue(y > 90 && y < 160, "tras releer, el mensaje mandado quedó en y=\(y), no pegado arriba")
    }

    /// El chip «N herramientas conectadas» abre Integraciones ENCIMA del chat: al cerrarla
    /// sigues en la conversación (antes te mandaba a Perfil, 7-oct).
    func testToolsChipKeepsYouInChat() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO_CHAT"] = "vacio"
        app.launch()
        let chip = app.buttons["chip-herramientas"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no está el chip de herramientas")
        chip.tap()
        Thread.sleep(forTimeInterval: 1.0)
        foto("54-integraciones-encima")
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 1.0)
        foto("55-de-vuelta-en-el-chat")
        XCTAssertTrue(app.textViews["campo-mensaje"].firstMatch.waitForExistence(timeout: 3),
                      "al cerrar Integraciones ya no estás en el chat")
    }

    func testDetener() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO_TRABAJANDO"] = "1"
        app.launch()
        abrirChat("El informe")
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
        // Al volver del fondo sigues DENTRO del hilo, no tocas su fila: tocarla lo trae de
        // nuevo del servidor, y en la demo eso lo da por terminado.
        app.launchEnvironment["GHOSTY_EN_HILO"] = "1"
        app.launch()
        let cartel = app.staticTexts["Estoy en ello. Te aviso en cuanto termine."]
        XCTAssertTrue(cartel.waitForExistence(timeout: 10),
                      "no salió el cartel del turno interrumpido")
        // La cabecera no puede decir «en reposo» encima del cartel que dice que sigue.
        // (En la demo otra conversación espera permiso, y eso gana: también vale.)
        let cabecera = app.buttons["cabecera-agente"]
        let dice = (cabecera.value as? String) ?? ""
        XCTAssertFalse(dice.isEmpty, "la cabecera dice que el agente está en reposo encima del cartel")
        foto("22-interrumpido")
        // Y en la lista tiene que verse igual de tranquilo: gris, no rojo de fallo.
        volverAChats()
        let fila = filaDeChat("El informe")
        XCTAssertTrue(fila.waitForExistence(timeout: 5), "el hilo interrumpido no sale en Chats")
        XCTAssertFalse(fila.label.contains("No terminó"),
                       "la lista da por fallido el hilo interrumpido: «\(fila.label)»")
        foto("23-interrumpido-lista")
    }

    /// El servidor cortó la respuesta (deploy): la franja con la razón y «Continuar», que la quita.
    func testCortadoContinuar() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO_CORTADO"] = "1"
        app.launchEnvironment["GHOSTY_EN_HILO"] = "1"
        app.launch()
        let boton = app.buttons["continuar-cortado"]
        XCTAssertTrue(boton.waitForExistence(timeout: 10), "no salió «Continuar» del run cortado")
        XCTAssertTrue(app.staticTexts["Se reinició el servidor mientras trabajaba."].exists)
        foto("24-cortado")
        boton.tap()
        XCTAssertTrue(boton.waitForNonExistence(timeout: 5), "«Continuar» no hizo nada")
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
        XCTAssertTrue(app.buttons["nueva-conversacion-lista"].waitForExistence(timeout: 10), "la app no arrancó en la demo")
        foto("01-chats")

        // 1. Nueva conversación desde la cabecera del hilo: tiene que dejarte en uno vacío.
        abrirChat("El informe")
        app.buttons["nueva-conversacion-cabecera"].tap()
        // El vacío del diseño nuevo: «¿Qué trabajo me encargas hoy?» con sus sugerencias.
        XCTAssertTrue(app.staticTexts["¿Qué trabajo me encargas hoy?"].waitForExistence(timeout: 3),
                      "el lápiz de la cabecera no abrió un hilo vacío")
        foto("02-nueva-desde-cabecera")

        // 2. La hoja del agente y sus paneles: se abre tocando su nombre en la cabecera.
        app.buttons["cabecera-agente"].tap()
        let cerrarHoja = app.buttons["cerrar-hoja"].firstMatch
        XCTAssertTrue(cerrarHoja.waitForExistence(timeout: 3), "tocar el agente no abrió su hoja")
        foto("03-hoja")
        cerrarHoja.tap()
        XCTAssertTrue(cerrarHoja.waitForNonExistence(timeout: 3), "la hoja del agente no cerró")

        // 3. «Chats»: la lista de verdad. Tocar una tiene que llevarme a ella — es el toque
        //    que antes no funcionaba.
        volverAChats()
        foto("04-chats")
        abrirChat("El informe")
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
        let copyButton = app.buttons.matching(identifier: "copy-response").allElementsBoundByIndex
            .last { $0.isHittable }
        XCTAssertNotNil(copyButton, "no hay botón de copiar bajo la respuesta")
        copyButton?.tap()
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
        XCTAssertTrue(app.staticTexts["causo.io"].waitForNonExistence(timeout: 3), "la hoja de fuentes no cerró")

        // 4b. La conversación con foto: imagen de markdown y tarjeta de entrega. Aquí es
        //     donde se ve si una imagen grande respeta el ancho de la burbuja.
        volverAChats()
        abrirChat("solo me interesa la foto")
        XCTAssertTrue(app.buttons["adjuntar"].waitForExistence(timeout: 3))
        foto("07b-conversacion-con-imagen")

        // Tocar una imagen de la respuesta tiene que abrirla a pantalla completa.
        // La imagen grande de la respuesta: la más alta de la pantalla.
        // Con el hilo ya asentado: al abrirlo se re-ancla abajo mientras las tarjetas
        // se miden, y un toque en ese instante cae donde la imagen ESTABA.
        Thread.sleep(forTimeInterval: 1.0)
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
        // La nota de voz (` ```eb-audio `) sale como la MISMA burbuja de voz que las tuyas
        // y play la baja y la reproduce: antes era JSON crudo, y un mp3 por URL decía «No
        // tengo el audio». La del agente es la segunda de 0:04 (la primera es la tuya).
        // Con el visor ya cerrado del todo: tocar mientras se va aterrizaba en la
        // tarjeta de la imagen y volvía a abrirlo.
        Thread.sleep(forTimeInterval: 0.8)
        let notas = app.otherElements.matching(NSPredicate(format: "label == 'Nota de voz de 0:04'"))
        XCTAssertTrue(notas.element(boundBy: 1).waitForExistence(timeout: 3),
                      "la nota de voz del agente no salió como reproductor")
        let play = notas.element(boundBy: 1).buttons["voz-play"]
        for _ in 0..<4 where play.exists && !play.isHittable { app.swipeDown() }
        play.tap()
        Thread.sleep(forTimeInterval: 1.0)
        foto("07d-nota-de-voz")
        XCTAssertEqual(play.label, "Pausar", "play no puso a sonar la nota de voz")
        XCTAssertFalse(app.staticTexts["Esa nota ya no está."].exists, "la nota de voz no se pudo bajar")
        XCTAssertFalse(app.staticTexts["No pude bajarlo."].exists, "la nota de voz no se pudo bajar")
        XCTAssertFalse(app.staticTexts["No pude reproducirlo."].exists, "la nota de voz no sonó")

        // 5. El adjuntador de tres tarjetas.
        let mas = app.buttons["adjuntar"]
        XCTAssertTrue(mas.waitForExistence(timeout: 3), "no encontré el botón de adjuntar")
        mas.tap()
        // «Agregar» es ahora una hoja (Foto, Cámara, Archivo) que tapa el `+`: se cierra
        // con el velo, como la de cambiar de agente. Tocar el `+` otra vez caía en una
        // fila de la hoja y abría el selector de archivos.
        let camara = app.buttons["adjuntar-Cámara"]
        XCTAssertTrue(camara.waitForExistence(timeout: 3), "no salió la hoja de agregar")
        Thread.sleep(forTimeInterval: 0.6)
        foto("08-adjuntar")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(camara.waitForNonExistence(timeout: 3), "tocar el velo no cerró la hoja de agregar")

        // 6. Empezar una conversación desde Chats (el +): eliges agente y te LLEVA al chat.
        volverAChats()
        let nueva = app.buttons["nueva-conversacion-lista"].firstMatch
        XCTAssertTrue(nueva.waitForExistence(timeout: 3), "no salió el botón de nueva conversación")
        nueva.tap()
        let conGhosty = app.buttons["nueva-con-demo-1"].firstMatch
        XCTAssertTrue(conGhosty.waitForExistence(timeout: 3), "el + no ofreció a qué agente")
        conGhosty.tap()
        XCTAssertTrue(app.buttons["volver-a-chats"].waitForExistence(timeout: 3)
                        && app.buttons["adjuntar"].waitForExistence(timeout: 3),
                      "nueva conversación no llevó al chat")
        foto("09-nueva-conversacion")
        volverAChats()

        // 6a. Deslizar una conversación a la izquierda: asoma «Archivar» y pide
        // confirmación. Se cancela, para que el archivado de verdad (6b) vaya por la
        // selección y queden cubiertos los dos caminos.
        let paraDeslizar = filaDeChat("solo me interesa la foto")
        XCTAssertTrue(paraDeslizar.waitForExistence(timeout: 3), "no está la conversación con foto en Chats")
        paraDeslizar.swipeLeft()
        let archivarDeslizado = app.buttons["Archivar"].firstMatch
        XCTAssertTrue(archivarDeslizado.waitForExistence(timeout: 3), "deslizar no descubrió el botón de archivar")
        foto("11a-deslizado")
        archivarDeslizado.tap()
        XCTAssertTrue(app.staticTexts["Se quita de tus chats y de tu agente."].waitForExistence(timeout: 3),
                      "archivar al deslizar no pidió confirmación")
        foto("11b-deslizado-confirmar")
        // El «Cancelar» de un confirmationDialog no siempre entra en la jerarquía de
        // accesibilidad: tocar fuera lo cierra igual.
        let cancelarArchivo = app.buttons["Cancelar"].firstMatch
        if cancelarArchivo.exists { cancelarArchivo.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap() }
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(paraDeslizar.exists, "cancelar archivó la conversación igual")

        // 6a2. Toque largo → modo selección → «Cambiar nombre»: el campo, guardar, y el
        // nombre nuevo en la fila. Una de Nube: el nombre se guarda en el teléfono y las
        // demás pruebas buscan las de Ghosty por su título.
        let paraNombrar = filaDeChat("Cotización de marzo", agente: "demo-2")
        XCTAssertTrue(paraNombrar.waitForExistence(timeout: 3), "no está «Cotización de marzo» de Nube")
        paraNombrar.press(forDuration: 0.6)
        let renombrar = app.buttons["Cambiar nombre"].firstMatch
        XCTAssertTrue(renombrar.waitForExistence(timeout: 3), "el toque largo no ofreció cambiar el nombre")
        renombrar.tap()
        let campo = app.alerts.textFields.firstMatch
        XCTAssertTrue(campo.waitForExistence(timeout: 3), "cambiar el nombre no abrió el campo")
        campo.tap()
        // Viene con el nombre actual: se borra tecleando retrocesos.
        let actual = (campo.value as? String) ?? ""
        campo.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: actual.count))
        campo.typeText("Lista del súper")
        foto("11c-renombrar")
        app.alerts.buttons["Guardar"].firstMatch.tap()
        XCTAssertTrue(filaDeChat("Lista del súper", agente: "demo-2").waitForExistence(timeout: 3),
                      "el nombre nuevo no apareció en la lista")
        foto("11d-renombrada")

        // 6b. Toque largo → selección → «Archivar»: se va de verdad de la lista.
        // Se comprueba que baje el número de filas: sin esto el test pasaba con la fila
        // intacta, que fue justo lo que ocultó que se borraba el canal equivocado.
        let paraArchivar = filaDeChat("solo me interesa la foto")
        let antes = filasDeChats.count
        paraArchivar.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["seleccion-cerrar"].waitForExistence(timeout: 3), "el toque largo no entró a la selección")
        foto("11-seleccion")
        // El de la barra de selección: la fila también tiene un «Archivar» (el de deslizar).
        let archivar = app.buttons.matching(NSPredicate(format: "label == 'Archivar'"))
            .allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(archivar, "la selección no ofrece archivar")
        archivar?.tap()
        foto("13-archivando")
        XCTAssertTrue(paraArchivar.waitForNonExistence(timeout: 3), "la conversación no se archivó")
        XCTAssertLessThan(filasDeChats.count, antes, "la lista no tiene una fila menos")
        foto("14-archivado")

        // 7. Lo guardado en el agente (sin abrir en el teléfono) va en la misma lista por
        //    fecha. Tiene que estar Y abrirse al tocarlo.
        let guardada = app.buttons["s-demo-1-s-vieja"]
        XCTAssertTrue(guardada.waitForExistence(timeout: 3), "lo guardado en el agente no sale en la lista")
        XCTAssertTrue(guardada.label.hasPrefix("Cotización de marzo"), "la guardada no se llama como en la caja")
        foto("10-guardadas")
        guardada.tap()
        XCTAssertTrue(app.buttons["volver-a-chats"].waitForExistence(timeout: 3)
                        && app.buttons["adjuntar"].waitForExistence(timeout: 3),
                      "tocar una conversación guardada no llevó al chat")
        volverAChats()

        // 8. Borrar la cuenta EXISTE y pide confirmación (Apple 5.1.1). Vive en Perfil. Se
        //    cancela: en demo no hay red y no hay cuenta que borrar.
        app.buttons["tab-perfil"].tap()
        let borrarCuenta = app.buttons["borrar-cuenta"].firstMatch
        XCTAssertTrue(borrarCuenta.waitForExistence(timeout: 3), "no está «Borrar mi cuenta» en Perfil")
        for _ in 0..<4 where !borrarCuenta.isHittable { app.swipeUp() }
        borrarCuenta.tap()
        // El botón rojo de confirmar es la prueba de que se pidió confirmación. Se cierra
        // sin tocarlo: con «Cancelar» si el diálogo lo trae (hoja) o tocando fuera (popover).
        XCTAssertTrue(app.staticTexts["¿Borrar tu cuenta?"].waitForExistence(timeout: 3),
                      "borrar la cuenta no pidió confirmación")
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
        app.launch()

        // 1. La cabecera del agente lo dice, aunque el turno no lo abrimos aquí.
        // ⚠️ El permiso GANA sobre el trabajo: es lo único detenido esperándote, y ahora
        // también cuenta el que se pidió desde otra superficie.
        abrirChat("El informe")
        let estado = app.buttons["cabecera-agente"]
        XCTAssertTrue(estado.waitForExistence(timeout: 5), "no se pintó la cabecera del agente")
        let dice = (estado.value as? String) ?? ""
        XCTAssertTrue(dice.contains("visto bueno"),
                      "un permiso pedido desde otro lado no sale en la cabecera: «\(dice)»")
        foto("20-estado-remoto")
        volverAChats()

        // 2. Las guardadas: la que corre dice «Trabajando…» y la que lleva tres horas
        //    muda NO — si no, la lista miente toda la tarde.
        // Cada fila es UN elemento de accesibilidad (título + subtítulo), así que se mira
        // su label. Sólo las de Ghosty, para que quepan sin hacer scroll.
        app.buttons["chip-demo-1"].tap()
        func guardada(_ titulo: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH 's-demo-1-' AND label BEGINSWITH %@", titulo)).firstMatch
        }
        let corre = guardada("Migración de la base")
        XCTAssertTrue(corre.waitForExistence(timeout: 3), "no sale la conversación que corre en otro lado")
        XCTAssertTrue(corre.label.contains("Trabajando…"),
                      "la conversación que sí corre no dice que trabaja: «\(corre.label)»")
        let muda = guardada("Turno mudo")
        XCTAssertTrue(muda.exists, "no sale el turno mudo")
        XCTAssertFalse(muda.label.contains("Trabajando"),
                       "el turno mudo de hace tres horas sigue diciendo que trabaja: «\(muda.label)»")
        let permiso = guardada("Publicar el recorte")
        XCTAssertTrue(permiso.exists, "no sale la conversación detenida por un permiso")
        XCTAssertTrue(permiso.label.contains("Espera tu permiso"),
                      "la conversación detenida por un permiso no lo dice: «\(permiso.label)»")
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

        abrirChat("El informe")
        let pensando = app.descendants(matching: .any).matching(identifier: "pensando").firstMatch
        XCTAssertTrue(pensando.waitForExistence(timeout: 5),
                      "sin herramienta corriendo no queda ningún indicador de carga")
        foto("24-entre-herramientas")

        // Y al volver de otra pestaña: el indicador sigue. Dentro del hilo no hay barra,
        // así que se sale a Chats, se va a Archivos y se vuelve a entrar.
        volverAChats()
        app.buttons["tab-artifacts"].tap()
        app.buttons["tab-chat"].tap()
        abrirChat("El informe")
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

        abrirChat("El informe")
        let campo = app.textViews["campo-mensaje"].firstMatch
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
        XCTAssertTrue(app.staticTexts["Añadido a lo que está haciendo"].waitForExistence(timeout: 3),
                      "no se dice que el mensaje entró en el turno en marcha")
        foto("27-steer-hecho")
    }

    /// Y con un agente que NO sabe steerear: se avisa antes de tirarle el trabajo.
    func testMandarleAUnAgenteQueNoSteerea() {
        app.terminate()
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launchEnvironment["GHOSTY_DEMO_STEER"] = "nativo"
        app.launch()

        abrirChat("El informe")

        let campo = app.textViews["campo-mensaje"].firstMatch
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
        XCTAssertTrue(app.textViews["campo-mensaje"].waitForExistence(timeout: 3),
                      "cancelar no devolvió al compositor")
    }

    func testVisorCierra() {
        abrirChat("solo me interesa la foto")
        XCTAssertTrue(app.buttons["adjuntar"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1.0)
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
