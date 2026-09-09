import SwiftUI

/// La bienvenida. Un solo botón: todo lo demás —Google, Apple, Face ID, correo— vive en
/// la página de ghosty.studio, así que la app no tiene que saber nada de proveedores ni
/// crecer un botón cada vez que se añada uno.
struct LoginView: View {
    var alEntrar: () async -> Void

    @State private var flujo = LoginFlow()
    @State private var yendo: LoginFlow.Proveedor?
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

            // Los proveedores van AQUÍ y no en la web: tocar "Entrar" y que la página
            // vuelva a preguntar con qué entrar son dos pasos para la misma decisión.
            VStack(spacing: 10) {
                ActionButton(title: titulo("Continuar con Google", .google), kind: .primary) {
                    Task { await entrar(.google) }
                }
                .disabled(yendo != nil)

                ActionButton(title: titulo("Continuar con Apple", .apple), kind: .secondary) {
                    Task { await entrar(.apple) }
                }
                .disabled(yendo != nil)

                Button {
                    Task { await entrar(.cualquiera) }
                } label: {
                    Text("Otra forma de entrar")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.gInk2)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .disabled(yendo != nil)
            }
            .padding(.horizontal, 24)

            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.gDanger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
            }

            Spacer().frame(height: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func titulo(_ base: String, _ p: LoginFlow.Proveedor) -> String {
        yendo == p ? "Abriendo…" : base
    }

    private func entrar(_ proveedor: LoginFlow.Proveedor) async {
        error = nil
        yendo = proveedor
        defer { yendo = nil }
        do {
            try await flujo.entrar(con: proveedor)
            await alEntrar()
        } catch LoginFlow.Fallo.cancelado {
            // Cancelar no es un fallo. ⚠️ No basta con devolver `nil` en
            // `errorDescription`: `localizedDescription` cae entonces al texto de
            // sistema ("The operation couldn't be completed…"), que es justo lo que
            // salía en rojo al cerrar la hoja. Hay que atrapar el caso, no confiar
            // en que el texto venga vacío.
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
