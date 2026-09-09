import AuthenticationServices
import SwiftUI

/// Las apps que tu agente puede usar en tu nombre.
///
/// ⚠️ El OAuth se hace AQUÍ, en el teléfono. Se dio por hecho que había que mandar a la
/// persona al panel web «porque OAuth necesita navegador», y la app ya tiene uno:
/// `ASWebAuthenticationSession`, el mismo con el que se entra con Google o Apple. Sacar a
/// alguien de la app a mitad de una conversación para volver a entrar es justo la fricción
/// que este producto no puede permitirse.
struct ConectoresView: View {
    let store: LiveAgentStore
    @Environment(\.dismiss) private var dismiss
    @State private var busqueda = ""
    @State private var trabajando: String?
    @State private var fallo: String?
    @State private var sesion: ASWebAuthenticationSession?
    @State private var ancla = AnclaDeLaSesion()

    private var filtrados: [Conector] {
        let q = busqueda.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? store.conectores
            : store.conectores.filter { $0.nombre.lowercased().contains(q) }
    }
    private var conectados: [Conector] { filtrados.filter(\.conectado) }
    private var disponibles: [Conector] { filtrados.filter { !$0.conectado } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    TintedIcon(systemName: "xmark", tint: .gInk, background: .gSeparator, size: 34)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Integraciones").font(.system(size: 16, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 34, height: 34)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            // El buscador sólo aparece cuando hay bastantes: con cinco conectores es una
            // fila que estorba, y con veinte es lo primero que se usa.
            if store.conectores.count > 8 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13))
                        .foregroundStyle(Color.gInk3)
                    TextField("Buscar", text: $busqueda).textFieldStyle(.plain).font(.system(size: 15))
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.top, 14)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let fallo {
                        Text(fallo).gCaption().foregroundStyle(Color.gDangerInk)
                            .padding(.horizontal, Theme.Space.screenH)
                    }
                    if !conectados.isEmpty { seccion("Conectadas", conectados) }
                    if !disponibles.isEmpty { seccion("Disponibles", disponibles) }
                }
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
        }
        .background(Color.gBg.ignoresSafeArea())
        .task { await store.cargarConectores() }
    }

    private func seccion(_ titulo: String, _ lista: [Conector]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titulo).gSectionTitle().padding(.horizontal, Theme.Space.screenH)
            VStack(spacing: 0) {
                ForEach(Array(lista.enumerated()), id: \.element.id) { i, c in
                    fila(c)
                        .ghostySeparator(inset: i == lista.count - 1 ? .infinity : 60)
                }
            }
            .padding(.horizontal, Theme.Space.cardH)
            .ghostyCard()
            .padding(.horizontal, Theme.Space.screenH)
        }
    }

    private func fila(_ c: Conector) -> some View {
        HStack(spacing: 12) {
            TintedIcon(systemName: c.icono,
                       tint: c.conectado ? .gPrimary : .gInk2,
                       background: c.conectado ? .gPrimaryTint : .gFill, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.nombre).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.gInk)
                if c.conectado { Text("Conectada").gCaption() }
            }
            Spacer(minLength: 8)
            if trabajando == c.id {
                ProgressView().controlSize(.small)
            } else if c.conectado {
                Button("Quitar") { Task { await desconectar(c) } }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.gInk3)
            } else {
                Button("Conectar") { conectar(c) }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.gPrimary)
            }
        }
        .padding(.vertical, 11)
    }

    // MARK: - Acciones

    private func conectar(_ c: Conector) {
        trabajando = c.id
        fallo = nil
        Task {
            guard let url = await store.urlDeConexion(c.id) else {
                trabajando = nil
                fallo = "No pude empezar la conexión con \(c.nombre)."
                return
            }
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: Session.redirectScheme) { _, err in
                trabajando = nil
                // Cancelar no es un error: es la persona cerrando la hoja.
                if let err, (err as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                    fallo = err.localizedDescription
                }
                Task { await store.cargarConectores() }
            }
            s.presentationContextProvider = ancla
            s.prefersEphemeralWebBrowserSession = false   // reusa la sesión del navegador
            sesion = s
            s.start()
        }
    }

    private func desconectar(_ c: Conector) async {
        trabajando = c.id
        await store.desconectar(c.id)
        trabajando = nil
    }
}

/// Dónde se presenta la hoja del navegador. `ASWebAuthenticationSession` lo exige.
final class AnclaDeLaSesion: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
