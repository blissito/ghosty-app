import PhotosUI
import SwiftUI

struct ConversationView: View {
    let store: LiveAgentStore
    var onOpenSheet: () -> Void

    @State private var borrador = ""
    @FocusState private var escribiendo: Bool
    @Namespace private var formaDelCompositor
    /// Donde vuela la nota de voz: de la barra de grabación a su burbuja.
    @Namespace private var vuelo
    /// El id de la nota que va en el aire ahora mismo.
    @State private var enVuelo: String?

    // Adjuntos que esperan a que se mande el turno.
    @State private var adjuntos: [Adjunto] = []
    @State private var fotos: [PhotosPickerItem] = []
    @State private var abrirFotos = false
    @State private var abrirArchivos = false
    @State private var abrirCamara = false
    /// ¿Está abierta la fila de tres tarjetas del `+`?
    @State private var adjuntando = false
    @State private var subiendo = false
    /// Mandar esto le corta el trabajo al agente: se pregunta antes.
    @State private var avisoDeCorte = false
    @State private var grabador = GrabadorDeVoz()
    /// Cuánto se ha arrastrado desde el micrófono. Izquierda cancela, arriba bloquea.
    @State private var arrastre: CGSize = .zero
    /// Manos libres: se soltó el dedo y la grabación sigue.
    @State private var vozBloqueada = false
    @State private var fallo: String?
    /// El último mensaje visible, según el propio `ScrollView`.
    @State private var anclaje: String?
    /// ¿Sigues el final del hilo? UNA regla, la de todos los chats: sólo lo cambia el
    /// dedo (subir a releer lo apaga, volver abajo lo enciende), enviar o cambiar de
    /// conversación. Lo que llega hace scroll si y sólo si esto es verdad.
    ///
    /// ⚠️ Antes se deducía de «¿el ancla es el último id?», y al añadirse un mensaje el
    /// ancla apuntaba al ANTERIOR: la deducción decía «no estás abajo» justo cuando había
    /// que bajar. De ahí salieron un plazo de cuatro segundos, un contador de envíos y
    /// un reintento a los 120 ms, y el scroll seguía siendo intermitente.
    @State private var pegadoAbajo = true
    /// «Siguiendo el final»: se re-ancla abajo con cada crecimiento del contenido hasta
    /// que la persona arrastre. `pegadoAbajo` lo mueve el sistema con cada relayout y por
    /// eso no sirve para esto: al crecer una tarjeta el ancla cambia de id un instante.
    @State private var siguiendoElFinal = true
    /// Cada incremento es una orden de bajar al fondo; la ejecuta el `ScrollViewReader`.
    @State private var bajar = 0
    @State private var bajarAnimado = false
    private static let fondo = "fondo-del-hilo"
    /// El mensaje que acabas de mandar, para clavarlo ARRIBA de la pantalla mientras el
    /// agente contesta debajo (como Claude). `nil` = hilo abierto normal, anclado al final.
    /// «El próximo mensaje de usuario que aparezca es el mío»: `send` es asíncrono y el id
    /// lo pone el store, así que se espera a verlo en la lista.
    /// Alto de lo que va desde el mensaje anclado hasta el final, y alto visible del
    /// hilo: la diferencia es el aire que se pone debajo para que el mensaje QUEPA arriba.
    @State private var altoDeLaCola: CGFloat = 0
    @State private var altoVisible: CGFloat = 0

    /// La agenda de la conversación que se mira. Se rehace al cambiar de hilo: es por
    /// `(agente, sesión)`, y una conversación nueva sin `sessionId` no tiene agenda aún.
    @State private var agenda: Agenda?
    @State private var abrirAgenda = false

    var body: some View {
        VStack(spacing: 0) {
            if let agente = store.selectedAgent {
                AgentHeader(agent: agente, estado: store.estado(de: agente.id),
                            onTap: { escribiendo = false; onOpenSheet() },
                            onNueva: { store.nuevaConversacion() })
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }

            // ⚠️⚠️ El scroll va con la API de Apple —`scrollPosition` y
            // `defaultScrollAnchor`, iOS 17— y no con `ScrollViewReader` + centinela, que
            // es lo que había. Ese apaño costó cuatro intentos y ninguno funcionó: medir
            // la posición con geometría devolvía cero dentro de un `ScrollView`, deducirla
            // del gesto dejaba el botón pegado, y `scrollTo` sobre un `LazyVStack` que
            // aún no ha medido sus filas aterriza en cualquier parte. Esto no es un
            // problema que haya que resolver a mano: el sistema ya sabe dónde estás.
            //
            // `anclaje` es el ÚLTIMO mensaje visible. Si es el último del hilo, estás
            // abajo; si no, se enseña el botón. Bajar es asignarlo.
            hilo

            // ⚠️ Un CARTEL, no un mensaje. Que el aviso viva dentro de la respuesta lo
            // convertía en historia: quedaba «se cortó la conexión» pegado para siempre en
            // una conversación que acabó bien. Éste está atado al estado del hilo, así que
            // se va solo en cuanto la recogida trae la respuesta.
            if let hilo = store.hiloActivo, hilo.interrumpido {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Sigo con esto. Te aviso en cuanto termine.")
                        .gMeta().foregroundStyle(Color.gInk2)
                    Spacer(minLength: 0)
                    // ⚠️ SIEMPRE una salida. Este cartel no ofrecía ninguna: si el turno
                    // se quedaba colgado allá, la conversación se quedaba diciendo «sigue
                    // con esto» sin forma de pararlo ni de escribir —el botón de detener
                    // sólo sale con un turno LOCAL vivo, y aquí no lo hay—.
                    Button("Detener") { Task { await store.stopTurn() } }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                        .accessibilityIdentifier("detener-interrumpido")
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.gCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16).padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Lo que el agente hará solo, si hay algo: es lo que convierte «trabaja en
            // esto por días» en algo que se ve sin abrir ninguna hoja.
            if let agenda { AgendaStrip(agenda: agenda) { abrirAgenda = true } }

            // ⚠️ Aquí vivió la barra de chips de conversaciones con su «+». Se fue: la
            // lista de verdad es la pestaña de Conversaciones, y «nueva» ya está en la
            // cabecera. Dos entradas para lo mismo encima del compositor era ruido.

            compositor
                // Venir de «Nueva conversación» abre el teclado: si te llevan a una
                // conversación vacía, lo siguiente que vas a hacer es escribir.
                .onChange(of: store.pedirTeclado) { _, quiere in
                    guard quiere else { return }
                    escribiendo = true
                    store.pedirTeclado = false
                }
                .onAppear {
                    if store.pedirTeclado { escribiendo = true; store.pedirTeclado = false }
                }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                   value: store.hiloActivo?.interrumpido)
        .sensoryFeedback(.success, trigger: entregasEnElHilo)
        .sensoryFeedback(.impact(weight: .light), trigger: adjuntos.count)
        .sensoryFeedback(.start, trigger: grabador.grabando)
        .sensoryFeedback(.impact(weight: .medium), trigger: vozBloqueada)
    }

