import SwiftUI

struct RootView: View {
    @State private var store = LiveAgentStore()
    @State private var tab: GhostyTab = .chat
    @State private var hoja: Agent?

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
                    EmptyState(
                        icon: "key",
                        title: "Falta la llave",
                        detail: "Pon tu llave de EasyBits en EASYBITS_API_KEY, o en ~/.ghosty-app.json como easyBitsApiKey."
                    )
                    .padding(.horizontal, 24)
                case .fallo(let detalle):
                    VStack(spacing: 14) {
                        EmptyState(icon: "exclamationmark.triangle", title: "No pude conectar", detail: detalle)
                        Button("Reintentar") { Task { await store.cargar() } }
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
            if let sonda = ProcessInfo.processInfo.environment["GHOSTY_PROBE"],
               !sonda.isEmpty, case .lista = store.conexion {
                await store.send(sonda)
            }
        }
        .sheet(item: $hoja) { agente in
            AgentSheetView(agent: agente, store: store)
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
            ConversationView(store: store, onOpenSheet: abrirHoja)
                .padding(.bottom, Theme.Space.composerClearance)
        case .fleet:
            FleetView(store: store) { hoja = $0 }
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
