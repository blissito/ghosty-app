import SwiftUI

/// La bienvenida. Un solo botón: todo lo demás —Google, Apple, Face ID, correo— vive en
/// la página de ghosty.studio, así que la app no tiene que saber nada de proveedores ni
/// crecer un botón cada vez que se añada uno.
struct LoginView: View {
    var alEntrar: () async -> Void

    @State private var flujo = LoginFlow()
    @State private var yendo = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("ghosty-lila")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text("Ghosty")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.gInk)
                .padding(.top, 20)

            Text("Tu agente, en tu bolsillo.")
                .gMeta()
                .padding(.top, 6)

            Spacer()

            ActionButton(title: yendo ? "Abriendo…" : "Entrar", kind: .primary) {
                Task { await entrar() }
            }
            .disabled(yendo)
            .padding(.horizontal, 24)

            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.gDanger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
            }

            Text("Con tu cuenta de Google, Apple o tu correo.")
                .gMeta()
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func entrar() async {
        error = nil
        yendo = true
        defer { yendo = false }
        do {
            try await flujo.entrar()
            await alEntrar()
        } catch {
            // Cancelar no es un fallo: `errorDescription` es nil y no se enseña nada.
            // Regañar a alguien por cerrar una hoja que abrió él es ruido.
            self.error = error.localizedDescription.isEmpty ? nil : error.localizedDescription
        }
    }
}