    /// Ejemplos de lo que se le puede pedir. Al tocarlos se escriben en el campo —no se
    /// envían— para que la persona pueda cambiarlos antes de mandarlos.
    private static let ejemplos = [
        "Resume este PDF",
        "Búscame precios y hazme una tabla",
        "Arma una cotización en PDF",
    ]

    /// El vacío del hilo.
    ///
    /// ⚠️ NO explica cómo funciona por dentro. Decía "este hilo habla con tu caja de verdad
    /// y lo que contesta se pinta como markdown": la caja es vocabulario NUESTRO —nadie de
    /// fuera sabe qué es— y el markdown es un detalle de implementación que no le resuelve
    /// nada a quien abre la app por primera vez. Lo que esa persona necesita saber es qué
    /// pedirle, así que el vacío ES el onboarding. Es lo que hace Muse con su pestaña de
    /// ideas y lo que hacen todos los demás.
    ///
    /// Dónde SÍ se nombra la máquina: en Ajustes, en posesivo y como promesa ("vive en tu
    /// propia computadora en la nube"), que es exactamente el molde de Meta — primero lo
    /// que es tuyo, después, y sólo si hace falta, lo técnico.
    private var primeraVez: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.gInk4)
            Text("¿En qué te ayudo?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.gInk2)

            VStack(spacing: 8) {
                ForEach(Self.ejemplos, id: \.self) { texto in
                    Button {
                        borrador = texto
                        escribiendo = true
                    } label: {
                        Text(texto)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.gInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity)
                            .background(Color.gCard, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity)
    }

    private func esEntrega(_ m: Message) -> Bool {
        if case .entrega = m.kind { return true }
        return false
    }

    /// Cuántas entregas lleva el hilo. Dispara la háptica: es un cambio del MUNDO (te
    /// llegó algo), no de la pantalla, y el teléfono tiene una forma nativa de decirlo.
    private var entregasEnElHilo: Int {
        store.messages.reduce(0) { $0 + (esEntrega($1) ? 1 : 0) }
    }

    /// Qué conversación se está mirando. Cambia al abrir un hilo de la caja, al
    /// empezar una nueva y al cambiar de agente — los tres casos en los que el hilo
    /// se repuebla entero y hay que volver a poner el ojo abajo.
    /// Los mensajes, sin ids repetidos.
    ///
    /// ⚠️ Red de seguridad, no maquillaje: un `ForEach` con dos ids iguales no pinta de
    /// más — **deja de pintar**, y la conversación se queda en blanco con los mensajes
    /// ahí. Pasó de verdad, tres veces reportado. La causa se arregla en el store (una
    /// entrega que llegaba dos veces al mismo hilo), pero un hilo en blanco es tan malo
    /// que no puede depender de que nadie se equivoque nunca más.
    private var mensajesÚnicos: [Message] {
        var vistos = Set<String>()
        return store.messages.filter { vistos.insert($0.id).inserted }
    }

    private var alFinal: Bool { pegadoAbajo }


    /// El hilo con su scroll. Aparte del `body` porque el compilador no lo tipaba junto.
    private var hilo: some View {
        ScrollViewReader { lector in
        ScrollView {
            // ⚠️ VStack, NO LazyVStack. Con el perezoso, al plegar una tarjeta de
            // herramientas el contenido encogía, el offset quedaba más allá del final
            // y no se pintaba NADA: el hilo entero en blanco con los mensajes dentro
            // (medido: «pintando 2 mensajes» y pantalla vacía). El hilo trae como
            // mucho `tail` mensajes; no hay nada que virtualizar.
            contenidoDelHilo(lector)
        }
        .background(MedidorDeAlto(alto: $altoVisible))
        // Un chat empieza abajo. Sin esto arranca arriba y hay que mandarlo al final
        // a mano en cada apertura, que es de donde salían los saltos.
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $anclaje, anchor: .bottom)
        // ⚠️ Bajar es `scrollTo`, no asignar el ancla. Asignar `anclaje = ultimo` no
        // hacía nada si el sistema ya lo tenía como ancla —pasa siempre que el último
        // mensaje es más alto que la pantalla: subes a releerlo, el ancla sigue
        // siendo él, y el botón no servía—. Con un `VStack` (no perezoso) todas las
        // filas existen, así que `scrollTo` aterriza donde debe.
        .onChange(of: bajar) { _, _ in
            guard bajar > 0 else { return }
            if bajarAnimado { withAnimation(.easeOut(duration: 0.28)) { reanclar(lector) } }
            else { reanclar(lector) }
            // ⚠️ Y otra vez cuando termine la animación. Con un mensaje largo que
            // sigue creciendo (streaming) el primer `scrollTo` aterrizaba en el fondo
            // de HACE un instante y se quedaba a medio camino: el botón «no
            // funcionaba». El segundo cierra la diferencia sin animación.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(bajarAnimado ? 320 : 80))
                guard siguiendoElFinal else { return }
                reanclar(lector)
            }
        }
        .overlay(alignment: .bottom) {
            if !alFinal, !mensajesÚnicos.isEmpty {
                Button { irAbajo(animado: true) } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                        .frame(width: 44, height: 44)
                        .background(Color.gCard, in: Circle())
                        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                        // ⚠️ 44 pt de toque de verdad, con aire alrededor: a 34 pt
                        // había que atinarle, y el toque que caía al lado lo cogía el
                        // scroll (que además cierra el teclado) y parecía que el botón
                        // no hacía nada.
                        .padding(6)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ir-abajo")
                .accessibilityLabel("Ir al final")
                .padding(.bottom, 8)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: alFinal)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            TapGesture().onEnded {
                escribiendo = false
                if adjuntando {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        adjuntando = false
                    }
                }
            }
        )
        // El dedo manda: el ancla la mueve el sistema al hacer scroll, y de ahí sale
        // si sigues el final o subiste a releer.
        .onChange(of: anclaje) { _, a in
            guard let a, let ultimo = mensajesÚnicos.last?.id else { return }
            pegadoAbajo = a == ultimo || a == Self.fondo
            // Volver abajo con el dedo es volver a seguir el final.
            if pegadoAbajo { siguiendoElFinal = true }
        }
        // El dedo manda: arrastrar suelta el «seguir el final».
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { g in
            if g.translation.height > 0 { siguiendoElFinal = false }
        })
        // Llega un mensaje o crece el último (la respuesta viene en trozos): se baja
        // sólo si seguías el final. Que la respuesta te tire hacia abajo cuando has
        // subido a releer es lo más molesto que puede hacer un chat.
        .onChange(of: store.messages.count) { _, _ in llegoMensaje(lector) }
        // Y al aparecer: la sonda de desarrollo manda antes de que la vista exista, y el
        // `onChange` de arriba no ve ese cambio.
        //
        // ⚠️ SIN animar. Volver de otra pestaña construye la vista de cero (`RootView` es
        // un `switch`), y animar aquí se ve como un salto del hilo entero al entrar. El
        // ancla ya está en el hilo: sólo hay que volver a ella.
        .onAppear { reanclar(lector) }
        .onChange(of: textoDelUltimo) { _, _ in seguir() }
        // Una tarjeta que se midió tarde (video, imagen): si seguías el final, abajo.
        .onReceive(NotificationCenter.default.publisher(for: .hiloCrecio)) { _ in
            guard siguiendoElFinal else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                reanclar(lector)
            }
        }
        // Cambiar de conversación es una pantalla nueva: empieza por el final.
        .onChange(of: hiloVisible) { _, _ in irAbajo() }
        // ⚠️ El aire de abajo vive SÓLO mientras el turno corre. Dejarlo después —como hace
        // Claude— aquí era un hueco por el que se arrastraba la conversación entera fuera
        // de la pantalla (medido en el iPhone): al cerrar el turno se recoge, animado, y
        // el hilo vuelve a su ancla de siempre.
        .onChange(of: store.currentTurn == nil) { _, enReposo in
            guard enReposo, store.anclaDelHilo != nil else { return }
            withAnimation(.easeInOut(duration: 0.35)) { store.anclaDelHilo = nil }
        }
        // Un mensaje que se mandó y la app murió antes de que existiera la
        // conversación vuelve al compositor, con el aviso, en vez de desaparecer.
        .task(id: store.selectedAgentID) {
            if borrador.isEmpty, let perdido = BorradorPendiente.recoger(de: store.selectedAgentID) {
                borrador = perdido
                fallo = "No se pudo mandar. Inténtalo otra vez."
            }
        }
        .task(id: "\(hiloVisible)/\(store.hiloActivo?.sesionID ?? "")") {
            guard let sid = store.hiloActivo?.sesionID else { agenda = nil; return }
            let a = Agenda(agentID: store.selectedAgentID, sessionID: sid)
            agenda = a
            await a.recargar()
        }
        .sheet(isPresented: $abrirAgenda) {
            if let agenda { AgendaSheet(agenda: agenda) }
        }
        // ⚠️ Se dice lo que CUESTA, no «¿estás seguro?». Este agente no sabe meter tu
        // mensaje en lo que ya hace (o le mandas un archivo, que no se puede inyectar):
        // mandarlo ahora tira lo que lleva. Quien sí sabe, no pregunta nada.
        //
        // ⚠️ `alert` y no `confirmationDialog`: la hoja de abajo se ancla sobre el
        // compositor y su botón de cancelar quedaba FUERA de la pantalla —un aviso
        // destructivo del que sólo se veía la opción destructiva—. Lo cazó el recorrido.
        .alert("\(store.selectedAgent?.name ?? "Tu agente") está con lo anterior",
               isPresented: $avisoDeCorte) {
            Button("Mandar y empezar de nuevo", role: .destructive) { mandarYa() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Pierde lo que lleva hecho y arranca otra vez con lo que acabas de escribir.")
        }
        } // ScrollViewReader
    }

    /// El contenido del scroll, aparte: dentro del `body` el compilador no lo tipaba.
    @ViewBuilder
    private func contenidoDelHilo(_ lector: ScrollViewProxy) -> some View {
                VStack(spacing: 14) {
            if mensajesÚnicos.isEmpty {
                primeraVez.padding(.top, 90)
            }
            Color.clear.frame(height: 0)
                .onAppear { EasyBitsClient.diag("[vista] pintando \(store.messages.count) mensajes de \(store.claveDelHilo.prefix(8))") }
                .onChange(of: store.messages.count) { _, n in
                    EasyBitsClient.diag("[vista] ahora \(n) mensajes de \(store.claveDelHilo.prefix(8))")
                }
            ForEach(antesDelAncla) { mensaje in filaAnimada(mensaje) }
            // ⚠️ Lo que va desde TU último mensaje se mide aparte: es lo que
            // permite calcular cuánto aire hace falta debajo para que ese mensaje
            // se quede pegado arriba mientras la respuesta crece (como Claude). El
            // aire se come conforme la cola crece, y cuando la cola ya no cabe, el
            // hilo vuelve a comportarse como siempre.
            VStack(spacing: 14) {
                ForEach(desdeElAncla) { mensaje in filaAnimada(mensaje) }
                pieDeTrabajo
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: AltoDeLaCola.self, value: g.size.height)
            })
            // ⚠️ SIEMPRE presente y con altura animable. `defaultScrollAnchor(.bottom)`
            // sigue el crecimiento del contenido al instante, así que un aire que aparece
            // de golpe es un salto seco por mucho `scrollTo` animado que venga después;
            // si la ALTURA anima de 0 al aire, el anclaje de abajo la sigue y la subida se
            // ve.
            Color.clear.frame(height: store.anclaDelHilo == nil ? 0 : aireDebajo)
            // El fondo de verdad: a donde se baja. Un mensaje largo que crece
            // con el streaming no cambia de id, y «bajar» a un id que ya es
            // el ancla no mueve nada.
            Color.clear.frame(height: 1).id(Self.fondo)
        }
        .padding(.horizontal, 16)
        // ⚠️ Aire al final, que es el «siempre esconde contenido»: sin esto la
        // última línea queda justo debajo de la barra de conversaciones y hay que
        // adivinar que sigue ahí.
        .padding(.bottom, 28)
        .scrollTargetLayout()
        // El contenido CRECE después del primer pintado (markdown, tarjetas de
        // video con su cuadro, imágenes): mientras sigas el final, cada cambio de
        // altura vuelve a anclar abajo sin animación. Es lo que evita el «se quedó
        // a la mitad» al abrir un hilo. Si subiste a releer, no se fuerza.
        .background(GeometryReader { g in
            Color.clear.preference(key: AltoDelHilo.self, value: g.size.height)
        })
        .onPreferenceChange(AltoDelHilo.self) { _ in
            guard siguiendoElFinal else { return }
            // La subida del mensaje recién mandado se ve: es el aire apareciendo de
            // golpe, y sin esto el re-anclaje instantáneo se comía la animación.
            reanclar(lector)
        }
        .onPreferenceChange(AltoDeLaCola.self) { altoDeLaCola = $0 }
    }

    /// Que el agente SIGUE, al final del hilo y bajo la última respuesta.
    ///
    /// ⚠️ Esto era un mensaje (`.typing`) metido en el hilo por `send`, y la PRIMERA
    /// herramienta lo borraba para siempre (`pintarRespuesta`). Lo que quedaba era una
    /// mascota dentro de la burbuja que pedía `tools.corriendo != nil`: entre una
    /// herramienta y la siguiente —el modelo pensando, que es donde más se tarda— no había
    /// absolutamente nada, y volver de otra pestaña dejaba la pantalla como si hubiera
    /// terminado. Ahora sale del TURNO, que es lo que el servidor confirma y lo único que
    /// sobrevive a que la vista se destruya.
    @ViewBuilder
    private var pieDeTrabajo: some View {
        if store.currentTurn != nil {
            MascotaPensando(tone: store.selectedAgent?.tone ?? .lila, texto: textoDelPie)
                // ⚠️ `combine` ANTES del identificador: sin eso el `HStack` no es un
                // elemento de accesibilidad y el identificador no existe para nadie —ni
                // para VoiceOver ni para el recorrido que comprueba que el indicador sigue.
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pensando")
                .transition(.opacity)
        }
    }

    /// Lo que hace, salvo que la línea de pasos ya lo esté diciendo: dos frases para el
    /// mismo hecho, una encima de otra, es de lo que más ensucia esta pantalla.
    private var textoDelPie: String? {
        if case .agent(_, let tools, _) = mensajesÚnicos.last?.kind, tools?.corriendo != nil {
            return nil
        }
        return store.currentTurn?.detail ?? "Pensando…"
    }

    /// Llegó un mensaje: se sigue el final.
    ///
    /// ⚠️ Aquí se decidía TAMBIÉN qué mensaje clavar arriba, adivinándolo de la forma del
    /// hilo («tu mensaje y un `.typing` detrás»). Ese `.typing` lo borraba la primera
    /// herramienta, así que en cuanto el agente usaba una, el aire ya no se podía
    /// reconstruir —y volver de otra pestaña lo perdía—. Ahora lo pone `send`, que es
    /// quien sabe de verdad qué acabas de mandar, y vive en el hilo.
    private func llegoMensaje(_ lector: ScrollViewProxy) {
        seguir(animado: true)
    }

    /// Los mensajes antes de tu último envío, y desde él (inclusive).
    private var antesDelAncla: [Message] {
        guard let ancla = store.anclaDelHilo,
              let i = mensajesÚnicos.firstIndex(where: { $0.id == ancla }) else { return mensajesÚnicos }
        return Array(mensajesÚnicos[..<i])
    }
    private var desdeElAncla: [Message] {
        guard let ancla = store.anclaDelHilo,
              let i = mensajesÚnicos.firstIndex(where: { $0.id == ancla }) else { return [] }
        return Array(mensajesÚnicos[i...])
    }
    /// A dónde se «sigue el final». Con un mensaje recién mandado que aún cabe con su
    /// respuesta en la pantalla, el final ES ese mensaje arriba: se ancla por su `id` con
    /// `.top`, que no depende de medir el aire al punto. Medido: con el aire calculado a
    /// mano el mensaje se metía bajo la cabecera en el iPhone y quedaba corto en el
    /// simulador. Cuando la cola ya no cabe, se vuelve al fondo como siempre.
    private func reanclar(_ lector: ScrollViewProxy) {
        if let ancla = store.anclaDelHilo, altoDeLaCola + 57 < altoVisible {
            lector.scrollTo(ancla, anchor: .top)
        } else {
            lector.scrollTo(Self.fondo, anchor: .bottom)
        }
    }

    /// Lo que falta para que la cola llene la pantalla. Debajo de la cola hay: el
    /// espaciado al aire (14), el aire, el espaciado al fondo (14), el fondo (1) y el
    /// `padding(.bottom)` (28) = 57; y 8 más para que la burbuja no bese la cabecera.
    /// ⚠️ Restaba 42 y el mensaje subía hasta meterse bajo la cabecera.
    private var aireDebajo: CGFloat { max(0, altoVisible - altoDeLaCola - 57) }

    @ViewBuilder
    private func filaAnimada(_ mensaje: Message) -> some View {
        fila(mensaje).id(mensaje.id)
            // Sólo la entrega se anima al entrar: llega a mitad del turno
            // y aparecer de golpe se lee como un salto. Animar CADA trozo
            // del streaming haría temblar el hilo entero.
            .transition(esEntrega(mensaje)
                        ? .scale(scale: 0.94).combined(with: .opacity)
                        : .identity)
    }

    /// Si sigues el final, quédate en él.
    private func seguir(animado: Bool = false) {
        guard pegadoAbajo, !mensajesÚnicos.isEmpty else { return }
        bajarAnimado = animado
        bajar += 1
    }

    /// Al final del hilo, pase lo que pase: enviar, tocar el botón, cambiar de hilo.
    private func irAbajo(animado: Bool = false) {
        pegadoAbajo = true
        siguiendoElFinal = true
        seguir(animado: animado)
    }

    private var hiloVisible: String {
        // ⚠️ La clave LOCAL, no el `sessionId`: dos conversaciones nuevas del mismo
        // agente no lo tienen todavía y serían indistinguibles — cambiar entre ellas
        // dejaría el scroll a media altura, que se lee como "se colgó".
        "\(store.selectedAgentID)/\(store.claveDelHilo)"
    }

    /// Al fondo de verdad: ahora y otra vez cuando las filas ya se midieron.
    /// Al final del hilo, insistiendo hasta que la fila exista.
    ///
    /// ⚠️ Los reintentos no son paranoia: dentro de un `LazyVStack` una fila que está
    /// fuera de pantalla **no se ha creado todavía**, y `scrollTo` a algo que no existe no
    private var textoDelUltimo: Int {
        guard case .agent(let t, _, _) = store.messages.last?.kind else { return 0 }
        return t.count
    }

    @ViewBuilder
    private func fila(_ mensaje: Message) -> some View {
        switch mensaje.kind {
        case .user(let t, let adj, let steer):
            HStack {
                Spacer(minLength: 40)
                UserBubble(text: t, adjuntos: adj, vuelo: vuelo, steer: steer)
            }
        case .agent(let t, let tools, let trailing):
            // ⚠️ Aquí había una segunda mascota para cuando no hay texto y sí herramienta
            // corriendo. La quita `pieDeTrabajo`, que cubre TODO el turno y no sólo ese
            // instante; con las dos salían dos mascotas en la misma pantalla.
            AgentBubble(text: t, tools: tools, trailing: trailing,
                        vivo: store.currentTurn != nil && mensaje.id == mensajesÚnicos.last?.id)
        case .entrega(let e):
            HStack {
                EntregaCard(entrega: e)
                    .borrarConToqueLargo("¿Borrar «\(e.titulo)»?",
                                         consecuencia: "Se quita de esta conversación y de Artefactos. Vive sólo en este teléfono.") {
                        store.borrarEntrega(e.id)
                    }
                Spacer(minLength: 30)
            }
        case .prCard(let card):
            HStack {
                PRCard(card: card,
                       onApprove:        { Task { await store.respondToPR(card, approve: true) } },
                       onRequestChanges: { Task { await store.respondToPR(card, approve: false) } })
                Spacer(minLength: 30)
            }
        case .sistema(let causa):
            HStack {
                Spacer()
                Label(causa, systemImage: "clock")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.gInk3)
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.gFill, in: Capsule())
                Spacer()
            }
        case .typing:
            // La mascota pensando y, al lado, lo que está haciendo en una línea. Es el
            // indicador de carga del hilo (como el spinner de Claude bajo la herramienta).
            MascotaPensando(tone: store.selectedAgent?.tone ?? .lila,
                            texto: store.hiloActivo?.turno?.detail ?? "Pensando…")
                .accessibilityIdentifier("pensando")
        }
    }

    /// El compositor sólo trae controles que hacen algo.
    ///
    /// ⚠️ El `+` es SÓLO para adjuntar. Tuvo también "nueva conversación", "cambiar de
    /// agente" y "tu cuenta", y las tres estaban duplicadas: la primera es el botón grande
    /// de la hoja del agente, la segunda ES la pestaña Flota, y la tercera su engrane.
    /// Llegaron ahí cuando eran el único acceso. Con seis entradas había que leerlas todas
    /// para encontrar las tres que hacen lo que un `+` promete en cualquier app.
    ///
    /// Si "nueva conversación" acaba haciendo falta más cerca, la vuelta atrás NO es
    /// devolverla al menú —un menú con dos intenciones ya se probó peor— sino darle su
    /// propio icono aquí.
    private var compositor: some View {
        VStack(spacing: 8) {
            if !adjuntos.isEmpty || fallo != nil { antesDeMandar }
            capsula
            if adjuntando { tarjetasDeAdjuntar }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .photosPicker(isPresented: $abrirFotos, selection: $fotos, maxSelectionCount: 4,
                      matching: .images)
        .onChange(of: fotos) { _, nuevas in
            guard !nuevas.isEmpty else { return }
            Task {
                for item in nuevas {
                    let datos = try? await item.loadTransferable(type: Data.self)
                    // El nombre no viaja con la foto: se inventa uno legible, porque es lo
                    // que la persona va a ver en el chip y lo que el agente verá si sube.
                    agregar(datos.map {
                        Adjunto(nombre: "foto-\(adjuntos.count + 1).jpg", mime: "image/jpeg", datos: $0)
                    })
                }
                fotos = []
            }
        }
        .fileImporter(isPresented: $abrirArchivos, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { r in
            switch r {
            case .success(let urls): for u in urls { agregar(Adjunto(url: u)) }
            case .failure: fallo = "No pude abrir ese archivo."
            }
        }
        .fullScreenCover(isPresented: $abrirCamara) {
            CamaraPicker { d in
                agregar(Adjunto(nombre: "foto.jpg", mime: "image/jpeg", datos: d))
            }
            .ignoresSafeArea()
        }
    }

    /// De dónde sacar lo que se manda.
    ///
    /// ⚠️ Era un `Menu` nativo de iOS: tres renglones grises con iconos diminutos, que
    /// aparecían flotando encima del compositor tapándolo. Tres tarjetas grandes debajo
    /// son un blanco de dedo de verdad, se leen de un vistazo y no esconden lo que estabas
    /// escribiendo. Son las mismas tres puertas de siempre — los pickers no se tocaron.
    private var tarjetasDeAdjuntar: some View {
        HStack(spacing: 8) {
            tarjeta("Cámara", "camera") { abrirCamara = true }
            tarjeta("Foto", "photo") { abrirFotos = true }
            tarjeta("Documento", "paperclip") { abrirArchivos = true }
            // Programar sólo tiene sentido con una conversación que ya existe en gs.
            if agenda != nil {
                tarjeta("Programar", "clock.badge.checkmark") { abrirAgenda = true }
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity))
    }

    private func tarjeta(_ nombre: String, _ icono: String, _ accion: @escaping () -> Void) -> some View {
        Button {
            // Se cierra al elegir: la fila ya cumplió y dejarla abierta detrás del picker
            // significa encontrarla puesta al volver, sin que nadie la haya pedido.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { adjuntando = false }
            accion()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icono)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.gInk)
                Text(nombre)
                    .gChip()
                    .foregroundStyle(Color.gInk)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.cardH)
            // ⚠️ El MISMO radio y la MISMA sombra que la cápsula que tienen encima. Con un
            // 16 inventado convivían tres radios distintos en cuatro dedos de pantalla
            // —16, 18 y el 19 del tab bar—, y sin sombra parecían recortes de papel
            // debajo de una cápsula que sí flota.
            .background(Color.gCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("adjuntar-\(nombre)")
    }

    /// Los adjuntos que esperan, y el aviso si algo falló.
    private var antesDeMandar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !adjuntos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(adjuntos) { a in
                            AdjuntoChip(adjunto: a) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    adjuntos.removeAll { $0.id == a.id }
                                }
                            }
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 52)
            }
            if let fallo {
                Text(fallo).gCaption().foregroundStyle(Color.gDangerInk)
                    .padding(.horizontal, 4)
            }
        }
        .transition(.opacity)
    }

    /// UNA sola cápsula que se transforma por dentro.
    ///
    /// ⚠️ Primero puse una cápsula distinta para grabar, y estaba mal: son dos vistas que
    /// se sustituyen, o sea un salto. Lo que hace WhatsApp —y lo correcto— es que el
    /// compositor SIGA siendo el mismo y le cambie el contenido, con el control de la
    /// derecha en su sitio todo el rato.
    private var capsula: some View {
        HStack(spacing: 10) {
            if grabador.grabando {
                BarraDeGrabacion(segundos: grabador.segundos,
                                 onda: grabador.enVivo,
                                 haciaCancelar: haciaCancelar,
                                 bloqueado: vozBloqueada,
                                 alCancelar: { cancelarVoz() })
                    // El ORIGEN del vuelo. Con el mismo id que la burbuja y en la misma
                    // transacción animada, SwiftUI interpola una en la otra: lo que sueltas
                    // SE CONVIERTE en el mensaje, en vez de desaparecer para que aparezca
                    // otra cosa.
                    .matchedGeometryEffect(id: enVuelo.map { "voz-\($0)" } ?? "voz-ninguna",
                                           in: vuelo, isSource: false)
                    // Entra por la derecha, de donde viene el micrófono. Un fundido no dice
                    // de dónde salió esto; el deslizamiento sí, y es lo que hace WhatsApp.
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            } else {
                campoInterior.transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
            control
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
        .background(Color.gCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
        // Se tiñe de rojo según te acercas a cancelar: el aviso llega ANTES de soltar, que
        // es cuando todavía se puede rectificar.
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.gDanger.opacity(haciaCancelar * 0.12))
                .allowsHitTesting(false)
        }
    }

    private var haciaCancelar: Double {
        grabador.grabando && !vozBloqueada ? min(1, max(0, Double(-arrastre.width) / 90)) : 0
    }

    /// Los controles de la derecha: detener lo que hace y, si escribiste, mandar.
    ///
    /// ⚠️ Los DOS a la vez mientras trabaja. Antes era uno solo —con turno vivo sólo había
    /// detener— y para decirle algo más había que pararlo primero, aunque el servidor sepa
    /// meter el mensaje en el turno en marcha. Detener va a la izquierda y mandar pegado al
    /// borde: el botón de mandar no cambia de sitio nunca, que es lo que aprende el dedo.
    @ViewBuilder
    private var control: some View {
        HStack(spacing: 8) {
            if store.currentTurn != nil && !grabador.grabando { botonDetener }
            controlPrincipal
        }
    }

    private var botonDetener: some View {
        Button { Task { await store.stopTurn() } } label: {
            RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
                .fill(Color.gInk)
                .frame(width: 30, height: 30)
                .overlay {
                    RoundedRectangle(cornerRadius: 2.5).fill(Color.white)
                        .frame(width: 9, height: 9)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("detener")
    }

    @ViewBuilder
    private var controlPrincipal: some View {
        if grabador.grabando && vozBloqueada {
            Button(action: soltarVoz) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.primaryGradient, in: Circle())
            }
            .buttonStyle(.plain)
        } else if hayQueMandar {
            Button(action: enviar) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(subiendo
                                ? AnyShapeStyle(Color.gInk4.opacity(0.45))
                                : AnyShapeStyle(Theme.primaryGradient))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("enviar")
            .disabled(subiendo)
        } else if store.currentTurn == nil || grabador.grabando {
            microfono
        }
        // Con turno vivo y sin nada escrito, el único control es detener: un micrófono al
        // lado invita a grabar encima de lo que el agente está haciendo.
    }

    /// ⚠️ **Late con tu voz.** Un micrófono que no reacciona no dice si te está oyendo, y
    /// eso es lo primero que uno quiere saber al grabar. El nivel sale del medidor del
    /// grabador, el mismo que dibuja la onda.
    private var microfono: some View {
        let nivel = Double(grabador.onda.last ?? 0)
        return Image(systemName: "mic.fill")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background {
                Circle()
                    .fill(grabador.grabando
                          ? AnyShapeStyle(Color.gDanger)
                          : AnyShapeStyle(Theme.primaryGradient))
                    // El halo crece con la voz; el círculo sólo un poco, o el icono baila.
                    .overlay {
                        Circle()
                            .stroke(Color.gDanger.opacity(grabador.grabando ? 0.35 : 0), lineWidth: 3)
                            .scaleEffect(1 + nivel * 0.9)
                    }
            }
            // Sigue al DEDO. Es la mitad de la sensación: sin esto el gesto es un umbral
            // invisible y el botón se queda quieto mientras arrastras.
            .offset(x: grabador.grabando && !vozBloqueada ? min(0, arrastre.width) : 0,
                    y: grabador.grabando && !vozBloqueada ? min(0, max(-70, arrastre.height)) : 0)
            // Y se encoge conforme se acerca al bote, como si lo fuera a soltar dentro.
            .scaleEffect(grabador.grabando ? (1 + nivel * 0.18) * (1 - haciaCancelar * 0.35) : 1)
            .opacity(1 - haciaCancelar * 0.4)
            .animation(.easeOut(duration: 0.08), value: nivel)
            .contentShape(Circle())
            .gesture(gestoDeVoz)
    }

    private var gestoDeVoz: some Gesture {
        // Un solo `DragGesture` desde 0: tocar empieza a grabar, arrastrar decide, soltar
        // manda. Encadenar LongPress con Drag —lo que había— hacía que el primer instante
        // no respondiera y que el arrastre llegara en otro sistema de coordenadas: el gesto
        // se sentía muerto.
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !grabador.grabando {
                    escribiendo = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        grabador.empezar()
                    }
                }
                arrastre = v.translation
            }
            .onEnded { v in
                if v.translation.width < -90 { cancelarVoz() }
                // Arriba = manos libres, como WhatsApp: sigue grabando y aparecen la
                // papelera y el enviar.
                else if v.translation.height < -70 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        vozBloqueada = true
                        arrastre = .zero
                    }
                } else { soltarVoz() }
            }
    }

    /// Lo que va DENTRO de la cápsula cuando no se está grabando: el `+` y el campo.
    /// El control de la derecha lo pone `capsula`, porque es el que cambia de identidad.
    private var campoInterior: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    adjuntando.toggle()
                }
                if adjuntando { escribiendo = false }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(adjuntando ? Color.gInk : Color.gInk3)
                    // Gira a `×`: el mismo botón que abrió cierra, y el giro lo dice sin
                    // cambiar de icono ni mover nada de sitio.
                    .rotationEffect(.degrees(adjuntando ? 45 : 0))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("adjuntar")
            // Un archivo no se puede meter en el turno en marcha (gs steerea texto, no
            // adjuntos): mientras trabaja, adjuntar sólo llevaría a cortarle el trabajo.
            .disabled(store.currentTurn != nil)
            .opacity(store.currentTurn != nil ? 0.35 : 1)

            // ⚠️ Aquí NO va "nueva conversación". Estuvo, y eran dos entradas para lo
            // mismo: la barra de conversaciones de justo encima ya la lista todas y
            // termina en su «+», que es donde uno la busca — al final de la lista.

            TextField(store.currentTurn == nil ? "Mensaje" : "Dile algo más…", text: $borrador, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineLimit(1...4)
                .focused($escribiendo)
                .submitLabel(.send)
                .onSubmit(enviar)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Listo") { escribiendo = false }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.gPrimary)
                    }
                }
        }
    }

    private var hayQueMandar: Bool {
        !borrador.trimmingCharacters(in: .whitespaces).isEmpty || !adjuntos.isEmpty
    }

    /// ¿Mandar esto ahora mismo le tira al agente el trabajo que lleva?
    ///
    /// Con el turno vivo hay dos caminos: el mensaje ENTRA en él («steer») o lo corta y
    /// empieza de nuevo. Sólo entra si el agente lo soporta y si no van adjuntos —gs no
    /// steerea archivos—.
    ///
    /// ⚠️ Si todavía no sabemos qué soporta (`puedeSteer == nil`, las `caps` no han
    /// llegado), se trata como que NO: preguntar de más cuesta un toque, darlo por hecho
    /// cuesta el turno que el agente llevaba media hora trabajando.
    private var mandarCortaElTurno: Bool {
        guard store.currentTurn != nil else { return false }
        return !adjuntos.isEmpty || store.canalActivo?.puedeSteer != true
    }

    private func enviar() {
        guard hayQueMandar, !subiendo else { return }
        // ⚠️ Aquí había un candado: con turno vivo no se mandaba nada y había que detener
        // primero. Lo justificaba el gs de entonces, que cancelaba el turno anterior sin
        // avisar. Hoy gs sabe INYECTAR el mensaje en el turno en vuelo, así que el candado
        // se cambió por lo único que hacía falta: avisar cuando de verdad va a cortar.
        if mandarCortaElTurno {
            // ⚠️ El teclado PRIMERO. Con el teclado arriba, el diálogo sale encima de él y
            // su botón de cancelar queda debajo: un aviso destructivo del que sólo se ve
            // la opción destructiva. Lo cazó el recorrido, no un ojo.
            escribiendo = false
            avisoDeCorte = true
            return
        }
        mandarYa()
    }

    /// Lo de mandar, ya sin preguntas.
    private func mandarYa() {
        let texto = borrador
        let envio = adjuntos
        borrador = ""
        // El teclado se va y el hilo baja: escribiste, ya está mandado, lo que toca es
        // mirar. Dejarlo abierto tapaba media conversación justo cuando llega la respuesta.
        escribiendo = false
        // Acabas de escribir: se sigue el final aunque estuvieras arriba. El mensaje se
        // añade después (el envío es asíncrono) y `seguir` lo baja al llegar.
        pegadoAbajo = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            adjuntos = []
            adjuntando = false
        }
        fallo = nil
        // ⚠️ `subiendo` gatea el botón mientras los archivos viajan a la máquina del
        // agente. Sin esto se pueden encolar dos turnos con el mismo adjunto.
        // Todo adjunto se sube ahora, imágenes incluidas.
        subiendo = !envio.isEmpty
        Task {
            await store.send(texto, adjuntos: envio)
            subiendo = false
            // La subida falla dentro del turno, así que el aviso sale de ahí: el store
            // pinta el error en el hilo. Aquí sólo se devuelven los adjuntos para que la
            // persona pueda reintentar sin volver a elegirlos.
            if store.ultimoEnvioFallo {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    adjuntos = envio
                    borrador = texto
                }
                fallo = "No se pudo mandar. Inténtalo otra vez."
            }
        }
    }

    /// Se soltó el micrófono: la nota se manda sola.
    ///
    /// ⚠️ "Parar es enviar", como en Teams. Dejarla en el compositor para que la persona le
    /// dé a un segundo botón convierte un gesto de dos segundos en uno de cuatro, y el
    /// motivo de hablar en vez de escribir era justamente ir rápido.
    private func cancelarVoz() {
        // Se descarta con un resorte, no de golpe: el gesto acaba donde el ojo lo estaba
        // siguiendo. `.snappy` es más seco que la spring de selección — cancelar tiene que
        // sentirse resuelto, no elástico.
        withAnimation(.snappy(duration: 0.22)) {
            grabador.cancelar()
            vozBloqueada = false
            arrastre = .zero
        }
    }

    private func soltarVoz() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            vozBloqueada = false
            arrastre = .zero
        }
        guard let clip = grabador.terminar() else { grabador.cancelar(); return }
        let nota = Adjunto(voz: clip)
        // Se marca ANTES de mandar: cuando el store añada el mensaje, el destino ya existe
        // y las dos vistas comparten id.
        enVuelo = nota.id
        let texto = borrador
        borrador = ""
        // Igual que al enviar escrito: teclado fuera y al final del hilo.
        escribiendo = false
        // Acabas de escribir: se sigue el final aunque estuvieras arriba. El mensaje se
        // añade después (el envío es asíncrono) y `seguir` lo baja al llegar.
        pegadoAbajo = true
        fallo = nil
        subiendo = true
        Task {
            await store.send(texto, adjuntos: [nota])
            subiendo = false
            // Ya aterrizó: se suelta el emparejamiento para que la siguiente nota no herede
            // la geometría de ésta.
            enVuelo = nil
        }
    }

    private func agregar(_ a: Adjunto?) {
        guard let a else { fallo = "No pude leer ese archivo."; return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            adjuntos.append(a)
            fallo = nil
        }
    }
}

