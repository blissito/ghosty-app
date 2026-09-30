import PhotosUI
import SwiftUI

struct ConversationView: View {
    let store: LiveAgentStore
    var onOpenSheet: () -> Void
    /// Abre el historial de conversaciones (hoja de `RootView`). `nil` = sin botón.
    var onHistorial: (() -> Void)? = nil
    /// Regresa a «Chats». Con él, la cabecera lleva la flecha de atrás en vez del historial.
    var onVolver: (() -> Void)? = nil

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
    /// La hoja «Agregar» y el overlay de voz se pintan en la raíz (ver `CapaDeChat`).
    @Environment(CapaDeChat.self) private var capa: CapaDeChat?
    /// ¿La grabación en curso es la del overlay «Te escucho…» (un toque al micrófono)?
    @State private var vozConOverlay = false
    /// Cuándo empezó el toque al micrófono: menos de ~0.35 s sin arrastrar es un TOQUE.
    @State private var inicioDelToque: Date?
    /// Los mensajes que ya estaban en pantalla: sólo los NUEVOS entran con `gin`. Sin esto
    /// abrir un hilo largo lo hacía aparecer entero, y cada envío —que mueve mensajes de
    /// un contenedor a otro alrededor del ancla— los volvía a animar.
    @State private var yaVistos: Set<String> = []
    @State private var semillaDeVistos = ""
    @State private var subiendo = false
    /// Mandar esto le corta el trabajo al agente: se pregunta antes.
    @State private var avisoDeCorte = false
    @State private var grabador = GrabadorDeVoz()
    /// Cuánto se ha arrastrado desde el micrófono. Izquierda cancela, arriba bloquea.
    @State private var arrastre: CGSize = .zero
    /// Manos libres: se soltó el dedo y la grabación sigue.
    @State private var vozBloqueada = false
    /// Se canceló deslizando SIN soltar: el micrófono cae al bote (`MicAlBote`) y el resto
    /// del gesto ya no cuenta hasta que se levante el dedo.
    @State private var alBote = false
    @State private var gestoCancelado = false
    /// El globito «Mantén presionado para grabar…» sobre el micrófono, tras un toque corto.
    @State private var pistaDeVoz = false
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
    /// Permiso de IA de terceros (5.1.2(i)): sin él, el envío abre la hoja y espera.
    @AppStorage(AIConsentSheet.key) private var consentGiven = false
    @State private var pendingSend: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if let agente = store.selectedAgent {
                AgentHeader(agent: agente, estado: store.estado(de: agente.id),
                            onTap: { escribiendo = false; onOpenSheet() },
                            onNueva: { store.nuevaConversacion() },
                            onHistorial: onHistorial.map { abrir in { escribiendo = false; abrir() } },
                            puntoHistorial: store.hayPendientes,
                            onVolver: onVolver.map { volver in { escribiendo = false; volver() } },
                            pendientesAtras: onVolver == nil ? 0 : store.chatsSinLeer)
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
            if let p = store.threadPermission {
                PermissionCard(request: p) { d in Task { await store.decide(p, d) } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

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
        // El overlay de voz sigue a la grabación: si ésta acaba por otro lado, se va.
        .onChange(of: grabador.grabando) { _, graba in if !graba { cerrarOverlayDeVoz() } }
        .onDisappear {
            if vozConOverlay { cancelarVoz(); cerrarOverlayDeVoz() }
        }
        // Lo que llegó de la hoja de compartir («Abrir en Ghosty»): al compositor.
        .onChange(of: store.compartidoListo?.id, initial: true) { _, id in
            guard id != nil, let r = store.compartidoListo else { return }
            store.compartidoListo = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                adjuntos += r.adjuntos
                if borrador.isEmpty { borrador = r.texto }
            }
        }
        // Lo que ya estaba al abrir no entra animado; lo que llega, sí (`gin`).
        .onAppear { sembrarVistos() }
        .onChange(of: hiloVisible) { _, _ in sembrarVistos() }
        .onChange(of: store.messages.count) { _, _ in
            Task { @MainActor in sembrarVistos() }
        }
        .task { await ganchosDelChat() }
    }

    /// Ganchos de desarrollo para poder MIRAR el chat en el simulador sin tocarlo:
    /// `GHOSTY_DEMO_CHAT=1` (pasos, tabla y archivo) o `=vacio` (el chat vacío), `GHOSTY_AGREGAR=1` (la hoja) y
    /// `GHOSTY_VOZ=1` (el overlay «Te escucho…», sin grabar).
    private func ganchosDelChat() async {
        if DemoData.encendido {
            switch Gancho.valor("GHOSTY_DEMO_CHAT") {
            case "1"?: store.hiloActivo?.mensajes = DemoDelChat.mensajes()
            // Hasta la tabla: para fotografiarla sin poder hacer scroll.
            case "tabla"?: store.hiloActivo?.mensajes = Array(DemoDelChat.mensajes().prefix(4))
            case "vacio"?: store.nuevaConversacion()
            default: break
            }
        }
        try? await Task.sleep(for: .milliseconds(600))
        if Gancho.valor("GHOSTY_AGREGAR") == "1" { abrirAgregar() }
        if Gancho.valor("GHOSTY_VOZ") == "1" {
            vozConOverlay = true
            capa?.cubrir(OverlayDeVoz(grabador: grabador,
                                      alTerminar: { cerrarOverlayDeVoz() },
                                      alDescartar: { cerrarOverlayDeVoz() }))
        }
    }

    /// Lo que se le puede encargar, del diseño. Tocar una la MANDA (el prototipo lo hace
    /// así: el vacío es el onboarding y la sugerencia es el primer encargo). La del PDF
    /// no tiene sentido sin un PDF: abre «Agregar» con el texto ya puesto.
    private struct Sugerencia: Identifiable {
        let titulo: String
        let sub: String
        let encargo: String
        let icono: GhostyStrokeIcon
        var pideArchivo = false
        var id: String { titulo }
    }

    private static let sugerencias = [
        Sugerencia(titulo: "Resume este PDF", sub: "Sube un archivo y te lo explico",
                   encargo: "Resume este PDF", icono: ChatIcons.pdf, pideArchivo: true),
        Sugerencia(titulo: "Búscame precios", sub: "Comparo proveedores en una tabla",
                   encargo: "Búscame precios y hazme una tabla", icono: ChatIcons.tabla),
        Sugerencia(titulo: "Arma una cotización", sub: "Con tu catálogo, lista en PDF",
                   encargo: "Arma una cotización en PDF", icono: ChatIcons.cotizacion),
    ]

    /// El vacío del hilo: la mascota con su aro, «¿Qué le encargamos hoy?» y las
    /// sugerencias, pegado ABAJO (junto al compositor), como el prototipo.
    ///
    /// ⚠️ NO explica cómo funciona por dentro («tu caja», «markdown»): quien abre la app
    /// por primera vez necesita saber qué pedirle, no cómo está hecha.
    private var primeraVez: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 76 con aro de 8 (`#ECEAFB`) y la sombra morada `0 10px 30px rgba(91,75,214,.25)`.
            AgentAvatar(tone: store.selectedAgent?.tone ?? .lila, size: 76)
                .background(Circle().fill(Color.gPrimaryRing).padding(-8))
                .shadow(color: Theme.Shadow.morado.opacity(0.25), radius: 15, y: 10)
                .padding(.leading, 8 + 8)
                .padding(.top, 8)
                .padding(.bottom, 26)
                .gIn()

            Text("¿Qué le encargamos hoy?")
                .font(.system(size: 32, weight: .heavy))
                .tracking(-0.96)
                .lineSpacing(-2)
                .foregroundStyle(Color.gInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .gIn(delay: 0.04)
            Text("No solo contesta: opera tus herramientas y te avisa cuando termina.")
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(Color.gInk2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 10)
                .padding(.bottom, 22)
                .gIn(delay: 0.08)

            VStack(spacing: 8) {
                ForEach(Array(Self.sugerencias.enumerated()), id: \.element.id) { i, s in
                    tarjetaDeSugerencia(s)
                        .gIn(delay: 0.12 + Double(i) * 0.05)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.bottom, 16)
        // Pegado abajo: el vacío ocupa lo que se ve del hilo y se alinea al fondo. Lo que
        // el hilo pone debajo (cinco huecos de 14, el fondo y el `padding` de 28) es
        // invisible: se le come con padding negativo para que el vacío quede junto al
        // compositor, como el prototipo, y sin sobrar scroll.
        .frame(minHeight: altoVisible, alignment: .bottom)
        .padding(.bottom, -(5 * 14 + 1 + 28))
        .accessibilityIdentifier("chat-vacio")
    }

    private func tarjetaDeSugerencia(_ s: Sugerencia) -> some View {
        Button { usarSugerencia(s) } label: {
            HStack(spacing: 12) {
                s.icono.dibujo(Color.gPrimary, size: 22, ancho: 1.7)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.titulo)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                    Text(s.sub)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.gInk3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ChatIcons.chevronDerecha.dibujo(Color.gChevron, size: 16)
            }
            .padding(.vertical, 13)
            .padding(.leading, 10).padding(.trailing, 14)
            .ghostyCard(radius: Theme.Radius.card)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(GhostyPressStyle(scale: 0.98, pressedBackground: nil))
        .accessibilityIdentifier("sugerencia-\(s.titulo)")
    }

    private func usarSugerencia(_ s: Sugerencia) {
        borrador = s.encargo
        if s.pideArchivo && adjuntos.isEmpty {
            abrirAgregar()
        } else {
            enviar()
        }
    }

    /// «N herramientas conectadas»: las integraciones REALES de la cuenta. Lleva a la
    /// pestaña de Integraciones. Sin ninguna conectada, invita a conectar.
    private var chipDeHerramientas: some View {
        let n = store.conectores.filter(\.conectado).count
        return Button { store.pestanaPedida = .connectors } label: {
            HStack(spacing: 6) {
                Circle().fill(n > 0 ? Color.gGreen : Color.gInk4).frame(width: 7, height: 7)
                Text(n == 0 ? "Conecta tus herramientas"
                     : n == 1 ? "1 herramienta conectada" : "\(n) herramientas conectadas")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.gInk2)
                ChatIcons.chevronChico.dibujo(Color.gInk3, size: 10, ancho: 1.6)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.gPressPill)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chip-herramientas")
        .transition(.opacity)
    }

    /// ¿Se enseña el vacío? Sin mensajes y sin conversación que traer del servidor.
    private var esVacio: Bool {
        mensajesÚnicos.isEmpty && store.hiloActivo?.sesionID == nil
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

    /// Los que se pintan: todos menos las entregas de imagen que ya se revelan DENTRO de la
    /// caja «Creando imagen» de su turno (si salieran también sueltas, la imagen nacería
    /// dos veces y la de abajo empujaría el hilo).
    private var mensajesVisibles: [Message] {
        let todos = mensajesÚnicos
        let dentro = Set(todos.compactMap { imagenDelTurno($0, en: todos).entrega })
        guard !dentro.isEmpty else { return todos }
        return todos.filter { !dentro.contains($0.id) }
    }

    /// La caja de imagen de una respuesta: si su turno corrió una herramienta de imagen, en
    /// qué va (creando, lista con la entrega del MISMO turno, o fallo), y qué entrega se
    /// revela dentro (esa fila no se pinta suelta).
    private func imagenDelTurno(_ m: Message, en todos: [Message]) -> (estado: ImagenDelTurno?, entrega: String?) {
        guard case .agent(_, let tools, _) = m.kind,
              let h = tools?.herramientas.last(where: \.esImagen),
              let i = todos.firstIndex(where: { $0.id == m.id }) else { return (nil, nil) }
        // La entrega de imagen que llegó después de esta respuesta y antes de tu siguiente mensaje.
        for sig in todos[(i + 1)...] {
            if case .user = sig.kind { break }
            if case .entrega(let e) = sig.kind, e.esImagen { return (.lista(e), sig.id) }
        }
        switch h.estado {
        case .fallida:
            let linea = h.salida?.split(separator: "\n").first.map(String.init) ?? ""
            return (.fallo(linea.isEmpty ? "No se pudo crear la imagen." : linea), nil)
        case .corriendo:
            return (.creando(editando: h.editaImagen), nil)
        case .hecha:
            // Terminó pero la entrega no ha llegado: la caja espera en su sitio mientras el
            // turno sigue vivo (si se quitara, la imagen nacería más abajo: brinco).
            return (esLaQueEscribe(m) ? .creando(editando: h.editaImagen) : nil, nil)
        }
    }

    /// «Editar» de una imagen: el compositor queda con «Edita esta imagen: » y la imagen
    /// como adjunto.
    private func editarImagen(_ a: Adjunto?) {
        borrador = "Edita esta imagen: "
        if let a { agregar(a) }
        escribiendo = true
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
            TapGesture().onEnded { escribiendo = false }
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
        // ⚠️ Al cerrar el turno el ancla NO se suelta: el par pregunta/respuesta se queda
        // tal como se generó. Soltarla recogía el aire y el hilo se reajustaba al final
        // —la pregunta se iba por arriba justo al terminar de leer—. La cambia el
        // siguiente envío, que pone la suya.
        // Un mensaje que se mandó y la app murió antes de que existiera la
        // conversación vuelve al compositor, con el aviso, en vez de desaparecer.
        .task(id: store.selectedAgentID) {
            if borrador.isEmpty, let perdido = BorradorPendiente.recoger(de: store.selectedAgentID) {
                borrador = perdido
                // Un límite del plan lo explica su hoja; aquí sólo el fallo de verdad.
                if store.limitNotice == nil { fallo = "No se pudo mandar. Inténtalo otra vez." }
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
        .sheet(isPresented: Binding(get: { pendingSend != nil },
                                    set: { if !$0 { pendingSend = nil } })) {
            AIConsentSheet(onAccept: { [pendingSend] in pendingSend?() })
        }
        // ⚠️ Se dice lo que CUESTA, no «¿estás seguro?». Este agente no sabe meter tu
        // mensaje en lo que ya hace (o le mandas un archivo, que no se puede inyectar):
        // mandarlo ahora tira lo que lleva. Quien sí sabe, no pregunta nada.
        //
        // ⚠️ `alert` y no `confirmationDialog`: la hoja de abajo se ancla sobre el
        // compositor y su botón de cancelar quedaba FUERA de la pantalla —un aviso
        // destructivo del que sólo se veía la opción destructiva—. Lo cazó el recorrido.
        .sheet(isPresented: Binding(get: { store.limitNotice != nil },
                                    set: { if !$0 { store.limitNotice = nil } })) {
            LimitSheet(message: store.limitNotice ?? "") {
                // Tras cerrar esta hoja: abrir la del agente, donde está el uso.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpenSheet() }
            }
        }
        .alert("\(store.selectedAgent?.name ?? "Tu agente") está con lo anterior",
               isPresented: $avisoDeCorte) {
            Button("Mandar y empezar de nuevo", role: .destructive) { mandarYa() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Pierde lo que lleva hecho y arranca otra vez con lo que acabas de escribir.")
        }
        } // ScrollViewReader
    }

    /// Lo que se ve mientras la conversación viene en camino. No dice «vacío», que sería
    /// mentira, ni finge mensajes: dice que está llegando.
    private var trayendoElHilo: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Trayendo la conversación…").gMeta()
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("trayendo-el-hilo")
    }

    /// El hilo no llegó: se dice y se ofrece otra vez, en vez de girar para siempre.
    private func loadFailed(_ error: String, _ hilo: Hilo) -> some View {
        VStack(spacing: 12) {
            Text(error).gMeta()
            Button("Reintentar") { store.retryLoad(hilo) }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("hilo-no-llego")
    }

    /// El contenido del scroll, aparte: dentro del `body` el compilador no lo tipaba.
    @ViewBuilder
    private func contenidoDelHilo(_ lector: ScrollViewProxy) -> some View {
                VStack(spacing: 14) {
            if mensajesÚnicos.isEmpty {
                // ⚠️ Una conversación que YA EXISTE en el servidor y todavía no se ha
                // traído NO es una conversación nueva. Llegando por un push tarda un par
                // de segundos en llegar, y durante ese rato se pintaba «¿En qué te
                // ayudo?»: tocabas el aviso de una respuesta y aparecías en lo que parecía
                // un hilo en blanco. Medido en el iPhone: 2.7 s de «conversación nueva».
                if let hilo = store.hiloActivo, hilo.sesionID != nil, let error = hilo.loadError {
                    loadFailed(error, hilo).padding(.top, 90)
                } else if store.hiloActivo?.sesionID != nil {
                    trayendoElHilo.padding(.top, 90)
                } else {
                    primeraVez
                }
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
            // El indicador entra sin prisa: la respuesta tarda segundos de todos modos.
            // Antes no había animación que recogiera el `.transition` y salía de golpe.
            .animation(.easeOut(duration: 0.5), value: store.currentTurn != nil)
            .background(GeometryReader { g in
                Color.clear.preference(key: AltoDeLaCola.self, value: g.size.height)
            })
            // ⚠️ SIEMPRE presente y con altura animable. `defaultScrollAnchor(.bottom)`
            // sigue el crecimiento del contenido al instante, así que un aire que aparece
            // de golpe es un salto seco por mucho `scrollTo` animado que venga después;
            // si la ALTURA anima de 0 al aire, el anclaje de abajo la sigue y la subida se
            // ve.
            // Sin el mensaje ancla en el hilo (se recargó con otros ids) no hay nada que
            // clavar: el aire sería la pantalla entera en blanco.
            Color.clear.frame(height: desdeElAncla.isEmpty ? 0 : aireDebajo)
            // El fondo de verdad: a donde se baja. Un mensaje largo que crece
            // con el streaming no cambia de id, y «bajar» a un id que ya es
            // el ancla no mueve nada.
            Color.clear.frame(height: 1).id(Self.fondo)
        }
        .padding(.horizontal, 18)
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
        // ⚠️ Un HUECO de alto fijo que sigue ahí al cerrar el turno mientras tu mensaje siga
        // anclado: si la cola encogiera al terminar, con una respuesta más alta que la
        // pantalla el hilo bajaría de golpe. Al cerrar el turno NADA se mueve; el siguiente
        // envío pone su ancla y el hueco se va con ella. Los puntos entran y salen DENTRO
        // del hueco, sólo con opacidad: su salida no ocupa sitio de más.
        if store.currentTurn != nil || !desdeElAncla.isEmpty {
            ZStack(alignment: .leading) {
                if store.currentTurn != nil {
                    // Los tres puntos (`gdot`) en el margen de la respuesta.
                    TypingBubble(texto: textoDelPie)
                        // ⚠️ `combine` ANTES del identificador: sin eso el `HStack` no es un
                        // elemento de accesibilidad y el identificador no existe para nadie
                        // —ni para VoiceOver ni para el recorrido que comprueba que el
                        // indicador sigue.
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pensando")
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: TypingBubble.alto, maxHeight: TypingBubble.alto,
                   alignment: .leading)
        }
    }

    /// ¿Es ésta la respuesta que está creciendo? La del turno en curso por su id, y si el
    /// id todavía no se conoce, la última del hilo.
    private func esLaQueEscribe(_ m: Message) -> Bool {
        guard store.currentTurn != nil else { return false }
        if let viva = store.hiloActivo?.respuestaEnCursoID { return m.id == viva }
        return m.id == mensajesÚnicos.last?.id
    }

    /// Lo que hace, salvo que la línea de pasos ya lo esté diciendo: dos frases para el
    /// mismo hecho, una encima de otra, es de lo que más ensucia esta pantalla.
    private var textoDelPie: String? {
        // La tarjeta de pasos ya lo dice (corriendo o «pensando el siguiente paso»).
        if case .agent(_, let tools, _) = mensajesVisibles.last?.kind, (tools?.count ?? 0) > 0 {
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
        let visibles = mensajesVisibles
        guard let ancla = store.anclaDelHilo,
              let i = visibles.firstIndex(where: { $0.id == ancla }) else { return visibles }
        return Array(visibles[..<i])
    }
    private var desdeElAncla: [Message] {
        let visibles = mensajesVisibles
        guard let ancla = store.anclaDelHilo,
              let i = visibles.firstIndex(where: { $0.id == ancla }) else { return [] }
        return Array(visibles[i...])
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
            // `gin .3s`: todo mensaje NUEVO entra subiendo 8 pt con fade, como el
            // prototipo. Los que ya estaban al abrir el hilo no (ver `yaVistos`), y la
            // animación es de la FILA al nacer, no de cada trozo del streaming.
            .modifier(EntradaGin(animar: semillaDeVistos == hiloVisible && !yaVistos.contains(mensaje.id)))
            .transition(esEntrega(mensaje)
                        ? .scale(scale: 0.94).combined(with: .opacity)
                        : .identity)
    }

    /// Da por vistos los mensajes que hay ahora. Al abrir un hilo, todos; después, cada
    /// vez que llega uno (ya nació animado, y así no se re-anima al moverse de sitio).
    private func sembrarVistos() {
        yaVistos.formUnion(store.messages.map(\.id))
        semillaDeVistos = hiloVisible
    }

    /// Si sigues el final, quédate en él.
    ///
    /// ⚠️ Exige las DOS condiciones. `siguiendoElFinal` lo apaga tu dedo al arrastrar
    /// hacia arriba; `pegadoAbajo` lo deduce el sistema del ancla del scroll. Aquí sólo
    /// se miraba la segunda, y con el aire del final el ancla se quedaba en el último
    /// mensaje aunque hubieras subido: cada trozo de la respuesta te devolvía al fondo y
    /// no había forma de leer hacia arriba mientras el agente escribía. El dedo manda.
    private func seguir(animado: Bool = false) {
        guard siguiendoElFinal, pegadoAbajo, !mensajesÚnicos.isEmpty else { return }
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
    /// La última respuesta del agente: la única que lleva botón de copiar.
    private var lastReplyID: Message.ID? {
        mensajesÚnicos.last(where: { if case .agent = $0.kind { return true } else { return false } })?.id
    }

    private var textoDelUltimo: Int {
        guard case .agent(let t, _, _) = store.messages.last?.kind else { return 0 }
        return t.count
    }

    @ViewBuilder
    private func fila(_ mensaje: Message) -> some View {
        switch mensaje.kind {
        case .user(let t, let adj, let steer):
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                UserBubble(text: t, adjuntos: adj, vuelo: vuelo, steer: steer)
            }
        case .agent(let t, let tools, let trailing):
            // ⚠️ Aquí había una segunda mascota para cuando no hay texto y sí herramienta
            // corriendo. La quita `pieDeTrabajo`, que cubre TODO el turno y no sólo ese
            // instante; con las dos salían dos mascotas en la misma pantalla.
            AgentBubble(id: mensaje.id, text: t, tools: tools, trailing: trailing,
                        vivo: esLaQueEscribe(mensaje),
                        showCopy: mensaje.id == lastReplyID,
                        tone: store.selectedAgent?.tone ?? .lila,
                        imagen: imagenDelTurno(mensaje, en: mensajesÚnicos).estado,
                        alEditarImagen: { editarImagen($0) })
        case .entrega(let e):
            // En el margen de la respuesta (ya sin columna de avatar): lo entregó él.
            HStack(spacing: 0) {
                EntregaCard(entrega: e)
                    .borrarConToqueLargo("¿Borrar «\(e.titulo)»?",
                                         consecuencia: "Se quita de esta conversación y de Archivos. Vive sólo en este teléfono.") {
                        store.borrarEntrega(e.id)
                    }
                Spacer(minLength: 0)
            }
        case .prCard(let card):
            HStack(spacing: 0) {
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
            TypingBubble(tone: store.selectedAgent?.tone ?? .lila,
                         texto: store.hiloActivo?.turno?.detail ?? "Pensando…")
                .accessibilityElement(children: .combine)
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
            // «N herramientas conectadas», sólo en el vacío (como el prototipo).
            if esVacio && adjuntos.isEmpty && fallo == nil { chipDeHerramientas }
            capsula
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.2), value: esVacio)
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

    /// La hoja «Agregar» del diseño: Foto, Cámara, Archivo y, con su flag, Programar.
    ///
    /// ⚠️ Fue una fila de tres tarjetas debajo del compositor (y antes un `Menu`). El
    /// diseño la pasa a hoja: es la misma para todo lo que «se agrega» y deja el
    /// compositor en su sitio. Los pickers son los mismos de siempre.
    private func abrirAgregar() {
        escribiendo = false
        guard let capa else { abrirArchivos = true; return }
        let programar = agenda != nil && AppConfig.shared.isOn("agenda")
        capa.abrirHoja("Agregar", identificador: "hoja-agregar") {
            VStack(spacing: 6) {
                filaDeAgregar("Foto", "De tu galería", ChatIcons.foto) { abrirFotos = true }
                filaDeAgregar("Cámara", "Toma una foto o escanea", ChatIcons.camara) { abrirCamara = true }
                filaDeAgregar("Archivo", "PDF, Excel, Word", ChatIcons.documento) { abrirArchivos = true }
                // Programar sólo tiene sentido con una conversación que ya existe en gs.
                if programar {
                    filaDeAgregar("Programar", "Que lo haga solo, más tarde", ChatIcons.reloj) {
                        abrirAgenda = true
                    }
                }
            }
        }
    }

    private func filaDeAgregar(_ titulo: String, _ sub: String, _ icono: GhostyStrokeIcon,
                               _ accion: @escaping () -> Void) -> some View {
        GhostySheetRow(title: titulo, subtitle: sub, action: {
            capa?.cerrarHoja()
            // El picker del sistema sale cuando la hoja ya se está yendo: presentarlo
            // encima de la animación de salida lo hacía aparecer a medias.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { accion() }
        }) {
            icono.dibujo(Color.gInk, size: 22, ancho: 1.7)
                .frame(width: 36, height: 36)
        }
        .accessibilityIdentifier("adjuntar-\(titulo)")
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
                    .padding(.vertical, 4)
                }
                .frame(height: 58)
            }
            if let fallo {
                // El envío que no salió: el texto y los adjuntos ya volvieron al
                // compositor; aquí se dice y se ofrece mandarlo otra vez.
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.gDanger)
                    Text(fallo)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.gDangerInk)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if hayQueMandar {
                        Button("Reintentar", action: enviar)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.gPrimary)
                            .accessibilityIdentifier("reintentar-envio")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.gDangerTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.gIn)
            }
        }
        .transition(.opacity)
    }

    /// UNA sola cápsula que se transforma por dentro: blanca, r28, padding 6, borde fino
    /// y la sombra suave del diseño.
    ///
    /// ⚠️ Primero puse una cápsula distinta para grabar, y estaba mal: son dos vistas que
    /// se sustituyen, o sea un salto. Lo que hace WhatsApp —y lo correcto— es que el
    /// compositor SIGA siendo el mismo y le cambie el contenido, con el control de la
    /// derecha en su sitio todo el rato.
    private var capsula: some View {
        HStack(spacing: 6) {
            if alBote {
                MicAlBote { withAnimation(.snappy(duration: 0.22)) { alBote = false } }
                    .padding(.leading, 8)
                    .transition(.opacity)
            } else if grabador.grabando && vozBloqueada {
                // Bloqueada: dos filas con su propio enviar; el control de la derecha sobra.
                BloqueDeGrabacion(segundos: grabador.segundos,
                                  onda: grabador.enVivo,
                                  pausado: grabador.pausado,
                                  alTirar: { cancelarVoz() },
                                  alPausar: { grabador.pausado ? grabador.reanudar() : grabador.pausar() },
                                  alEnviar: { soltarVoz() })
                    .matchedGeometryEffect(id: enVuelo.map { "voz-\($0)" } ?? "voz-ninguna",
                                           in: vuelo, isSource: false)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)),
                                            removal: .opacity))
            } else if grabador.grabando {
                BarraDeGrabacion(segundos: grabador.segundos, haciaCancelar: haciaCancelar)
                    .padding(.leading, 8)
                    // El ORIGEN del vuelo. Con el mismo id que la burbuja y en la misma
                    // transacción animada, SwiftUI interpola una en la otra: lo que sueltas
                    // SE CONVIERTE en el mensaje, en vez de desaparecer para que aparezca
                    // otra cosa.
                    .matchedGeometryEffect(id: enVuelo.map { "voz-\($0)" } ?? "voz-ninguna",
                                           in: vuelo, isSource: false)
                    // Entra por la derecha, de donde viene el micrófono.
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            } else {
                campoInterior.transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
            if !(grabador.grabando && vozBloqueada) { control.zIndex(1) }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hayQueMandar)
        .padding(6)
        .frame(minHeight: 56)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
                .strokeBorder(Color.gSeparator, lineWidth: 1)
        }
        .ghostySoftShadow()
        // El globito de un toque corto, encima del micrófono (como WhatsApp).
        .overlay(alignment: .topTrailing) {
            if pistaDeVoz {
                Text("Mantén presionado para grabar y suelta para enviar")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.gInk)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.gCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .ghostySoftShadow()
                    .offset(y: -48)
                    .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        // Se tiñe de rojo según te acercas a cancelar: el aviso llega ANTES de que se
        // cancele, que es cuando todavía se puede rectificar.
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
                .fill(Color.gDanger.opacity(haciaCancelar * 0.1))
                .allowsHitTesting(false)
        }
    }

    /// Cuánto hay que deslizar a la izquierda para cancelar sin soltar (WhatsApp ~120 pt).
    private static let umbralCancelar: CGFloat = 120
    /// Cuánto hay que subir para bloquear.
    private static let umbralBloquear: CGFloat = 90

    private var haciaCancelar: Double {
        grabador.grabando && !vozBloqueada ? min(1, max(0, Double(-arrastre.width) / Self.umbralCancelar)) : 0
    }

    private var haciaBloquear: Double {
        grabador.grabando && !vozBloqueada ? min(1, max(0, Double(-arrastre.height) / Self.umbralBloquear)) : 0
    }

    /// El control de la derecha, UNO solo: manda si escribiste, detiene si no.
    ///
    /// ⚠️ Estuvieron los dos a la vez —detener y mandar— mientras el agente trabajaba, y
    /// se sentía cargado. Es lo que hacen ChatGPT y Claude: un control multiplexado.
    /// El precio: con algo escrito no se puede detener sin borrarlo primero.
    @ViewBuilder
    private var control: some View {
        Group {
            if store.currentTurn != nil && !grabador.grabando && !hayQueMandar {
                botonDetener
            } else {
                controlPrincipal
            }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    /// Botón redondo de 44 del diseño.
    private func circulo<Fondo: ShapeStyle>(_ fondo: Fondo, @ViewBuilder _ icono: () -> some View) -> some View {
        Circle().fill(fondo)
            .frame(width: 44, height: 44)
            .overlay { icono() }
    }

    private var botonDetener: some View {
        Button { Task { await store.stopTurn() } } label: {
            circulo(Color.gDark) {
                RoundedRectangle(cornerRadius: 3).fill(Color.white)
                    .frame(width: 12, height: 12)
            }
        }
        .buttonStyle(.gPressPrimary)
        .accessibilityLabel("Detener")
        .accessibilityIdentifier("detener")
    }

    @ViewBuilder
    private var controlPrincipal: some View {
        if hayQueMandar || !AppConfig.shared.isOn("voice") {
            // Enviar: `#15141B` con la flecha. Con la voz apagada desde gs (`flags.voice`)
            // ocupa el sitio del micrófono, inactivo mientras no haya nada que mandar.
            Button(action: enviar) {
                circulo(subiendo || !hayQueMandar ? Color.gInk4.opacity(0.45) : Color.gDark) {
                    ChatIcons.enviar.dibujo(.white, size: 18, ancho: 2)
                }
            }
            .buttonStyle(.gPressPrimary)
            .accessibilityLabel("Enviar")
            .accessibilityIdentifier("enviar")
            .disabled(subiendo || !hayQueMandar)
        } else {
            microfono
        }
    }

    /// El micrófono morado del diseño, como WhatsApp:
    /// - **Un toque** no graba: avisa «Mantén presionado para grabar y suelta para enviar».
    /// - **Mantener** graba: el botón crece (~1.85×) y sigue al dedo. Izquierda pasado
    ///   ~120 pt cancela SIN soltar (el micrófono cae al bote), arriba bloquea, soltar manda.
    ///
    /// ⚠️ **Late con tu voz.** Un micrófono que no reacciona no dice si te está oyendo.
    private var microfono: some View {
        let nivel = Double(grabador.onda.last ?? 0)
        let manteniendo = grabador.grabando && !vozBloqueada
        return circulo(manteniendo ? Color.gDanger : Color.gPrimary) {
            ChatIcons.microfono.dibujo(.white, size: 18, ancho: 1.9)
        }
        .background {
            // El halo crece con la voz; el círculo sólo un poco, o el icono baila.
            Circle()
                .stroke(Color.gDanger.opacity(manteniendo ? 0.3 : 0), lineWidth: 3)
                .scaleEffect(1 + nivel * 0.6)
        }
        .ghostyPrimaryShadow()
        // Crece mientras lo mantienes, como WhatsApp, y un poco con tu voz.
        .scaleEffect(manteniendo ? 1.85 * (1 + nivel * 0.06) * (1 - haciaCancelar * 0.25) : 1)
        // El candado, encima: dice que subir bloquea.
        .overlay(alignment: .bottom) {
            if manteniendo {
                PildoraDeCandado(haciaBloquear: haciaBloquear)
                    .offset(y: -98 - CGFloat(haciaBloquear) * 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Sigue al DEDO: sin esto el gesto es un umbral invisible.
        .offset(x: manteniendo ? min(0, arrastre.width) : 0,
                y: manteniendo ? min(0, max(-Self.umbralBloquear, arrastre.height)) : 0)
        .animation(.easeOut(duration: 0.08), value: nivel)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: manteniendo)
        .contentShape(Circle())
        .gesture(gestoDeVoz)
        .accessibilityElement()
        .accessibilityLabel("Nota de voz")
        .accessibilityHint("Mantén presionado para grabar y suelta para enviar")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { empezarBloqueada() }
        .accessibilityIdentifier("microfono")
    }

    private var gestoDeVoz: some Gesture {
        // Un solo `DragGesture` desde 0: tocar empieza a grabar (para no perder la primera
        // sílaba), arrastrar decide, soltar manda. Si fue un toque corto, se tira y se avisa.
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard !gestoCancelado else { return }
                if !grabador.grabando {
                    escribiendo = false
                    inicioDelToque = Date()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        grabador.empezar()
                    }
                }
                guard !vozBloqueada else { return }
                arrastre = v.translation
                // Izquierda pasado el umbral: se cancela YA, sin esperar a que sueltes.
                if v.translation.width < -Self.umbralCancelar {
                    gestoCancelado = true
                    grabador.cancelar()
                    withAnimation(.snappy(duration: 0.22)) {
                        arrastre = .zero
                        alBote = true
                    }
                } else if v.translation.height < -Self.umbralBloquear {
                    // Arriba = manos libres: sigue grabando y aparecen bote, pausa y enviar.
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        vozBloqueada = true
                        arrastre = .zero
                    }
                }
            }
            .onEnded { v in
                defer { gestoCancelado = false; inicioDelToque = nil }
                guard !gestoCancelado, !vozBloqueada, grabador.grabando else { return }
                let duro = Date().timeIntervalSince(inicioDelToque ?? .distantPast)
                let quieto = abs(v.translation.width) < 12 && abs(v.translation.height) < 12
                if quieto && duro < 0.4 {
                    // Un TOQUE: no es una nota. Se tira lo grabado y se explica el gesto.
                    cancelarVoz()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pistaDeVoz = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation(.easeOut(duration: 0.2)) { pistaDeVoz = false }
                    }
                } else {
                    soltarVoz()
                }
            }
    }

    /// Para VoiceOver: grabar directo en modo bloqueado (bote · pausa · enviar).
    private func empezarBloqueada() {
        escribiendo = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            grabador.empezar()
            vozBloqueada = true
        }
    }

    /// Para VoiceOver (y el gancho `GHOSTY_VOZ`): grabar directo en el overlay.
    private func empezarConOverlay() {
        escribiendo = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            grabador.empezar()
            vozBloqueada = true
        }
        mostrarOverlayDeVoz()
    }

    private func mostrarOverlayDeVoz() {
        vozConOverlay = true
        capa?.cubrir(OverlayDeVoz(grabador: grabador,
                                  alTerminar: { cerrarOverlayDeVoz(); soltarVoz() },
                                  alDescartar: { cerrarOverlayDeVoz(); cancelarVoz() }))
    }

    private func cerrarOverlayDeVoz() {
        guard vozConOverlay else { return }
        vozConOverlay = false
        capa?.descubrir()
    }

    /// Lo que va DENTRO de la cápsula cuando no se está grabando: el `+` y el campo.
    /// El control de la derecha lo pone `capsula`, porque es el que cambia de identidad.
    private var campoInterior: some View {
        HStack(spacing: 6) {
            Button(action: abrirAgregar) {
                ChatIcons.mas.dibujo(Color.gInk, size: 18, ancho: 1.9)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.gPressIcon)
            .accessibilityLabel("Agregar")
            .accessibilityIdentifier("adjuntar")
            // Un archivo no se puede meter en el turno en marcha (gs steerea texto, no
            // adjuntos): mientras trabaja, adjuntar sólo llevaría a cortarle el trabajo.
            .disabled(store.currentTurn != nil)
            .opacity(store.currentTurn != nil ? 0.35 : 1)

            TextField("", text: $borrador,
                      prompt: Text(store.currentTurn == nil ? "Pide algo o encarga una tarea" : "Dile algo más…")
                        .foregroundStyle(Color.gInk4),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Color.gInk)
                .lineLimit(1...5)
                .padding(.horizontal, 6)
                .focused($escribiendo)
                .submitLabel(.send)
                .onSubmit(enviar)
                .accessibilityIdentifier("campo-mensaje")
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
        // Sin permiso de IA de terceros no sale nada: la hoja pregunta y, si aceptas,
        // retoma este mismo envío. El borrador se queda donde estaba si dices que no.
        guard consentGiven else {
            escribiendo = false
            pendingSend = { enviar() }
            return
        }
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
            } else if let f = store.falloDeSubida {
                // El turno salió pero un adjunto no (p.ej. el tope de archivos de la
                // conversación): se dice con las palabras del servidor, que ya trae qué hacer.
                fallo = f
            }
            store.falloDeSubida = nil
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
        guard consentGiven else {
            pendingSend = { mandarNota(nota) }
            return
        }
        mandarNota(nota)
    }

    private func mandarNota(_ nota: Adjunto) {
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
            // No llegó al agente: la nota vuelve al compositor, como un adjunto escrito.
            // Antes se quedaba en el hilo sin respuesta y sin forma de reenviarla —así se
            // perdieron las dos de Brenda—; volver a grabarla era la única salida.
            if store.ultimoEnvioFallo {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    adjuntos = [nota]
                    borrador = texto
                }
                fallo = "Tu nota de voz no llegó. Tócale enviar para reintentar."
            } else if let f = store.falloDeSubida {
                // El agente recibió la transcripción, pero el audio no quedó guardado.
                fallo = f
            }
            store.falloDeSubida = nil
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

/// `gin` para una fila del hilo: entra con fade subiendo 8 pt, sólo si nace nueva.
private struct EntradaGin: ViewModifier {
    let animar: Bool
    @State private var visible: Bool?
    @Environment(\.accessibilityReduceMotion) private var sinMovimiento

    func body(content: Content) -> some View {
        let v = visible ?? !animar
        content
            .opacity(v ? 1 : 0)
            .offset(y: v || sinMovimiento ? 0 : 8)
            .onAppear {
                guard visible == nil else { return }
                visible = !animar
                if animar { withAnimation(.easeOut(duration: 0.3)) { visible = true } }
            }
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
