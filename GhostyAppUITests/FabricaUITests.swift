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

    /// «⋯» → Conectar repo → buscar → un repo que la App no ve (409, «Dar acceso») → otro repo →
    /// crear su room → nivel y faltantes → «Pide el primer cambio» abre «Nuevo pedido» con ese room.
    func testConectarRepoDemo() {
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launch()
        let pestana = app.buttons["tab-fabrica"]
        XCTAssertTrue(pestana.waitForExistence(timeout: 20), "no apareció la pestaña «Fábrica»")
        pestana.tap()
        let mas = app.buttons["fabrica-mas"]
        XCTAssertTrue(mas.waitForExistence(timeout: 10), "no hay «⋯» en la cabecera")
        mas.tap()
        let menu = app.buttons["menu-conectar-repo"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "el menú no trae «Conectar repo»")
        menu.tap()

        XCTAssertTrue(app.buttons["repo-tienda"].waitForExistence(timeout: 5), "la hoja no lista los repos")
        XCTAssertTrue(app.staticTexts["en #agenda"].exists, "el repo conectado no dice su room")
        foto("c1-repos")

        // El que la App no ve: el 409 se queda en la hoja con «Dar acceso».
        app.buttons["repo-inventario"].tap()
        XCTAssertTrue(app.buttons["conectar-repo"].waitForExistence(timeout: 3), "escoger el repo no abrió el room")
        app.buttons["conectar-repo"].tap()
        XCTAssertTrue(app.buttons["dar-acceso-repo"].waitForExistence(timeout: 8), "el 409 no ofreció «Dar acceso en GitHub»")
        foto("c2-sin-acceso")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let buscar = app.textFields["buscar-repo"]
        XCTAssertTrue(buscar.waitForExistence(timeout: 3))
        buscar.tap()
        buscar.typeText("tien")
        XCTAssertFalse(app.buttons["repo-sitio"].exists, "la búsqueda no filtró")
        app.buttons["repo-tienda"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["room-nuevo"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["nombre-room"].value as? String, "tienda", "el room nuevo no se llama como el repo")
        foto("c3-room")
        app.buttons["conectar-repo"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["conectando"].waitForExistence(timeout: 2), "no se ve el progreso")
        foto("c4-conectando")

        let listo = app.staticTexts["conectado"]
        XCTAssertTrue(listo.waitForExistence(timeout: 8), "no terminó de conectar")
        XCTAssertTrue(listo.label.contains("#tienda"), "el resultado no nombra el room: \(listo.label)")
        XCTAssertTrue(app.staticTexts["Reglas para agentes (AGENTS.md)"].exists, "no dice lo que falta")
        foto("c5-listo")

        app.buttons["pide-primer-cambio"].tap()
        let chip = app.buttons["nuevo-room-tienda"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "«Pide el primer cambio» no abrió «Nuevo pedido» con el room")
        XCTAssertEqual(chip.value as? String, "escogido", "el room nuevo no quedó escogido")
        foto("c6-pedido")
    }

    // MARK: - Lo que contesta @plan («se manda el pedido pero nada regresa», 19-oct)

    private func abrirFabrica() {
        app.launchEnvironment["GHOSTY_DEMO"] = "1"
        app.launch()
        let pestana = app.buttons["tab-fabrica"]
        XCTAssertTrue(pestana.waitForExistence(timeout: 20), "no apareció la pestaña «Fábrica»")
        pestana.tap()
    }

    /// Toca una fila de la lista, bajando si la tapa la barra de pestañas.
    private func tocar(_ id: String) {
        let e = app.buttons[id]
        XCTAssertTrue(e.waitForExistence(timeout: 10), "la lista no enseña «\(id)»")
        var i = 0
        while (!e.isHittable || e.frame.maxY > app.frame.maxY - 110) && i < 4 { app.swipeUp(velocity: .slow); i += 1 }
        e.tap()
    }

    /// Escalado porque la preview no arranca sin variables (#125): los hallazgos se leen (no JSON
    /// crudo), la barra NO ofrece «Que @build lo arregle», se dan las variables y @check revisa.
    func testEscaladoBloqueadoDemo() {
        abrirFabrica()
        tocar("pedido-36")
        let hallazgos = app.descendants(matching: .any)["hallazgos"]
        XCTAssertTrue(hallazgos.waitForExistence(timeout: 5), "no salen los hallazgos")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "\"severity\"")).firstMatch.exists,
                       "los hallazgos salen como JSON crudo")
        XCTAssertFalse(app.buttons["otra-vuelta"].exists, "un bloqueo no se arregla con otra vuelta de @build")
        XCTAssertTrue(app.buttons["volver-a-revisar"].exists, "falta «Que @check revise»")
        foto("b1-bloqueado")
        let copiar = app.buttons["copiar-para-terminal"]
        XCTAssertTrue(copiar.exists, "falta «Copiar para mi agente de terminal»")
        // Con el motivo arriba, el botón queda bajo la barra de decisiones: se baja a él.
        tocar("copiar-para-terminal")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Copiado")).firstMatch.waitForExistence(timeout: 3),
                      "copiar no avisó")
        tocar("dar-variables")
        let campo = app.secureTextFields["valor-DATABASE_URL"]
        XCTAssertTrue(campo.waitForExistence(timeout: 5), "la hoja no trae DATABASE_URL")
        XCTAssertTrue(app.secureTextFields["valor-SANDBOX_HOST_TOKEN"].exists, "faltan variables en la hoja")
        campo.tap()
        campo.typeText("postgres://demo")
        foto("b2-variables")
        app.buttons["guardar-variables"].tap()
        let confirmar = app.descendants(matching: .any)["confirmar-recheck"]
        XCTAssertTrue(confirmar.waitForExistence(timeout: 5), "al guardar no ofrece que @check revise")
        foto("b3-revisar")
    }

    /// «Te toca 8» con 5 que eran la preview atorada (easybits, 20-oct): una falla de la plataforma
    /// no cuenta como «Te toca», cada tarjeta dice su motivo y cada tipo trae su botón.
    func testTeTocaConMotivoDemo() {
        abrirFabrica()
        let conteo = app.staticTexts["conteo-Te toca"]
        XCTAssertTrue(conteo.waitForExistence(timeout: 10), "no está la sección «Te toca»")
        // #42 firma, #41 fix, #36 variables, #43 cerrar, #39 PR. El #44 (preview) no.
        XCTAssertEqual(conteo.label, "5", "una preview atorada cuenta como «Te toca»")
        XCTAssertTrue(app.staticTexts["motivo-43"].exists, "la tarjeta escalada no dice su motivo")
        XCTAssertTrue(app.staticTexts["Esperando preview"].exists, "el pedido que espera la preview no lo dice")
        foto("t1-te-toca")

        tocar("pedido-44")
        XCTAssertTrue(app.staticTexts["Esperando la preview"].waitForExistence(timeout: 5), "no sale la tarjeta de plataforma")
        XCTAssertTrue(app.buttons["reintentar-preview"].exists, "falta «Reintentar preview»")
        XCTAssertFalse(app.buttons["otra-vuelta"].exists, "una falla de plataforma no se arregla con @build")
        XCTAssertFalse(app.buttons["que-hago"].exists, "en una falla de plataforma no hay nada que decidir")
        foto("t2-plataforma")
        app.navigationBars.buttons.firstMatch.tap()

        tocar("pedido-43")
        XCTAssertTrue(app.staticTexts["motivo"].waitForExistence(timeout: 5), "el detalle no dice el motivo")
        tocar("cerrar-ignorar")
        XCTAssertTrue(app.descendants(matching: .any)["confirmar-close-ignore"].waitForExistence(timeout: 5),
                      "«Cerrar e ignorar» no pide confirmar")
        foto("t3-cerrar-ignorar")
        app.buttons["confirmar-cancelar"].tap()
    }

    /// Un pedido sin avanzar (#121, 20-oct) dice la verdad y tiene salida: «¿Qué pasó?», «Retomar»,
    /// «Detener pedido» y el hilo DENTRO de la app, donde se le escribe a @build.
    func testPedidoSinAvanzarDemo() {
        abrirFabrica()
        tocar("pedido-35")
        XCTAssertTrue(app.staticTexts["Sin avanzar: nadie está trabajando"].waitForExistence(timeout: 5),
                      "un pedido atorado sigue diciendo que alguien construye")
        XCTAssertTrue(app.buttons["retomar"].exists, "falta «Retomar»")
        XCTAssertTrue(app.buttons["detener-pedido"].exists, "falta «Detener pedido»")
        tocar("que-paso")
        XCTAssertTrue(app.staticTexts["que-paso-texto"].waitForExistence(timeout: 5), "«¿Qué pasó?» no contestó")
        foto("s1-sin-avanzar")
        tocar("retomar")
        XCTAssertTrue(app.descendants(matching: .any)["confirmar-resume"].waitForExistence(timeout: 5), "«Retomar» no pide confirmar")
        app.buttons["confirmar-cancelar"].tap()
        tocar("abrir-hilo")
        XCTAssertTrue(app.descendants(matching: .any)["hilo-pedido"].waitForExistence(timeout: 5), "el hilo no abre dentro de la app")
        // El identificador de la pantalla («hilo-pedido») tapa el del campo: se busca por su texto.
        let campo = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Escríbele a @build")).firstMatch
        XCTAssertTrue(campo.waitForExistence(timeout: 5), "en un pedido en marcha se le escribe a @build, no a @plan")
        foto("s2-hilo")
        tocar("plan-listo")
        XCTAssertTrue(app.buttons["retomar"].waitForExistence(timeout: 5), "la tarjeta del hilo no regresa al pedido")
    }

    /// Mandar un pedido abre su hilo (no un «Listo» que no lleva a nada) y ahí se ve a @plan trabajar.
    func testPedidoNuevoAbreElHiloDemo() {
        abrirFabrica()
        app.buttons["fabrica-nuevo"].tap()
        let texto = app.textViews.firstMatch
        XCTAssertTrue(texto.waitForExistence(timeout: 5))
        texto.tap()
        texto.typeText("Que el cliente pueda reagendar desde el link del recordatorio")
        app.buttons["Mandar a @plan"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pasos-en-vivo"].waitForExistence(timeout: 8), "mandar no abrió el hilo con @plan trabajando")
        foto("p1-hilo-trabajando")
    }

    /// La lista «Con @plan» → una pregunta con opciones → contestar → nace el plan y pasa solo a firmarlo.
    func testPreguntaDePlanDemo() {
        abrirFabrica()
        XCTAssertTrue(app.buttons["con-plan-9004"].waitForExistence(timeout: 10), "no está la sección «Con @plan»")
        foto("p2-con-plan")
        tocar("con-plan-9004")
        let opcion = app.buttons["opcion-WhatsApp"]
        XCTAssertTrue(opcion.waitForExistence(timeout: 5), "la pregunta no trae sus opciones")
        foto("p3-pregunta")
        opcion.tap()
        XCTAssertTrue(app.staticTexts["pedido-titulo"].waitForExistence(timeout: 10), "contestar no llevó al plan para firmar")
        foto("p4-plan-para-firmar")
    }

    /// Ideas: «Pedir» abre el hilo del pedido nuevo.
    func testIdeasDePlanDemo() {
        abrirFabrica()
        tocar("con-plan-9003")
        let pedir = app.buttons["pedir-idea-0"]
        XCTAssertTrue(pedir.waitForExistence(timeout: 5), "las ideas no traen «Pedir»")
        foto("p5-ideas")
        pedir.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pasos-en-vivo"].waitForExistence(timeout: 8), "«Pedir» no abrió el hilo nuevo")
    }

    /// Sprint: del hilo a la lista nativa, quitar un ticket deslizando, crear el sprint y ver su avance.
    func testSprintDemo() {
        abrirFabrica()
        tocar("con-plan-9002")
        let abrir = app.buttons["abrir-sprint"]
        XCTAssertTrue(abrir.waitForExistence(timeout: 5), "el hilo no enseña el sprint propuesto")
        foto("s1-hilo-sprint")
        abrir.tap()
        XCTAssertTrue(app.staticTexts["sprint-titulo"].waitForExistence(timeout: 5), "no abrió el sprint")
        let crear = app.buttons["crear-sprint"]
        XCTAssertTrue(crear.label.contains("4"), "no cuenta 4 tickets: \(crear.label)")
        foto("s2-sprint")

        app.cells.containing(.any, identifier: "ticket-K4").firstMatch.swipeLeft()
        let quitar = app.buttons["Quitar"]
        XCTAssertTrue(quitar.waitForExistence(timeout: 3), "deslizar no ofreció «Quitar»")
        quitar.tap()
        XCTAssertTrue(app.buttons["crear-sprint"].label.contains("3"), "quitar no bajó la cuenta: \(app.buttons["crear-sprint"].label)")

        app.descendants(matching: .any).matching(identifier: "ticket-K1").firstMatch.tap()
        XCTAssertTrue(app.buttons["editar-ticket"].waitForExistence(timeout: 3), "el ticket no abrió su hoja")
        foto("s3-ticket")
        app.buttons["Cerrar"].tap()

        app.buttons["crear-sprint"].tap()
        let confirmar = app.buttons["confirmar-sprint"]
        XCTAssertTrue(confirmar.waitForExistence(timeout: 3), "«Crear sprint» no pidió confirmar")
        confirmar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sprint-avance"].waitForExistence(timeout: 5), "crear no dejó el sprint en marcha")
        XCTAssertFalse(app.buttons["crear-sprint"].exists, "la barra de crear sigue ahí")
        foto("s4-en-marcha")

        // De vuelta en la lista, la fila del sprint ya no dice «Propuesto · te toca revisarlo».
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let fila = app.buttons["sprint-7"]
        XCTAssertTrue(fila.waitForExistence(timeout: 5), "no regresó a la lista")
        XCTAssertFalse(fila.label.contains("Propuesto"), "la fila sigue diciendo propuesto: \(fila.label)")
        foto("s5-lista-tras-aprobar")
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
