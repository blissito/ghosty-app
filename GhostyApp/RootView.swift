import SwiftUI

struct RootView: View {
    @State private var store = LiveAgentStore()
    // GHOSTY_TAB / GHOSTY_SHEET son ganchos de desarrollo: dejan abrir una pantalla
    // concreta desde la línea de comandos para poder verificarlas sin tocar la
    // pantalla del simulador, que no acepta toques por script.
    @State private var tab: GhostyTab =
        GhostyTab(rawValue: ProcessInfo.processInfo.environment["GHOSTY_TAB"] ?? "") ?? .chat
    @State private var hoja: Agent?
    @State private var ajustes = false

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
                GhostyTabBar(selection: $tab, tabs: pestanas)
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
        .task {
            await store.cargar()
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
        store.puedeVerArchivos || !store.entregas.de(store.selectedAgentID).isEmpty
            ? [.chat, .fleet, .artifacts]
            : [.chat, .fleet]
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
            ConversationView(store: store, onOpenSheet: abrirHoja,
                             onConectarAgente: { ajustes = true })
                .padding(.bottom, Theme.Space.composerClearance)
        case .fleet:
            FleetView(store: store,
                      onConectar: { ajustes = true },
                      onEditar: { _ in ajustes = true })
                .safeAreaPadding(.bottom, Theme.Space.tabBarClearance)
        case .ideas:
            EmptyState(icon: "lightbulb", title: "Ideas",
                       detail: "Lo que el agente propone sin que se lo pidas. Todavía no está.")
                .padding(.bottom, Theme.Space.tabBarClearance)
        case .goals:
            EmptyState(icon: "checkmark.square", title: "Metas",
                       detail: "Lo que persigue y su plan para llegar. Todavía no está.")
                .padding(.bottom, Theme.Space.tabBarClearance)
        case .artifacts:
            ArtifactsView(store: store, onOpenSheet: abrirHoja)
                .safeAreaPadding(.bottom, Theme.Space.tabBarClearance)
        }
    }

    private func abrirHoja() {
        hoja = store.selectedAgent
    }
}
