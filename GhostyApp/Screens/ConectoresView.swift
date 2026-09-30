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
    /// Hacia dónde va el interruptor mientras se conecta o desconecta: se mueve al tocarlo,
    /// no cuando contesta el servidor.
    @State private var destino: Bool?
    @State private var fallo: String?
    @State private var sesion: ASWebAuthenticationSession?
    @State private var ancla = AnclaDeLaSesion()
    /// El nombre del conector cuyo alta está reiniciando el agente, si hay uno.
    @State private var reiniciando: String?
    /// Apagar pide confirmación: desconectar revoca la llave y el agente deja de poder usarla.
    @State private var porDesconectar: Conector?
    @Environment(Toaster.self) private var toaster: Toaster?

    private var disponibles: [Conector] {
        store.conectores.filter(\.disponible).sorted { $0.conectado && !$1.conectado }
    }
    private var proximas: [Conector] { store.conectores.filter { !$0.disponible } }

    /// «2 de 5 conectadas. Ghosty solo usa las que actives.»
    private var resumen: String {
        let total = disponibles.count
        guard total > 0 else {
            return "Se irán activando conforme estén listas. Ghosty solo usa las que actives."
        }
        let n = disponibles.filter(\.conectado).count
        return "\(n) de \(total) conectada\(total == 1 ? "" : "s"). Ghosty solo usa las que actives."
    }

    var body: some View {
        // ⚠️ Con ScrollView. Sin él la lista no cabía y el VStack se desbordaba por arriba.
        ScrollView {
            contenido
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.top, 14)
                .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .task { await store.cargarConectores() }
        .confirmationDialog(porDesconectar.map { "¿Desconectar \($0.nombre)?" } ?? "",
                            isPresented: Binding(get: { porDesconectar != nil },
                                                 set: { if !$0 { porDesconectar = nil } }),
                            titleVisibility: .visible) {
            Button("Desconectar", role: .destructive) {
                if let c = porDesconectar { Task { await desconectar(c) } }
                porDesconectar = nil
            }
            Button("Cancelar", role: .cancel) { porDesconectar = nil }
        } message: {
            Text("Tus agentes dejarán de poder usarla. Puedes volver a conectarla cuando quieras.")
        }
    }

    private var contenido: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Integraciones").gScreenTitle()
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
            // ⚠️ Son de la CUENTA (`gc_user_connectors`, clave `(sub, provider)`): cualquier
            // agente que invoques usa la misma. El resumen lo dice sin nombrar agente.
            Text(resumen)
                .gScreenSubtitle()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .padding(.bottom, 18)
                .contentTransition(.numericText())
                .animation(.snappy, value: resumen)
                .accessibilityIdentifier("resumen-integraciones")

            // El fallo propio de esta pantalla, o el que reportó el store (una recarga que
            // se cayó, una desconexión que no pudo revocar).
            if let aviso = fallo ?? store.falloDeConectores {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(aviso).font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.gDangerInk)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gDangerTint,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .padding(.bottom, 14)
                .transition(.gIn)
            }
            if let reiniciando {
                HStack(spacing: 8) {
                    GhostySpinner()
                    Text("Reiniciando tu agente para activar \(reiniciando)…").gCaption()
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 14)
                .transition(.gIn)
            }

            if !disponibles.isEmpty { lista(disponibles) }

            if !proximas.isEmpty {
                Text("Muy pronto").gSectionCaps()
                    .padding(.horizontal, 4)
                    .padding(.top, disponibles.isEmpty ? 0 : 22)
                    .padding(.bottom, 8)
                lista(proximas)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: store.conectores)
        .animation(.easeOut(duration: 0.25), value: reiniciando)
    }

    private func lista(_ conectores: [Conector]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(conectores.enumerated()), id: \.element.id) { i, c in
                fila(c)
                    .ghostySeparator(inset: i == conectores.count - 1 ? .infinity : 0)
                    .gIn(delay: min(Double(i), 8) * 0.03)
            }
        }
        // Renglones de borde a borde, como Chats: sin tarjeta.
        .padding(.horizontal, -Theme.Space.screenH)
    }

    private func fila(_ c: Conector) -> some View {
        HStack(spacing: 12) {
            insignia(c)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.nombre)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gInk)
                Text(Self.descripcion(c))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.gInk3)
                    .lineLimit(1)
                // Drive sólo ve lo que eliges en el selector de Google: sin esta puerta,
                // agregar una hoja desde el teléfono obligaba a desconectar y volver a
                // conectar. `/start` de un Drive ya conectado devuelve el selector.
                if c.id == "google-drive", c.conectado, trabajando != c.id {
                    Button("Elegir archivos") { conectar(c) }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                        .buttonStyle(.gPressPill)
                        .padding(.top, 3)
                        .accessibilityIdentifier("connector-files-\(c.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !c.disponible {
                Text("Muy pronto").gCaption()
            } else {
                // Botones oscuros de la paleta, como Android: Conectar relleno, Desconectar
                // con borde.
                let cargando = trabajando == c.id
                Button {
                    guard trabajando == nil else { return }
                    if c.conectado { porDesconectar = c } else { conectar(c) }
                } label: {
                    Group {
                        if cargando { ProgressView().controlSize(.small).tint(c.conectado ? Color.gDark : .white) }
                        else { Text(c.conectado ? "Desconectar" : "Conectar") }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.conectado ? Color.gDark : .white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(c.conectado ? Color.clear : Color.gDark, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.gDark, lineWidth: c.conectado ? 1.2 : 0))
                    .contentShape(Capsule())
                }
                .buttonStyle(.gPressPill)
                .accessibilityLabel("\(c.conectado ? "Desconectar" : "Conectar") \(c.nombre)")
                .accessibilityIdentifier("switch-\(c.id)")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        // Lo que todavía no se puede conectar se ve, pero apagado: enseñar lo que viene es
        // útil; dejar que se toque y no pase nada, no.
        .opacity(c.disponible ? 1 : 0.55)
    }

    /// La marca de casa si la hay; si no, la inicial en el cuadrito de borde del diseño.
    @ViewBuilder
    private func insignia(_ c: Conector) -> some View {
        if let marca = c.marca {
            // La marca va SIN teñir y sin fondo de color: un logo lleva su propia paleta.
            Image(marca, bundle: GhostyAssets.bundle)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous))
        } else {
            Text(String(c.nombre.prefix(1)).uppercased())
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(light: 0x5E5D6B, dark: 0xA3A2B0))
                .frame(width: 36, height: 36)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
                    .strokeBorder(Color.gFillStrong, lineWidth: 1.5))
        }
    }

    /// Qué hace cada una, en una línea. Mapa local mientras gs no mande descripción.
    static func descripcion(_ c: Conector) -> String {
        switch c.id {
        case "easybits":                 return "Archivos, documentos y páginas"
        case "denik":                    return "Agenda y citas"
        case "mailmask":                 return "Correos y listas de envío"
        case "github":                   return "Repos, issues y pull requests"
        case "google", "gmail":          return "Lee y redacta correos"
        case "google-calendar", "calendar": return "Agenda citas"
        case "google-drive", "drive":    return "Archivos"
        case "calendly":                 return "Citas y disponibilidad"
        case "spotify":                  return "Música y playlists"
        case "canva":                    return "Diseños y presentaciones"
        case "odoo":                     return "Ventas, inventario y facturas"
        case "kommo":                    return "CRM y embudo de ventas"
        case "whatsapp":                 return "Responde y envía mensajes"
        case "stripe":                   return "Cobros y cortes"
        case "notion":                   return "Documentos y bases"
        case "shopify":                  return "Catálogo y pedidos"
        default:                         return c.conectado ? "Conectada" : "Disponible"
        }
    }

    private func conectar(_ c: Conector) {
        // Ya conectado = sólo se cambian los archivos elegidos. Las tools los leen en cada
        // llamada, así que no hay por qué cortar la conversación.
        let wasConnected = c.conectado
        trabajando = c.id
        destino = true
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
                    // Cancelar en Google (`detalle=cancelado`) es lo mismo que cerrar la hoja:
                    // no es un fallo. Cualquier otro motivo se dice tal cual lo manda gs.
                    if let volvio, Self.failureDetail(volvio) != "cancelado" {
                        fallo = Self.failureDetail(volvio).map { "No se pudo conectar \(c.nombre): \($0)." }
                            ?? "No se pudo conectar \(c.nombre)."
                    }
                    Task { await store.cargarConectores() }
                    return
                }
                if wasConnected {
                    Task {
                        await store.cargarConectores()
                        trabajando = nil
                    }
                    return
                }
                toaster?.show("\(c.nombre) conectada ✓")
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

    /// El motivo que gs pone en `detalle` cuando no salió bien.
    private static func failureDetail(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "detalle" }?.value
    }

    private func desconectar(_ c: Conector) async {
        trabajando = c.id
        destino = false
        await store.desconectar(c.id)
        trabajando = nil
        if !(store.conectores.first { $0.id == c.id }?.conectado ?? false) {
            toaster?.show("\(c.nombre) desconectada")
        }
    }
}

/// El interruptor de iOS del diseño: 51×31, perilla blanca de 27 con sombra, morado
/// `#5B4BD6` encendido y `#E2E1EA` apagado. Mientras el servidor contesta, la perilla
/// gira (`gspin`).
struct InterruptorGhosty: View {
    let encendido: Bool
    var cargando = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(encendido ? Color.gPrimary : Color.gFillStrong)
                .frame(width: 51, height: 31)
                .overlay(alignment: encendido ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 27, height: 27)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 2)
                        .overlay {
                            if cargando { GhostySpinner(size: 13, lineWidth: 1.8).transition(.opacity) }
                        }
                        .padding(2)
                }
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: encendido)
                .animation(.easeOut(duration: 0.2), value: cargando)
                .contentShape(Capsule())
        }
        .buttonStyle(.gPress(0.95))
        .disabled(cargando)
        .accessibilityAddTraits(encendido ? .isSelected : [])
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
