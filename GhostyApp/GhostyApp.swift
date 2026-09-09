import SwiftUI

@main
struct GhostyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                #if os(macOS)
                // Ventana del tamaño de un teléfono para poder juzgar el diseño
                // sin simulador — útil mientras no hay Xcode, y para iterar rápido.
                .frame(width: 390, height: 844)
                #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}
