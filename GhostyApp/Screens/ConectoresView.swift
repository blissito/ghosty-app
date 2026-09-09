import AuthenticationServices
import SwiftUI

/// Las apps que tu agente puede usar en tu nombre.
///
/// ⚠️ El OAuth se hace AQUÍ, en el teléfono. Se dio por hecho que había que mandar a la
/// persona al panel web «porque OAuth necesita navegador», y la app ya tiene uno:
/// `ASWebAuthenticationSession`, el mismo con el que se entra con Google o Apple. Sacar a
/// alguien de la app a mitad de una conversación para volver a entrar es justo la fricción
/// que este producto no puede permitirse.
/// Las apps que tu agente puede usar en tu nombre, dentro del panel del agente.
///
/// ⚠️ Vive AQUÍ y no en Ajustes: son capacidades DEL AGENTE. En Ajustes quedaban a tres
/// toques y detrás de un engrane que casi nadie encuentra — y menos desde que el `+` dejó
/// de llevar "Tu cuenta".
///
/// ⚠️ El OAuth se hace en el teléfono. Se dio por hecho que había que mandar a la persona
/// al panel web «porque OAuth necesita navegador», y la app ya tiene uno:
/// `ASWebAuthenticationSession`, el mismo con el que se entra con Google o Apple.
struct ConectoresPane: View {
    let store: LiveAgentStore
    @State private var trabajando: String?
    @State private var fallo: String?
    @State private var sesion: ASWebAuthenticationSession?
    @State private var ancla = AnclaDeLaSesion()

    private var conectados: [Conector] { store.conectores.filter(\.conectado) }
    private var disponibles: [Conector] { store.conectores.filter { !$0.conectado } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let fallo {
                Text(fallo).gCaption().foregroundStyle(Color.gDangerInk)
                    .padding(.horizontal, Theme.Space.screenH)
            }
            if !conectados.isEmpty { seccion("Conectadas", conectados) }
            if !disponibles.isEmpty {
                seccion(store.hayConectores ? "Disponibles" : "En camino", disponibles)
            }
            if !store.hayConectores {
                Text("Se irán activando conforme estén listas. Mientras tanto, tu agente ya puede leer y escribir archivos y trabajar con lo que le mandes.")
                    .gCaption()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.screenH)
            }
        }
        .task { await store.cargarConectores() }
    }

    private func seccion(_ titulo: String, _ lista: [Conector]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titulo).gSectionTitle().padding(.horizontal, Theme.Space.screenH)
            VStack(spacing: 0) {
                ForEach(Array(lista.enumerated()), id: \.element.id) { i, c in
                    fila(c).ghostySeparator(inset: i == lista.count - 1 ? .infinity : 60)
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
            if !c.disponible {
                Text("Muy pronto").gCaption()
            } else if trabajando == c.id {
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
        // Lo que todavía no se puede conectar se ve, pero apagado: enseñar lo que viene es
        // útil; dejar que se toque y no pase nada, no.
        .opacity(c.disponible ? 1 : 0.55)
    }

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
