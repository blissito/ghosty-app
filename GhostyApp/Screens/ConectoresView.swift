import AuthenticationServices
import SwiftUI
import UIKit

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
    /// La hoja de «Tu sistema» (MCP propio).
    @State private var hojaMCP = false
    /// El conector cuya intro está abierta (la manda gs; hoy GitHub).
    @State private var introDe: Conector?
    /// Se conecta al CERRARSE la intro: presentar el navegador mientras la hoja se va falla.
    @State private var pendienteDeConectar: Conector?
    @Environment(\.openURL) private var abrir

    private var disponibles: [Conector] {
        store.conectores.filter(\.disponible).sorted { $0.conectado && !$1.conectado }
    }
    private var proximas: [Conector] { store.conectores.filter { !$0.disponible } }

    /// «2 de 5 conectadas. Ghosty solo usa las que actives.»
    private var resumen: String {
        let total = disponibles.count
        guard total > 0 else {
            return "Conecta tus servicios y los uso por ti."
        }
        let n = disponibles.filter(\.conectado).count
        return "\(n) de \(total) conectada\(total == 1 ? "" : "s"). Conecta tus servicios y los uso por ti."
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
        .sheet(item: $introDe, onDismiss: {
            if let c = pendienteDeConectar { pendienteDeConectar = nil; conectar(c) }
        }) { c in
            if let intro = c.intro {
                IntroConectorSheet(intro: intro) {
                    pendienteDeConectar = c
                    introDe = nil
                }
            }
        }
        .sheet(isPresented: $hojaMCP) {
            ConectarMCPSheet { nombre, url, token in
                await conectarMCP(nombre: nombre, url: url, token: token)
            }
        }
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
            Text("Ya no podré usar este servicio por ti.")
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
                Text("Próximamente").gSectionCaps()
                    .padding(.horizontal, 4)
                    .padding(.top, disponibles.isEmpty ? 0 : 22)
                    .padding(.bottom, 8)
                lista(proximas)
            }

            // Fija al final del catálogo: traer SU sistema (un servidor MCP) al agente activo.
            filaTuSistema
                .padding(.horizontal, -Theme.Space.screenH)
                .padding(.top, 14)
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
                // Administrarlo del otro lado (GitHub: «Repos»). Lo manda gs.
                if c.conectado, !cargando, let m = c.manage, let u = m.url {
                    Button { abrir(u) } label: {
                        Text(m.label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.gDark)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .overlay(Capsule().strokeBorder(Color.gDark, lineWidth: 1.2))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.gPressPill)
                    .accessibilityLabel("\(m.label) de \(c.nombre)")
                    .accessibilityIdentifier("connector-manage-\(c.id)")
                }
                Button {
                    guard trabajando == nil else { return }
                    if c.conectado { porDesconectar = c }
                    else if c.intro != nil { fallo = nil; introDe = c }
                    else { conectar(c) }
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

    /// El logo del servidor (`logoPng`) primero; mientras baja o si no hay red, el asset
    /// empaquetado; sin él, el logo viejo de gs, el símbolo o la inicial.
    @ViewBuilder
    private func insignia(_ c: Conector) -> some View {
        if let url = c.logoPngURL {
            AsyncImage(url: url) { fase in
                if let img = fase.image {
                    cuadroDeLogo(img.resizable())
                } else {
                    insigniaLocal(c)
                }
            }
        } else {
            insigniaLocal(c)
        }
    }

    /// Respaldo sin red: la marca empaquetada, el logo remoto viejo o el símbolo.
    @ViewBuilder
    private func insigniaLocal(_ c: Conector) -> some View {
        if let marca = c.marca {
            cuadroDeLogo(Image(marca, bundle: GhostyAssets.bundle).resizable())
        } else if let url = c.logoURL {
            AsyncImage(url: url) { fase in
                if let img = fase.image { cuadroDeLogo(img.resizable()) } else { insigniaSinLogo(c) }
            }
        } else {
            insigniaSinLogo(c)
        }
    }

    /// La marca va SIN teñir y sin fondo de color: un logo lleva su propia paleta.
    /// Cuadro blanco de 42, radio 12, borde fino y el logo de 26, como Android.
    private func cuadroDeLogo(_ img: Image) -> some View {
        img.interpolation(.high)
            .scaledToFit()
            .frame(width: 26, height: 26)
            .frame(width: 42, height: 42)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.gSeparator, lineWidth: 1))
    }

    /// El SF Symbol del servidor si este iOS lo tiene; si no, la inicial.
    @ViewBuilder
    private func insigniaSinLogo(_ c: Conector) -> some View {
        if let simbolo = c.sfSymbol, UIImage(systemName: simbolo) != nil {
            Image(systemName: simbolo)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(light: 0x5E5D6B, dark: 0xA3A2B0))
                .frame(width: 42, height: 42)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.gSeparator, lineWidth: 1))
        } else {
            Text(String(c.nombre.prefix(1)).uppercased())
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(light: 0x5E5D6B, dark: 0xA3A2B0))
                .frame(width: 42, height: 42)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.gSeparator, lineWidth: 1))
        }
    }

    /// Qué hace cada una, en una línea. Manda la `descripcion` del servidor; el mapa local
    /// sólo cubre a un servidor viejo o al catálogo de emergencia.
    static func descripcion(_ c: Conector) -> String {
        if let d = c.descripcion?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
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
        case "hubspot":                  return "Contactos, negocios y notas"
        case "slack":                    return "Avisa a tu equipo"
        case "woocommerce":              return "Productos y pedidos"
        case "facturama":                return "Timbra y busca facturas"
        case "mercadopago":              return "Links de pago y cobros"
        case "skydropx":                 return "Guías y envíos"
        case "elevenlabs":               return "Voces y audio"
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

    private var filaTuSistema: some View {
        Button {
            guard trabajando == nil else { return }
            fallo = nil
            hojaMCP = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(light: 0x5E5D6B, dark: 0xA3A2B0))
                    .frame(width: 42, height: 42)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.gSeparator, lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tu sistema")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                    Text("Conecta su servidor MCP")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.gInk3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if trabajando == "mcp" {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gDark)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connector-mcp")
    }

    /// POST a `mcp/connect` con el agente activo. Devuelve el error para que la hoja lo
    /// enseñe; `nil` = la hoja se cierra (agregado o pasando a autorizar).
    private func conectarMCP(nombre: String, url: String, token: String?) async -> String? {
        let agente = store.selectedAgentID
        guard !agente.isEmpty else { return "Elige primero un agente." }
        switch await GhostyAPI.conectarMCP(agente: agente, nombre: nombre, url: url, token: token) {
        case .fallo(let e):
            return e
        case .agregado(let n):
            hojaMCP = false
            activadoMCP(n)
            return nil
        case .autorizar(let u):
            hojaMCP = false
            autorizarMCP(u, nombre: nombre)
            return nil
        }
    }

    /// El MCP pidió OAuth: la misma hoja de navegador que los conectores. gs vuelve a
    /// `…://conector?conector=mcp&estado=ok&mcp=<name>` (o `estado=error&detalle=…`).
    private func autorizarMCP(_ url: URL, nombre: String) {
        trabajando = "mcp"
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: Session.redirectScheme) { volvio, err in
            if let err, (err as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                trabajando = nil
                fallo = err.localizedDescription
                return
            }
            // Sin URL = la persona cerró la hoja: no es un fallo.
            guard let volvio else { trabajando = nil; return }
            let q = URLComponents(url: volvio, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let valor = { (k: String) in q.first { $0.name == k }?.value }
            guard valor("conector") == "mcp", valor("estado") == "ok" else {
                trabajando = nil
                let detalle = valor("detalle")
                if detalle != "cancelado" {
                    fallo = detalle.map { "No se pudo conectar \(nombre): \($0)." } ?? "No se pudo conectar \(nombre)."
                }
                return
            }
            activadoMCP(valor("mcp") ?? nombre)
        }
        s.presentationContextProvider = ancla
        sesion = s
        s.start()
    }

    /// El agente congela sus tools al abrir la conversación: se abre una nueva y se dice.
    private func activadoMCP(_ nombre: String) {
        toaster?.show("\(nombre) conectado ✓ Tu agente lo usa desde la siguiente conversación", duracion: 3)
        trabajando = "mcp"
        reiniciando = nombre
        Task {
            await store.reiniciarSesionTrasConectar()
            trabajando = nil
            reiniciando = nil
        }
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

/// Lo que se lee antes de ir a conectar: qué marcar del otro lado y por qué es seguro.
/// El texto entero lo manda gs (`intro` del conector).
struct IntroConectorSheet: View {
    let intro: IntroDeConector
    let continuar: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(intro.title).gScreenTitle()
                        .padding(.bottom, 4)
                    if !intro.subtitle.isEmpty {
                        Text(intro.subtitle).gScreenSubtitle()
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 18)
                    }
                    ForEach(Array(intro.items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.gInk)
                            Text(item.body)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.gInk3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.top, 24)
            }
            .scrollIndicators(.hidden)
            VStack(spacing: 6) {
                Button(action: continuar) {
                    Text(intro.continueLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.gDark, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.gPressPill)
                .accessibilityIdentifier("intro-continuar")
                Button(intro.cancelLabel) { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gInk3)
                    .frame(height: 40)
                    .accessibilityIdentifier("intro-cancelar")
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.bottom, 12)
        }
        .presentationDetents([.large])
        .presentationBackground(Color.gBg)
    }
}

