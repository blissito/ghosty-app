import SwiftUI

struct RootView: View {
    // ⚠️ El COMPARTIDO, no uno nuevo: el delegado de push necesita hablar con este mismo
    // store para recoger la respuesta cuando nos despiertan en el fondo.
    @State private var store = LiveAgentStore.compartido
    // GHOSTY_TAB / GHOSTY_SHEET son ganchos de desarrollo: dejan abrir una pantalla
    // concreta desde la línea de comandos para poder verificarlas sin tocar la
    // pantalla del simulador, que no acepta toques por script.
    @State private var tab: GhostyTab =
        GhostyTab(rawValue: Gancho.valor("GHOSTY_TAB") ?? "") ?? .chat
    @State private var hoja: Agent?
    /// Perfil como hoja: sólo desde el fallo de conexión (la barra no está ahí).
    @State private var ajustes = false
    /// El detalle del uso dentro de Perfil (`DetalleDeUso`). Lo abre la tarjeta del plan
    /// y «Ver mi uso» de la hoja de límite.
    @State private var verUso = false
    /// Cuándo se cerró la hoja de límite. Su «Ver mi uso» llama al `onOpenSheet` del chat
    /// tras cerrarse; si llega justo después, va al uso de Perfil y no a la hoja del agente.
    @State private var limiteCerradoEn: Date?
    /// ¿Estás DENTRO de una conversación? La pestaña Chats es la lista (inicio, como
    /// WhatsApp); abrir una fila entra al hilo, la barra se oculta y la flecha regresa.
    /// Los ganchos que miran un hilo (`GHOSTY_PROBE`, `GHOSTY_DEMO_CHAT`…) arrancan dentro.
    @State private var enHilo = Gancho.valor("GHOSTY_EN_HILO") == "1"
        || Gancho.valor("GHOSTY_PROBE") != nil || Gancho.valor("GHOSTY_DEMO_CHAT") != nil
        || Gancho.valor("GHOSTY_LOAD_THREAD") == "1" || Gancho.valor("GHOSTY_VOZ") == "1"
    /// El filtro de «Chats» (`nil` = Todos). Vive aquí porque lo pone también el avatar de
    /// la barra: elegir un agente te lleva a Chats con SUS conversaciones.
    @State private var filtroChats: String?
    /// «Cambiar de agente», la `GhostySheet` que abre el avatar de la barra.
    @State private var cambiarAgente = Gancho.valor("GHOSTY_AGENTES") == "1"
    /// El toast de la app (`Toaster`), uno para todas las pantallas.
    @State private var toaster = Toaster()
    /// La hoja «Agregar» y el overlay de voz del chat, pintados encima de la barra.
    @State private var capaDelChat = CapaDeChat()
    /// Lo que mide el borde seguro de abajo: decide a qué altura flota la barra.
    @State private var bordeInferior: CGFloat = 34
    /// La imagen que se está mirando a pantalla completa. Vive aquí porque quien pide
    /// abrirla está muy adentro —el proveedor de imágenes de una respuesta—. Ver `Visor`.
    @State private var visor = Visor()
    /// ⚠️ La app no miraba si volvía del fondo, así que un turno interrumpido por la
    /// suspensión se quedaba pintado como un fallo para siempre. Ver `volverDelFondo`.
    @Environment(\.scenePhase) private var fase
    private var config = AppConfig.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.gBg.ignoresSafeArea()

