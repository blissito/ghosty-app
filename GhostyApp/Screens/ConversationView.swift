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
    @State private var grabador = GrabadorDeVoz()
    /// Cuánto se ha arrastrado desde el micrófono. Izquierda cancela, arriba bloquea.
    @State private var arrastre: CGSize = .zero
    /// Manos libres: se soltó el dedo y la grabación sigue.
    @State private var vozBloqueada = false
    @State private var fallo: String?
    /// ¿Está el hilo al final? Decide si se enseña el botón de bajar.
    @State private var alFinal = true

    var body: some View {
        VStack(spacing: 0) {
            if let agente = store.selectedAgent {
                AgentHeader(agent: agente, onTap: { escribiendo = false; onOpenSheet() })
                    .padding(.top, 8)
                    .padding(.bottom, 14)
            }

            // Quién más sigue trabajando. Va ARRIBA, pegado a la cabecera del agente:
            // es información sobre la flota, no sobre este hilo.
            OtrosTrabajando(store: store)

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if store.messages.isEmpty {
                            primeraVez
                                .padding(.top, 90)
                        }
                        ForEach(store.messages) { mensaje in
                            fila(mensaje).id(mensaje.id)
                                // Sólo la entrega se anima al entrar: llega a mitad del
                                // turno, cuando la persona está mirando, y aparecer de
                                // golpe se lee como un salto del texto. Las burbujas no
                                // la llevan a propósito — animar CADA trozo del streaming
                                // haría temblar el hilo entero.
                                .transition(esEntrega(mensaje)
                                            ? .scale(scale: 0.94).combined(with: .opacity)
                                            : .identity)
                        }
                        // ⚠️ El centinela del final. `onScrollGeometryChange` sería más
                        // directo pero es de iOS 18 y aquí el mínimo es 17.4, así que se
                        // mide con lo que hay: si esta última fila se ve, estás abajo.
                        Color.clear.frame(height: 1).id("fondo")
                            .onAppear { alFinal = true }
                            .onDisappear { alFinal = false }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .overlay(alignment: .bottom) {
                    if !alFinal && !store.messages.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.25)) {
                                scroll.scrollTo("fondo", anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.gInk)
                                .frame(width: 34, height: 34)
                                .background(Color.gCard, in: Circle())
                                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                                .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
                        }
                        .buttonStyle(.plain)
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
                .onChange(of: store.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { scroll.scrollTo("fondo", anchor: .bottom) }
                }
                // También al crecer el ÚLTIMO mensaje: la respuesta llega en trozos y
                // sin esto el texto nuevo queda fuera de vista mientras se escribe.
                .onChange(of: textoDelUltimo) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) { scroll.scrollTo("fondo", anchor: .bottom) }
                }
                // ⚠️ Cargar un hilo entero NO es lo mismo que recibir un mensaje. El
                // `LazyVStack` todavía no ha medido las filas cuando `messages` cambia de
                // golpe, así que un solo `scrollTo` aterriza sobre una altura que aún no
                // existe y el hilo se queda arriba, con los últimos mensajes escondidos.
                // Por eso se repite tras el layout, y SIN animación: al abrir un hilo no
                // hay nada que animar, sólo un sitio donde empezar a leer.
                .onChange(of: hiloVisible) { _, _ in alFondo(scroll) }
                .onAppear { alFondo(scroll) }
            }

            compositor
        }
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
    private var hiloVisible: String {
        // ⚠️ La clave LOCAL, no el `sessionId`: dos conversaciones nuevas del mismo
        // agente no lo tienen todavía y serían indistinguibles — cambiar entre ellas
        // dejaría el scroll a media altura, que se lee como "se colgó".
        "\(store.selectedAgentID)/\(store.claveDelHilo)"
    }

    /// Al fondo de verdad: ahora y otra vez cuando las filas ya se midieron.
    private func alFondo(_ scroll: ScrollViewProxy) {
        guard !store.messages.isEmpty else { return }
        scroll.scrollTo("fondo", anchor: .bottom)
        Task { @MainActor in
            for espera in [40, 160, 400] {
                try? await Task.sleep(for: .milliseconds(espera))
                scroll.scrollTo("fondo", anchor: .bottom)
            }
        }
    }

    private var textoDelUltimo: Int {
        guard case .agent(let t, _, _) = store.messages.last?.kind else { return 0 }
        return t.count
    }

    @ViewBuilder
    private func fila(_ mensaje: Message) -> some View {
        switch mensaje.kind {
        case .user(let t, let adj):
            HStack { Spacer(minLength: 40); UserBubble(text: t, adjuntos: adj, vuelo: vuelo) }
        case .agent(let t, let tools, let trailing):
            HStack { AgentBubble(text: t, tools: tools, trailing: trailing); Spacer(minLength: 30) }
        case .entrega(let e):
            HStack { EntregaCard(entrega: e); Spacer(minLength: 30) }
        case .prCard(let card):
            HStack {
                PRCard(card: card,
                       onApprove:        { Task { await store.respondToPR(card, approve: true) } },
                       onRequestChanges: { Task { await store.respondToPR(card, approve: false) } })
                Spacer(minLength: 30)
            }
        case .typing:
            HStack { TypingBubble(); Spacer() }
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

    /// El control de la derecha: enviar, parar, o el micrófono que late con tu voz.
    @ViewBuilder
    private var control: some View {
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
            .disabled(subiendo)
        } else {
            microfono
        }
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

            // ⚠️ Su propio icono, no un menú. Lo dejó dicho el comentario de arriba: con
            // varias conversaciones a la vez, empezar otra es una acción de todos los
            // días y esconderla en la hoja del agente la hacía invisible.
            if store.messages.count > 1 {
                Button { store.nuevaConversacion() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.gInk3)
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            TextField("Mensaje", text: $borrador, axis: .vertical)
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

    private func enviar() {
        guard hayQueMandar, !subiendo else { return }
        let texto = borrador
        let envio = adjuntos
        borrador = ""
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