/// «Tu sistema»: nombre, URL https y token opcional del servidor MCP de la persona.
struct ConectarMCPSheet: View {
    /// Devuelve el error a enseñar, o `nil` si ya se cerró.
    let conectar: (_ nombre: String, _ url: String, _ token: String?) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var nombre = ""
    @State private var url = "https://"
    @State private var token = ""
    @State private var enviando = false
    @State private var error: String?

    /// El slug que acepta gs: `^[a-z0-9][a-z0-9_-]{0,40}$`.
    private var nombreValido: Bool {
        nombre.range(of: "^[a-z0-9][a-z0-9_-]{0,40}$", options: .regularExpression) != nil
    }
    /// a-z, 0-9, - y _ (espacio → guion), máximo 41.
    static func slug(_ v: String) -> String {
        let permitidos = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let base = v.lowercased().replacingOccurrences(of: " ", with: "-")
        return String(base.filter { permitidos.contains($0) }.prefix(41))
    }
    private var urlValida: Bool {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), u.scheme == "https",
              let h = u.host, !h.isEmpty else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("mi-sistema", text: $nombre)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: nombre) { _, v in
                            // a-z, 0-9, - y _: se normaliza al escribir.
                            let limpio = Self.slug(v)
                            if limpio != v { nombre = limpio }
                        }
                        .accessibilityIdentifier("mcp-nombre")
                } header: { Text("Nombre") } footer: { Text("Minúsculas, números, - y _.") }
                Section {
                    TextField("https://tu-sistema.com/mcp", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("mcp-url")
                } header: { Text("URL del servidor MCP") }
                Section {
                    SecureField("Opcional", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("mcp-token")
                } header: { Text("Token") } footer: {
                    Text("Si tu servidor usa OAuth, déjalo vacío: te pediré autorizar.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Color.gDangerInk).font(.system(size: 13)) }
                }
            }
            .navigationTitle("Tu sistema")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }.disabled(enviando)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if enviando {
                        ProgressView()
                    } else {
                        Button("Conectar") { enviar() }
                            .disabled(!nombreValido || !urlValida)
                            .accessibilityIdentifier("mcp-conectar")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(enviando)
    }

    private func enviar() {
        enviando = true
        error = nil
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let e = await conectar(nombre, url.trimmingCharacters(in: .whitespaces), t.isEmpty ? nil : t)
            enviando = false
            error = e
        }
    }
}