            Group {
                switch store.conexion {
                case .cargando:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Buscando tus agentes…").gMeta()
                    }
                case .sinLlave:
                    // Ya no se pega ningún token: se entra con la cuenta.
                    LoginView { await store.cargar() }
                case .fallo(let detalle):
                    VStack(spacing: 14) {
                        EmptyState(icon: "exclamationmark.triangle", title: "No pude conectar", detail: detalle)
                        HStack(spacing: 18) {
                            Button("Reintentar") { Task { await store.cargar() } }
                            Button("Ajustes") { ajustes = true }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                    }
                    .padding(.horizontal, 24)
                case .lista:
                    contenido
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if case .lista = store.conexion, !(tab == .chat && enHilo) {
                GhostyTabBar(selection: $tab, tabs: pestanas,
                             puntos: store.chatsSinLeer > 0 ? [.chat] : [],
                             agente: store.selectedAgent,
                             agenteAbierto: cambiarAgente,
                             onAgente: { cambiarAgente = true })
                    // A 28 pt del borde de la PANTALLA (diseño), no del borde seguro: en
                    // un iPhone con indicador de inicio (34 pt) eso es 6 pt por debajo.
                    // Sin indicador, 12 pt del borde.
                    .padding(.bottom, barraSobreElBorde)
                    // ⚠️ Si la pestaña activa deja de estar en la lista, hay que caer a
                    // Chat: sin esto la pantalla se queda en una vista sin destino y la
                    // barra sin píldora activa (el resaltado sólo se pinta cuando
                    // `selection == tab`). Pasa también con el gancho `GHOSTY_TAB`.
                    .onChange(of: pestanas) { _, nuevas in
                        if !nuevas.contains(tab) { tab = .chat }
                    }
                    .onAppear { if !pestanas.contains(tab) { tab = .chat } }
                    // Dentro del hilo la barra se va hacia abajo, como WhatsApp.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // La config remota (`AppConfig`): el aviso arriba, la compuerta encima de todo.
            if config.shouldSuggestUpdate {
                UpdateSuggestionBanner { withAnimation { config.dismissSuggestion() } }
                    .frame(maxHeight: .infinity, alignment: .top)
                    // Debajo de la cabecera del chat (el nombre del agente), no encima.
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if config.mustUpdate {
                UpdateRequiredView().transition(.opacity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { nuevo in
            // Con el teclado arriba el borde seguro crece: eso no es el indicador de
            // inicio, así que no mueve la barra.
            if nuevo < 60 { bordeInferior = nuevo }
        }
        // «Cambiar de agente» y el toast van en la raíz: el velo tapa también la barra.
        .ghostySheet(isPresented: $cambiarAgente, title: "Cambiar de agente",
                     identifier: "hoja-agentes") {
            CambiarAgenteSheet(store: store) {
                // Elegir un agente te lleva a «Chats» con SU filtro puesto (el chip se
                // desplaza a la vista), no a un hilo.
                cambiarAgente = false
                withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                    filtroChats = store.selectedAgentID
                    enHilo = false
                    tab = .chat
                }
            }
        }
        .capaDeChat(capaDelChat)
        .ghostyToast(toaster)
        // ⚠️ Sólo al VOLVER. Aquí hubo tres ramas —anotar el fondo, cerrar sockets con
        // tiempo de gracia, marcar turnos como interrumpidos— porque el turno era del
        // teléfono y había que salvarlo al dormirse. El turno es del servidor: irse no
        // requiere hacer nada, y al volver sólo hay que preguntar qué pasó.
        .onChange(of: fase) { _, nueva in
            // ⚠️ El registro se vuelca al IRSE. Su comentario decía que ya pasaba, pero
            // `volcar()` sólo lo llamaba el botón de compartir de Ajustes: lo que no
            // hubieras exportado a mano se perdía al cerrar la app. Se perdieron varias
            // reproducciones así, la última la del push que abría una conversación vacía.
            if nueva != .active { Bitacora.volcar() }
            guard nueva == .active else { return }
            Task { await store.volverDelFondo() }
            Task { await AppConfig.shared.refresh() }
        }
        // Tocar un aviso lleva al chat. El destino lo resuelve el store (`irA`); aquí
        // sólo se cambia de pestaña cuando lo pide, y se cierra lo que tape el chat.
        .onChange(of: store.pestanaPedida) { _, pedida in
            guard let pedida else { return }
            tab = pedida
            // Un aviso lleva a SU conversación: dentro del hilo, no a la lista.
            if pedida == .chat { enHilo = true }
            cambiarAgente = false
            store.pestanaPedida = nil
        }
        // `com.fixtergeek.ghostyapp://conversacion|compartido` (ver `EnlaceDeGhosty`): lo
        // que abre la extensión «Enviar a Ghosty».
        .onOpenURL { url in
            guard let enlace = EnlaceDeGhosty(url: url) else { return }
            store.abrir(enlace)
        }
        .task {
            // Lo primero, y barato: tirar las imágenes viejas del caché de disco.
            CacheDeImagenes.purgar()
            GrupoDeApp.espejarConsentimiento()
            // Sin await: la config nunca retrasa el arranque, llega cuando llegue.
            Task { await AppConfig.shared.refresh() }
            await store.cargar()
            // Gancho: `GHOSTY_COMPARTIDO=<id>` abre ese paquete de la hoja de compartir como
            // si llegara por `…://compartido` (el simulador pregunta antes de abrir un enlace
            // y nadie puede contestar).
            if let id = Gancho.valor("GHOSTY_COMPARTIDO") { store.abrir(.compartido(id: id)) }
            // En paralelo: ninguna de las dos bloquea la pantalla y las dos deciden qué se
            // enseña en Ajustes.
            async let almacen: Void = store.cargarAlmacenamiento()
            async let integraciones: Void = store.cargarConectores()
            // La biblioteca de la cuenta decide si la pestaña Artefactos aparece.
            async let archivosDeCuenta: Void = store.loadAccountFiles()
            _ = await (almacen, integraciones, archivosDeCuenta)
            // Sonda de desarrollo: con GHOSTY_PROBE puesta manda ese texto al
            // arrancar. Es lo que deja verificar el turno y el markdown sin
            // depender de que alguien teclee en el simulador.
            // Gancho de desarrollo: carga el hilo más reciente de la caja para
            // poder verificar el replay sin tocar la pantalla.
            if Gancho.valor("GHOSTY_LOAD_THREAD") == "1" {
                await store.cargarHilos()
                if let primero = store.hilosRemotos.first {
                    await store.abrirHilo(primero)
                }
            }
            // Gancho: `GHOSTY_USO=1` abre el detalle del uso desde Perfil.
            if Gancho.valor("GHOSTY_USO") == "1" {
                tab = .perfil
                verUso = true
            }
            if Gancho.valor("GHOSTY_SHEET") == "1" {
                hoja = store.selectedAgent
            }
            // Gancho: crea un hilo nuevo antes de la sonda, para verificar que
            // session/new funciona y que el turno cae en ESE hilo.
            if Gancho.valor("GHOSTY_NEW_THREAD") == "1" {
                store.nuevaConversacion()
                try? await Task.sleep(for: .seconds(6))
            }
            if let sonda = Gancho.valor("GHOSTY_PROBE"),
               !sonda.isEmpty, case .lista = store.conexion {
                // Gancho: `GHOSTY_ADJUNTOS=imagen|archivo|ambos|voz:<ruta>` manda la sonda CON
                // adjuntos. El simulador no acepta toques por script, así que sin esto no
                // hay forma de verificar el camino de subida ni el de la imagen inline —
                // que son justo los dos que fallan distinto.
                await store.send(sonda, adjuntos: Self.adjuntosDePrueba())
            }
        }
        .environment(visor)
        .fullScreenCover(item: Binding(get: { visor.imagen }, set: { visor.imagen = $0 })) { img in
            VisorDeImagen(imagen: img, titulo: visor.titulo)
        }
        .onChange(of: store.limitNotice) { antes, ahora in
            if antes != nil, ahora == nil { limiteCerradoEn = Date() }
        }
        .sheet(isPresented: $ajustes) {
            PerfilView(store: store, enHoja: true, verUso: $verUso)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationCornerRadius(Theme.Radius.sheet)
                #endif
        }
        .sheet(item: $hoja) { agente in
            AgentSheetView(agent: agente, store: store,
                           onAjustes: {
                               hoja = nil
                               withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { tab = .perfil }
                           })
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(Theme.Radius.sheet)
                #endif
        }
    }

    /// Las pestañas que se pintan hoy.
    ///
    /// **Ideas** y **Metas** no están: sus pantallas son cascarones que dicen "todavía no
    /// está". El `case` se queda en el enum —quitarlo obliga a tocar dos `switch` y no
    /// compra nada—, lo que se quita es su sitio en la barra.
    ///
    /// **Artefactos** sólo aparece con una llave de cuenta. Es exactamente la condición
    /// que `LiveAgentStore.cargarArchivos()` ya exige, dicha UNA vez: el agente que enrola
    /// la app entra con otro tipo de credencial, así que esa pestaña sólo podía abrirse
    /// para explicar por qué no funciona. Una pestaña que no sirve es peor que ninguna.
    private var pestanas: [GhostyTab] {
        // Artefactos aparece con el almacén de la cuenta o en cuanto el agente entrega
        // algo. Que la pestaña nazca cuando hay contenido es a propósito: vacía sólo servía
        // para explicar por qué estaba vacía.
        // ⚠️ **Chat va en MEDIO, no primero.** El centro de la barra es lo más cómodo del
        // pulgar y Chat es a donde más se vuelve; en el borde izquierdo estaba en la
        // esquina peor. Lo que NO se hace es rellenar hasta cinco para tener un centro
        // exacto: eso obligaría a inventar dos destinos, y una pestaña con "todavía no
        // está" detrás no se lee como beta, se lee como rota — es justo por lo que se
        // quitaron Ideas y Metas.
        // Rediseño 2026-09: las cuatro del diseño, SIEMPRE y en este orden. Archivos ya
        // no espera a tener contenido (su vacío explica qué va a caer ahí) e
        // Integraciones se enseña aunque el servidor todavía no las sirva: cada fila
        // apagada lo dice (decidido el 2026-09-09). Conversaciones salió de la barra.
        // Rediseño estilo WhatsApp (2026-09-29, igual que Android): Chats al final, pegado
        // al avatar del agente, que va a la derecha.
        [.perfil, .connectors, .artifacts, .chat]
    }

    /// La barra flota a 28 pt del borde de la pantalla; esto es ese margen medido desde
    /// el borde SEGURO, que es desde donde pone el `padding` el `ZStack`.
    private var barraSobreElBorde: CGFloat {
        bordeInferior > 0 ? Theme.Space.tabBarBottom - bordeInferior : 12
    }

    /// Cuánto tiene que dejar libre abajo una pantalla para que la barra no la tape.
    private var holguraDeLaBarra: CGFloat {
        barraSobreElBorde + Theme.Space.tabBarHeight + 6
    }

    /// Adjuntos sintéticos para el gancho `GHOSTY_ADJUNTOS`. Sólo se construyen si la
    /// variable está puesta, así que en un build normal no cuestan nada.
    private static func adjuntosDePrueba() -> [Adjunto] {
        let modo = Gancho.valor("GHOSTY_ADJUNTOS") ?? ""
        guard !modo.isEmpty else { return [] }
        var lista: [Adjunto] = []
        if modo == "imagen" || modo == "ambos" {
            // Un PNG rojo de 8×8. No hace falta que sea bonito, hace falta que el modelo
            // pueda decir de qué color es.
            //
            // ⚠️ Estos bytes están COMPROBADOS contra el modelo, no sólo contra `file`. El
            // primero que puse aquí lo daban por válido `file` y PIL, y el modelo contestaba
            // "llegó dañada": estuve a punto de declarar roto el camino de imágenes por
            // culpa de mi propio dato de prueba. Si se cambia, se vuelve a comprobar.
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP4z8CAFWEXHbQSACj/P8Fu7N9hAAAAAElFTkSuQmCC")
            if let png { lista.append(Adjunto(nombre: "rojo.png", mime: "image/png", datos: png)) }
        }
        // `voz:/ruta/nota.m4a`: una nota de voz de verdad, leída del disco de la Mac (el
        // simulador lo ve). Sintética no sirve: whisper tiene que poder transcribirla.
        if modo.hasPrefix("voz:"), let audio = FileManager.default.contents(atPath: String(modo.dropFirst(4))) {
            lista.append(Adjunto(nombre: "nota-de-voz-prueba.m4a", mime: "audio/mp4", datos: audio,
                                 segundos: 4, onda: Array(repeating: 0.5, count: 40)))
        }
        if modo == "archivo" || modo == "ambos" {
            let csv = Data("producto,precio\nteclado,750\nmonitor,3200\n".utf8)
            lista.append(Adjunto(nombre: "compras.csv", mime: "text/csv", datos: csv))
        }
        return lista
    }

    /// Las pestañas se DESLIZAN, como WhatsApp y Android (pager). El hilo va encima, fuera
    /// del pager: dentro de una conversación deslizar no cambia de pestaña, regresa.
    private var contenido: some View {
        ZStack {
            TabView(selection: $tab) {
                PerfilView(store: store, verUso: $verUso)
                    .safeAreaPadding(.bottom, holguraDeLaBarra + 12)
                    .tag(GhostyTab.perfil)
                ConectoresPane(store: store)
                    .safeAreaPadding(.bottom, holguraDeLaBarra + 12)
                    .tag(GhostyTab.connectors)
                ArtifactsView(store: store)
                    .safeAreaPadding(.bottom, holguraDeLaBarra + 12)
                    .tag(GhostyTab.artifacts)
                ChatsView(store: store, filtro: $filtroChats,
                          onAbrir: { withAnimation(.easeOut(duration: 0.25)) { enHilo = true } },
                          onPlanYUso: {
                              withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { tab = .perfil }
                              DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { verUso = true }
                          },
                          onAjustes: {
                              withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { tab = .perfil }
                          })
                    .safeAreaPadding(.bottom, holguraDeLaBarra + 12)
                    .tag(GhostyTab.chat)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if tab == .chat && enHilo {
                // Sin barra: el compositor va pegado abajo, como WhatsApp.
                ConversationView(store: store, onOpenSheet: abrirHojaDelChat,
                                 onVolver: volverAChats)
                    .padding(.bottom, 4)
                    .background(Color.gBg.ignoresSafeArea())
                    // Deslizar desde el borde izquierdo también regresa.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { v in
                                if v.startLocation.x < 28, v.translation.width > 90,
                                   abs(v.translation.height) < 80 { volverAChats() }
                            }
                    )
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
    }

    /// La flecha de atrás del hilo (o deslizar desde el borde): de vuelta a «Chats».
    private func volverAChats() {
        withAnimation(.easeOut(duration: 0.25)) { enHilo = false }
    }

    private func abrirHoja() {
        hoja = store.selectedAgent
    }

    /// El `onOpenSheet` del chat. Si llega justo tras cerrarse la hoja de límite, es su
    /// «Ver mi uso»: lleva al uso de Perfil (la hoja de límite vive en `Core/Chat` y no
    /// sabe de pestañas).
    private func abrirHojaDelChat() {
        if let t = limiteCerradoEn, Date().timeIntervalSince(t) < 1.5 {
            limiteCerradoEn = nil
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { tab = .perfil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { verUso = true }
            return
        }
        abrirHoja()
    }
}
