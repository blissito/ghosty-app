import AuthenticationServices
import SwiftUI

/// Las apps que tu agente puede usar en tu nombre.
///
/// ⚠️ El OAuth se hace AQUÍ, en el teléfono. Se dio por hecho que había que mandar a la
/// persona al panel web «porque OAuth necesita navegador», y la app ya tiene uno:
/// `ASWebAuthenticationSession`, el mismo con el que se entra con Google o Apple. Sacar a
/// alguien de la app a mitad de una conversación para volver a entrar es justo la fricción
/// que este producto no puede permitirse.
/// Las apps que tus agentes pueden usar en tu nombre. Es una PESTAÑA, no un panel del
/// agente.
///
/// ⚠️ La conexión es de la CUENTA: la tabla es `gc_user_connectors` con clave
/// `(sub, provider)` y el agente usa la de quien lo invoca. Metida en el panel del agente
/// —donde estuvo un rato— parecía que cada agente tenía las suyas y que había que
/// conectarlas una por una.
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
    /// El nombre del conector cuyo alta está reiniciando el agente, si hay uno.
    @State private var reiniciando: String?

    private var conectados: [Conector] { store.conectores.filter(\.conectado) }
    private var disponibles: [Conector] { store.conectores.filter { !$0.conectado } }

    var body: some View {
        // ⚠️ Con ScrollView. Sin él la lista no cabía y el VStack se desbordaba por arriba:
        // el título acababa bajo la isla y las filas salían de la tarjeta. Las otras
        // pestañas ya lo tienen; ésta nació como panel de una hoja, donde el scroll lo
        // ponía la hoja.
        ScrollView {
            contenido.padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var contenido: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Integraciones").gScreenTitle()
                // ⚠️ Se dice que son TUYAS, no del agente: la conexión cuelga de la persona
                // y cualquier agente que invoques usa la misma. Sin esta línea, en una app
                // con varios agentes se lee como que hay que conectarlas una por una.
                Text("Son de tu cuenta: cualquier agente que uses trabaja con ellas.")
                    .gMeta()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 8)
            // El fallo propio de esta pantalla, o el que reportó el store (una recarga que
            // se cayó, una desconexión que no pudo revocar).
            if let aviso = fallo ?? store.falloDeConectores {
                Text(aviso).gCaption().foregroundStyle(Color.gDangerInk)
                    .padding(.horizontal, Theme.Space.screenH)
            }
            if let reiniciando {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reiniciando tu agente para activar \(reiniciando)…").gCaption()
                }
                .padding(.horizontal, Theme.Space.screenH)
                .transition(.opacity)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
            if let marca = c.marca {
                // La marca va SIN teñir y sin fondo de color: un logo lleva su propia
                // paleta, y meterlo en una caja morada lo desfigura.
                Image(marca, bundle: GhostyAssets.bundle)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous))
            } else {
                TintedIcon(systemName: c.icono,
                           tint: c.conectado ? .gPrimary : .gInk2,
                           background: c.conectado ? .gPrimaryTint : .gFill, size: 34)
            }
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
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: Session.redirectScheme) { volvio, err in
                // Cancelar no es un error: es la persona cerrando la hoja.
                if let err, (err as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                    trabajando = nil
                    fallo = err.localizedDescription
                    return
                }
                // Sin URL de vuelta = canceló. No se toca nada.
                guard let volvio, Self.salioBien(volvio) else {
                    trabajando = nil
                    if volvio != nil { fallo = "No se pudo conectar \(c.nombre)." }
                    Task { await store.cargarConectores() }
                    return
                }
                // ⚠️ El servidor acaba de reiniciar la caja para meterle la llave, y una
                // sesión ACP congela sus herramientas al nacer. Si nos quedamos en la
                // conversación de antes, el agente seguirá sin las tools y lo contará mal
                // —dirá que la integración no está activa—. Así que se abre una nueva, y
                // se DICE, porque el corte del turno se ve como un cuelgue.
                reiniciando = c.nombre
                Task {
                    await store.reiniciarSesionTrasConectar()
                    trabajando = nil
                    reiniciando = nil
                }
            }
            s.presentationContextProvider = ancla
            sesion = s
            s.start()
        }
    }

    /// El callback vuelve como `…://conector?conector=easybits&estado=ok`. El estado lo
    /// pone NUESTRO servidor tras guardar la llave, no easybits: es lo único que prueba
    /// que la conexión llegó a completarse de este lado.
    private static func salioBien(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "estado" }?.value == "ok"
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