/// La mascota latiendo, con una línea opcional de lo que hace.
struct MascotaPensando: View {
    let tone: AgentTone
    let texto: String?
    @State private var late = false

    var body: some View {
        HStack(spacing: 10) {
            GhostyMascot(tone: tone, height: 26)
                .scaleEffect(late ? 1.1 : 0.92)
                .opacity(late ? 1 : 0.75)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { late = true }
                }
            if let texto {
                Text(texto).gMeta().foregroundStyle(Color.gInk3).lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: texto)
            }
            Spacer()
        }
        .padding(.leading, 4)
    }
}

/// Mide el alto de la vista a la que se pone de fondo.
private struct MedidorDeAlto: View {
    @Binding var alto: CGFloat
    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { alto = g.size.height }
                .onChange(of: g.size.height) { _, h in alto = h }
        }
    }
}

/// Alto de lo que va desde tu último mensaje, para el aire que lo clava arriba.
private struct AltoDeLaCola: PreferenceKey {
    static var defaultValue: CGFloat = 0
    // ⚠️ `max`, no «el último»: los hermanos que no ponen la clave aportan 0 y con
    // «el último gana» la medida llegaba siempre en cero.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Alto del contenido del hilo, para re-anclar abajo cuando crece tarde.
private struct AltoDelHilo: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
