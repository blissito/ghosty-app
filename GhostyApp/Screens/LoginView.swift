import SwiftUI

/// La bienvenida.
///
/// ⚠️ Los botones de proveedor NO son de diseño libre, y aquí no se improvisa:
///
///  • **Sign in with Apple** obliga a usar el botón de Apple —su logo, su texto, negro o
///    blanco, mínimo 44 pt— y a que **no sea menos prominente** que los demás. Un estilo
///    propio, más chico, o colocado debajo de los sociales es motivo documentado de
///    rechazo (HIG → Sign in with Apple; guidelines 4.0 y 4.8).
///  • **Google** sí permite botón propio, pero con su "G" oficial, sus colores y su
///    tipografía (developers.google.com/identity/branding-guidelines).
///
/// La primera versión de esta pantalla los tenía inventados —morado liso, sin logos— y
/// no habría pasado revisión.
struct LoginView: View {
    var alEntrar: () async -> Void

    @State private var flujo = LoginFlow()
    @State private var yendo: String?
    @State private var error: String?
    @State private var proveedores: [Proveedor] = Proveedor.respaldo

    /// Un proveedor tal como lo nombra el servidor. La lista NO va horneada: conectar
    /// uno nuevo no debe exigir publicar una versión y esperar a App Review.
    struct Proveedor: Identifiable, Decodable, Equatable {
        var id: String
        var etiqueta: String

        /// Lo que se pinta antes de que conteste el servidor, y si no contesta. Google
        /// lleva configurado desde siempre; enseñar una pantalla vacía mientras carga
        /// sería peor que enseñar el camino que casi todos usan.
        static let respaldo: [Proveedor] = [.init(id: "google", etiqueta: "Google")]
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("ghosty-lila")
                .resizable().scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text("Ghosty")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.gInk)
                .padding(.top, 20)

            Text("Tu agente, en tu bolsillo.").gMeta().padding(.top, 6)

            Spacer()

            VStack(spacing: 12) {
                ForEach(proveedores) { p in
                    boton(p)
                }

                // ⚠️ Aquí había un "Otra forma de entrar" que llevaba a la página de
                // login de gs. Se quitó por redundante: con un proveedor puesto ya se
                // entra a ghosty.studio, y ofrecer dos caminos al mismo sitio no ayuda
                // a decidir.
                //
                // Lo que se pierde y hay que devolver: correo y passkey (Face ID) vivían
                // en esa página. Mientras Apple no esté configurado, Google es la única
                // puerta desde el teléfono.
            }
            .padding(.horizontal, 24)

            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.gDanger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32).padding(.top, 12)
            }

            Spacer().frame(height: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await cargarProveedores() }
    }

    @ViewBuilder
    private func boton(_ p: Proveedor) -> some View {
        switch p.id {
        case "apple": BotonApple(cargando: yendo == p.id) { Task { await entrar(p.id) } }
        case "google": BotonGoogle(cargando: yendo == p.id) { Task { await entrar(p.id) } }
        // Un proveedor que el servidor conoce y esta versión de la app no (EasyBits será
        // el primero). Sale con un botón neutro en vez de desaparecer: mejor entrar con
        // un botón sin marca que no poder entrar.
        default:
            BotonNeutro(titulo: "Continuar con \(p.etiqueta)", cargando: yendo == p.id) {
                Task { await entrar(p.id) }
            }
        }
    }

    private func cargarProveedores() async {
        let url = Session.base.appendingPathComponent("oauth2/proveedores")
        guard let (d, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONDecoder().decode([String: [Proveedor]].self, from: d),
              let lista = j["proveedores"], !lista.isEmpty
        else { return }   // se queda el respaldo
        proveedores = lista
    }

    private func entrar(_ proveedor: String) async {
        error = nil
        yendo = proveedor
        defer { yendo = nil }
        do {
            try await flujo.entrar(con: proveedor)
            await alEntrar()
        } catch LoginFlow.Fallo.cancelado {
            // ⚠️ Cancelar no es un fallo, y devolver `nil` en `errorDescription` NO
            // basta: `localizedDescription` cae al texto de sistema ("The operation
            // couldn't be completed…"), que es lo que salía en rojo al cerrar la hoja.
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Los botones, con la marca que cada uno exige

/// Negro, logo de Apple, texto aprobado. Va PRIMERO y del mismo tamaño que los demás:
/// la HIG pide que no quede menos prominente que los otros proveedores.
private struct BotonApple: View {
    var cargando: Bool
    var accion: () -> Void

    var body: some View {
        Button(action: accion) {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 19, weight: .medium))
                Text(cargando ? "Abriendo…" : "Continuar con Apple")
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            // 50 pt: por encima del mínimo de 44 que pide la guía.
            .frame(height: 50)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(cargando)
        .opacity(cargando ? 0.7 : 1)
    }
}

/// Fondo blanco, borde gris y la "G" de cuatro colores, como pide la guía de marca de
/// Google. El texto va en su gris (#1F1F1F), no en el tinte de la app.
private struct BotonGoogle: View {
    var cargando: Bool
    var accion: () -> Void

    var body: some View {
        Button(action: accion) {
            HStack(spacing: 10) {
                Image("google-g").resizable().scaledToFit().frame(width: 20, height: 20)
                Text(cargando ? "Abriendo…" : "Continuar con Google")
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(red: 0.455, green: 0.463, blue: 0.463), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(cargando)
        .opacity(cargando ? 0.7 : 1)
    }
}

/// Para un proveedor que esta versión todavía no sabe pintar con su marca.
private struct BotonNeutro: View {
    var titulo: String
    var cargando: Bool
    var accion: () -> Void

    var body: some View {
        Button(action: accion) {
            Text(cargando ? "Abriendo…" : titulo)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.gInk)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.gCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.gSeparator, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(cargando)
        .opacity(cargando ? 0.7 : 1)
    }
}
