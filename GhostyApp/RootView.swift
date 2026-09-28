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
    /// El historial de conversaciones. Ya no es pestaña: lo abre el botón de la cabecera
    /// del chat. `GHOSTY_TAB=conversations` (el valor viejo) lo abre al arrancar.
    @State private var historial = Gancho.valor("GHOSTY_TAB") == "conversations"
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

            if case .lista = store.conexion {
                GhostyTabBar(selection: $tab, tabs: pestanas,
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
                cambiarAgente = false
                withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { tab = .chat }
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
        // Abrir el historial es pedirle cuentas a TODOS los agentes: es la pantalla donde
        // se ve lo que el agente está haciendo desde otra superficie, y ese estado vive
        // en el servidor. El freno de los 30 s lo pone el store.
        .onChange(of: historial, initial: true) { _, abierto in
            guard abierto else { return }
            store.repasarLaFlota()
        }
        // Tocar un aviso lleva al chat. El destino lo resuelve el store (`irA`); aquí
        // sólo se cambia de pestaña cuando lo pide, y se cierra lo que tape el chat.
        .onChange(of: store.pestanaPedida) { _, pedida in
            guard let pedida else { return }
            tab = pedida
            historial = false
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
                // Gancho: `GHOSTY_ADJUNTOS=imagen|archivo|ambos` manda la sonda CON
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
        .sheet(isPresented: $historial) {
            ConversacionesView(store: store,
                               onCuenta: { historial = false; tab = .perfil },
                               onAbrir: { historial = false; tab = .chat },
                               onAgentTap: { agente in
                                   historial = false
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { hoja = agente }
                               })
                .padding(.top, 8)
                .background(Color.gBg)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
        [.chat, .artifacts, .connectors, .perfil]
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
        if modo == "archivo" || modo == "ambos" {
            let csv = Data("producto,precio\nteclado,750\nmonitor,3200\n".utf8)
            lista.append(Adjunto(nombre: "compras.csv", mime: "text/csv", datos: csv))
        }
        return lista
    }

    @ViewBuilder
    private var contenido: some View {
        // El padding inferior lo pone cada pantalla: sin él, la píldora tapa el
        // último elemento de una lista y parece que falta contenido.
        switch tab {
        case .chat:
            // El compositor va 10 pt encima de la barra (diseño: `bottom:106` contra 96).
            ConversationView(store: store, onOpenSheet: abrirHojaDelChat,
                             onHistorial: { historial = true })
                .padding(.bottom, holguraDeLaBarra)
        case .connectors:
            ConectoresPane(store: store)
                .safeAreaPadding(.bottom, holguraDeLaBarra + 12)
        case .artifacts:
            ArtifactsView(store: store)
                .safeAreaPadding(.bottom, holguraDeLaBarra + 12)
        case .perfil:
            PerfilView(store: store, verUso: $verUso)
                .safeAreaPadding(.bottom, holguraDeLaBarra + 12)
        }
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
