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
    @State private var editando: AgentAccount?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.gBg.ignoresSafeArea()

            Group {
                switch store.conexion {
                case .cargando:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Buscando tus cajas…").gMeta()
                    }
                case .sinLlave:
                    VStack(spacing: 16) {
                        EmptyState(
                            icon: "key",
                            title: "Falta la credencial",
                            detail: "Pega el token de tu agente para que la app pueda hablar con su caja."
                        )
                        ActionButton(title: "Abrir Ajustes", kind: .primary) { ajustes = true }
                            .frame(maxWidth: 240)
                    }
                    .padding(.horizontal, 24)
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
                GhostyTabBar(selection: $tab)
                    .padding(.bottom, 4)
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
                await store.send(sonda)
            }
        }
        .sheet(item: $editando) { cuenta in
            SettingsView(editando: cuenta) { Task { await store.recargarCredencial() } }
                #if os(iOS)
                .presentationDetents([.large])
                .presentationCornerRadius(Theme.Radius.sheet)
                #endif
        }
        .sheet(isPresented: $ajustes) {
            SettingsView { Task { await store.recargarCredencial() } }
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
                      onEditar: { editando = $0 })
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
