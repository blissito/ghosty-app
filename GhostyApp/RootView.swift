import SwiftUI

struct RootView: View {
    // ⚠️ El COMPARTIDO, no uno nuevo: el delegado de push necesita hablar con este mismo
    // store para recoger la respuesta cuando nos despiertan en el fondo.
    @State private var store = LiveAgentStore.compartido
    // GHOSTY_TAB / GHOSTY_SHEET son ganchos de desarrollo: dejan abrir una pantalla
    // concreta desde la línea de comandos para poder verificarlas sin tocar la
    // pantalla del simulador, que no acepta toques por script.
    @State private var tab: GhostyTab =
        GhostyTab(rawValue: ProcessInfo.processInfo.environment["GHOSTY_TAB"] ?? "") ?? .chat
    @State private var hoja: Agent?
    @State private var ajustes = false
    /// La imagen que se está mirando a pantalla completa. Vive aquí porque quien pide
    /// abrirla está muy adentro —el proveedor de imágenes de una respuesta—. Ver `Visor`.
    @State private var visor = Visor()
    /// ⚠️ La app no miraba si volvía del fondo, así que un turno interrumpido por la
    /// suspensión se quedaba pintado como un fallo para siempre. Ver `volverDelFondo`.
    @Environment(\.scenePhase) private var fase

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
                             puntos: store.hayPendientes ? [.conversations] : [])
                    .padding(.bottom, 4)
                    // ⚠️ Si la pestaña activa deja de estar en la lista, hay que caer a
                    // Chat: sin esto la pantalla se queda en una vista sin destino y la
                    // barra sin píldora activa (el resaltado sólo se pinta cuando
                    // `selection == tab`). Pasa de verdad al cambiar de agente con
                    // Artefactos abierto, y también con el gancho `GHOSTY_TAB`.
                    .onChange(of: pestanas) { _, nuevas in
                        if !nuevas.contains(tab) { tab = .chat }
                    }
                    .onAppear { if !pestanas.contains(tab) { tab = .chat } }
            }
        }
        // ⚠️ Sólo al VOLVER. Aquí hubo tres ramas —anotar el fondo, cerrar sockets con
        // tiempo de gracia, marcar turnos como interrumpidos— porque el turno era del
        // teléfono y había que salvarlo al dormirse. El turno es del servidor: irse no
        // requiere hacer nada, y al volver sólo hay que preguntar qué pasó.
        .onChange(of: fase) { _, nueva in
            guard nueva == .active else { return }
            Task { await store.volverDelFondo() }
        }
        // Tocar un aviso abre a ese agente. Es la mitad que hace útil la notificación:
        // sin esto te enteras de que alguien terminó y sigues teniendo que buscarlo.
        .onReceive(NotificationCenter.default.publisher(for: Avisos.alTocar)) { aviso in
            guard let id = aviso.object as? String else { return }
            store.seleccionar(id)
            // Si el aviso dice de QUÉ conversación habla, se abre ésa: con varias por
            // agente, abrir «el agente» ya no dice a cuál ir.
            if let sesion = aviso.userInfo?["sesion"] as? String,
               let hilo = store.canales[id]?.hilo(sesion: sesion) {
                store.mirar(hilo, de: id)
            }
            tab = .chat
        }
        .task {
            // Lo primero, y barato: tirar las imágenes viejas del caché de disco.
            CacheDeImagenes.purgar()
            await store.cargar()
            // En paralelo: ninguna de las dos bloquea la pantalla y las dos deciden qué se
            // enseña en Ajustes.
            async let almacen: Void = store.cargarAlmacenamiento()
            async let integraciones: Void = store.cargarConectores()
            _ = await (almacen, integraciones)
            // Sonda de desarrollo: con GHOSTY_PROBE puesta manda ese texto al
            // arrancar. Es lo que deja verificar el turno y el markdown sin
            // depender de que alguien teclee en el simulador.
            // Gancho de desarrollo: carga el hilo más reciente de la caja para
            // poder verificar el replay sin tocar la pantalla.
            if ProcessInfo.processInfo.environment["GHOSTY_LOAD_THREAD"] == "1" {
                await store.cargarHilos()
                if let primero = store.hilosRemotos.first {
                    await store.abrirHilo(primero)
                }
            }
            if ProcessInfo.processInfo.environment["GHOSTY_SHEET"] == "1" {
                hoja = store.selectedAgent
            }
            // Gancho: crea un hilo nuevo antes de la sonda, para verificar que
            // session/new funciona y que el turno cae en ESE hilo.
            if ProcessInfo.processInfo.environment["GHOSTY_NEW_THREAD"] == "1" {
                store.nuevaConversacion()
                try? await Task.sleep(for: .seconds(6))
            }
            if let sonda = ProcessInfo.processInfo.environment["GHOSTY_PROBE"],
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
        .sheet(isPresented: $ajustes) {
            SettingsView(store: store)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationCornerRadius(Theme.Radius.sheet)
                #endif
        }
        .sheet(item: $hoja) { agente in
            AgentSheetView(agent: agente, store: store,
                           onAjustes: { hoja = nil; ajustes = true },
                           onNuevaConversacion: { store.nuevaConversacion() })
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
        var lista: [GhostyTab] = [.conversations, .chat]
        if store.puedeVerArchivos || !store.entregas.de(store.selectedAgentID).isEmpty {
            lista.append(.artifacts)
        }
        // Integraciones se enseña SIEMPRE, aunque el servidor todavía no las sirva: la
        // lista se va a ir completando y ver lo que viene es información útil. Cada fila
        // apagada lo dice. Decidido el 2026-09-09.
        lista.append(.connectors)
        return lista
    }

    /// Adjuntos sintéticos para el gancho `GHOSTY_ADJUNTOS`. Sólo se construyen si la
    /// variable está puesta, así que en un build normal no cuestan nada.
    private static func adjuntosDePrueba() -> [Adjunto] {
        let modo = ProcessInfo.processInfo.environment["GHOSTY_ADJUNTOS"] ?? ""
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
            ConversationView(store: store, onOpenSheet: abrirHoja)
                .padding(.bottom, Theme.Space.composerClearance)
        case .conversations:
            ConversacionesView(store: store,
                               onCuenta: { ajustes = true },
                               onAbrir: { tab = .chat })
                .safeAreaPadding(.bottom, Theme.Space.tabBarClearance)
        case .connectors:
            ConectoresPane(store: store)
                .safeAreaPadding(.bottom, Theme.Space.tabBarClearance)
        case .artifacts:
            ArtifactsView(store: store, onOpenSheet: abrirHoja)
                .safeAreaPadding(.bottom, Theme.Space.tabBarClearance)
        }
    }

    private func abrirHoja() {
        hoja = store.selectedAgent
    }
}
