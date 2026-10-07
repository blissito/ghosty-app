import PhotosUI
import SwiftUI
import UserNotifications

/// El uso de cada agente (`/me/usage?agente=…`), compartido por Perfil y «Cambiar de
/// agente» para no volver a pedirlo en cada apertura ni hacer parpadear las barras.
@MainActor @Observable
final class UsosDeAgentes {
    static let compartido = UsosDeAgentes()
    var usos: [String: PersonalUsage] = [:]
    private var pedidoEn: [String: Date] = [:]

    /// Pide lo que falte o tenga más de un minuto. Best-effort: lo que falle, no se pinta.
    func cargar(_ agentes: [Agent]) async {
        if DemoData.encendido {
            withAnimation(.easeOut(duration: 0.25)) { for a in agentes { usos[a.id] = UsagePane.demo } }
            return
        }
        // Lo último que se supo, al instante: la red refresca por detrás sin spinner.
        for a in agentes where usos[a.id] == nil {
            if let u = UsoEnDisco.leer(agente: a.id) { usos[a.id] = u }
        }
        let pendientes = agentes.filter { a in
            pedidoEn[a.id].map { Date().timeIntervalSince($0) > 60 } ?? true
        }
        for a in pendientes { pedidoEn[a.id] = Date() }
        await withTaskGroup(of: (String, PersonalUsage?).self) { grupo in
            for a in pendientes {
                grupo.addTask { (a.id, await GhostyAPI.usage(agentId: a.id)) }
            }
            for await (id, u) in grupo {
                if let u { withAnimation(.easeOut(duration: 0.25)) { usos[id] = u } }
                else { pedidoEn[id] = nil }
            }
        }
    }
}

/// Perfil (diseño 2026-09): quién eres, tu plan, cuánto lleva cada agente y lo de la
/// cuenta. Sustituye a la hoja de Ajustes: todo lo que vivía ahí está aquí.
///
/// ⚠️ Nunca números inventados. El diseño dice «1,240 créditos»: gs todavía no da saldo
/// en créditos, así que la tarjeta enseña el % REAL de la semana que da `/me/usage`, y
/// cada agente su barra real (o ninguna si corre con su llave o no tiene tope).
/// ⚠️ Sin «mejorar plan» ni ligas de compra: Apple 3.1.1. Aquí se consulta.
struct PerfilView: View {
    var store: LiveAgentStore
    /// Abierto como hoja (desde el fallo de conexión): con botón de cerrar.
    var enHoja = false
    /// El detalle completo del uso (`UsagePane`). Lo abre la tarjeta del plan y, desde
    /// fuera, «Ver mi uso» de la hoja de límite.
    @Binding var verUso: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var abrir
    @Environment(\.scenePhase) private var fase

    @State private var usos = UsosDeAgentes.compartido
    @State private var saliendo = false
    @State private var confirmarBorrado = false
    @State private var borrando = false
    @State private var falloAlBorrar: String?
    @AppStorage(AIConsentSheet.key) private var consentGiven = false
    @State private var abrirConsentimiento = false
    @State private var webAbierta = false
    @State private var avisos: UNAuthorizationStatus?

    /// Lo que se abre en el navegador. La sesión la resuelve la web con su propio
    /// handshake, así que la app no tiene que llevar ninguna credencial ahí.
    private let sitios: [(String, String, URL)] = [
        ("Teams", "Conversaciones, documentos y llamadas", URL(string: "https://teams.ghosty.studio")!),
        ("Tasks", "Tableros y pendientes", URL(string: "https://tasks.ghosty.studio")!),
        ("Sales", "Tu embudo y tus conversaciones de venta", URL(string: "https://sales.ghosty.studio")!),
        ("Privacidad", "Qué guardamos y por qué", URL(string: "https://www.ghosty.studio/privacidad")!),
    ]

    /// El agente que representa TU plan: el primero personal y tuyo; si no hay, el activo.
    private var agenteDelPlan: Agent? {
        store.agents.first { ($0.space ?? .personal).kind == .personal && $0.compartidoPor == nil }
            ?? store.selectedAgent
    }

    private var usoDelPlan: PersonalUsage? { agenteDelPlan.flatMap { usos.usos[$0.id] } }

    /// La foto: la copia local pinta al instante; al abrir se baja la del servidor.
    @State private var foto: UIImage? = FotoDePerfil.local()
    @State private var eligiendoFoto: PhotosPickerItem?
    @State private var subiendoFoto = false
    @State private var falloDeFoto: String?
    /// Cuánto se ha subido el contenido: la portada hace parallax con esto.
    @State private var subido: CGFloat = 0

    /// Perfil como el de WhatsApp: portada con dibujitos, hoja blanca que sube encima, la
    /// foto montada en su borde y las secciones en tarjetas redondeadas (las de iOS).
    var body: some View {
        ScrollView {
            ZStack(alignment: .top) {
                PortadaDePerfil()
                    .frame(height: 260 + max(0, -subido))
                    // Parallax: la portada sube a media velocidad; al tirar hacia abajo, crece.
                    .offset(y: subido > 0 ? subido * 0.5 : subido)
                    .clipped()
                VStack(spacing: 0) {
                    Color.clear.frame(height: 214)
                        .background {
                            GeometryReader { g in
                                Color.clear.preference(key: SubidaDelPerfil.self, value: -g.frame(in: .named("perfil")).minY)
                            }
                        }
                    hoja
                }
            }
        }
        .coordinateSpace(name: "perfil")
        .onPreferenceChange(SubidaDelPerfil.self) { subido = $0 }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .background(Color.gBg.ignoresSafeArea())
        .onChange(of: eligiendoFoto) { _, item in
            guard let item else { return }
            Task { await cambiarFoto(item) }
        }
        .task {
            if let u = await GhostyAPI.avatarURL() {
                if let d = await Descargas.bytes(u), let img = UIImage(data: d) {
                    foto = img
                    FotoDePerfil.guardar(d)
                }
            } else if let local = foto?.jpegData(compressionQuality: 0.85) {
                // El servidor no tiene y el teléfono sí: se sube, como Android.
                _ = try? await GhostyAPI.subirAvatar(local)
            }
        }
        .overlay(alignment: .topTrailing) {
            if enHoja {
                Button { dismiss() } label: {
                    TintedIcon(systemName: "xmark", tint: .gInk, background: .gSeparator, size: 34)
                }
                .buttonStyle(.gPressIcon)
                .padding(16)
            }
        }
        .background(Color.gBg.ignoresSafeArea())
        .task(id: store.agents.map(\.id)) { await usos.cargar(store.agents) }
        .task { await store.cargarAlmacenamiento() }
        .task(id: fase) { await leerAvisos() }
        .sheet(isPresented: $abrirConsentimiento) { AIConsentSheet() }
        .sheet(isPresented: Binding(get: { store.integracionesPedidas },
                                    set: { store.integracionesPedidas = $0 })) {
            ConectoresPane(store: store)
                .padding(.top, 8)
                .background(Color.gBg.ignoresSafeArea())
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { if Gancho.valor("GHOSTY_TAB") == "connectors" { store.integracionesPedidas = true } }
        .sheet(isPresented: $verUso) {
            DetalleDeUso(agente: agenteDelPlan)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(Theme.Radius.sheet)
                #endif
        }
    }

    // MARK: - Perfil estilo WhatsApp

    private var hoja: some View {
        VStack(spacing: 0) {
            avatar
                .padding(.top, -64)
                .padding(.bottom, 12)
            if let nombre = Self.nombreCorto(store.correo) {
                Text(nombre)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let correo = store.correo {
                Text(correo).font(.system(size: 15)).foregroundStyle(Color.gInk3)
            }
            if let falloDeFoto {
                Text(falloDeFoto).gCaption().foregroundStyle(Color.gDangerInk).padding(.top, 6)
            }

            VStack(spacing: 18) {
                seccion {
                    renglonWA("creditcard", "Suscripción",
                              usoDelPlan.map { "Plan \($0.plan.name) · se administra en ghosty.studio" } ?? "Se administra en ghosty.studio")
                    divisorWA
                    Button { verUso = true } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            renglonWA("chart.bar", "Uso", resumenDeUso, chevron: true)
                            barrasDeUso
                        }
                    }
                    .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gFillStrong))
                    .accessibilityIdentifier("tarjeta-plan")
                    if let a = store.almacenamiento {
                        divisorWA
                        VStack(alignment: .leading, spacing: 0) {
                            renglonWA("internaldrive", "Almacenamiento", a.texto)
                            barra(fraccion: a.fraccion, fondo: .gSeparator,
                                  relleno: a.fraccion > 0.9 ? .gDanger : .gPrimary, alto: 4)
                                .padding(.leading, 56).padding(.trailing, 16).padding(.bottom, 14)
                        }
                    }
                }
                seccion {
                    // Integraciones dejó de ser pestaña (2026-10-01): vive aquí.
                    Button { store.integracionesPedidas = true } label: {
                        renglonWA("powerplug", "Integraciones", resumenDeIntegraciones, chevron: true)
                    }
                    .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gFillStrong))
                    .accessibilityIdentifier("ajuste-integraciones")
                    divisorWA
                    Button {
                        #if os(iOS)
                        if let u = URL(string: UIApplication.openNotificationSettingsURLString) { abrir(u) }
                        #endif
                    } label: { renglonWA("bell", "Notificaciones", textoDeAvisos, chevron: true) }
                    .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gFillStrong))
                    .accessibilityIdentifier("ajuste-notificaciones")
                    divisorWA
                    // 5.1.2(i): el permiso de IA de terceros se revisa y se retira aquí.
                    Button { abrirConsentimiento = true } label: {
                        renglonWA("hand.raised", "IA de terceros", consentGiven ? "Permitido" : "No permitido", chevron: true)
                    }
                    .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gFillStrong))
                    .accessibilityIdentifier("ai-consent-settings")
                }
                seccion {
                    Button { abrir(Session.base.appendingPathComponent("privacidad")) } label: {
                        renglonWA("lock", "Privacidad", "Cómo cuidamos tus datos", chevron: true)
                    }
                    .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gFillStrong))
                    divisorWA
                    Button { abrir(Session.base.appendingPathComponent("terminos")) } label: {
                        renglonWA("doc.text", "Términos de servicio", "Lo que acordamos", chevron: true)
                    }
                    .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gFillStrong))
                    divisorWA
                    #if DEBUG
                    // El chat OFICIAL con PowerGhosty, en una conversación nueva: la barra de
                    // subagentes sale sola encima del compositor (SubagentsLayer.swift).
                    Button {
                        // La conversación de PowerGhosty que estabas usando, no una nueva cada vez
                        // (para empezar otra está el lápiz de la cabecera).
                        store.seleccionar("cmuio5hq80001gb17mi7tki0c")
                        store.pestanaPedida = .chat
                        if enHoja { dismiss() }
                    } label: {
                        renglonWA("person.3.sequence", "Laboratorio · Subagentes", "Chat con PowerGhosty y sus subagentes", chevron: true)
                    }
                    .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gFillStrong))
                    divisorWA
                    #endif
                    // ⚠️ El registro, a mano: es lo que se pide por teléfono cuando algo va mal.
                    ShareLink(item: Bitacora.volcar()) {
                        renglonWA("questionmark.circle", "Ayuda", "Compartir registro · \(PerfilView.versionCorta)", chevron: true)
                    }
                    .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gFillStrong))
                }
                seccion {
                    Button {
                        saliendo = true
                        Task {
                            // Cierra ANTES de despedir la hoja: al revés, la tarea se queda a medias.
                            await store.cerrarSesion()
                            if enHoja { dismiss() }
                        }
                    } label: {
                        renglonWA("rectangle.portrait.and.arrow.right", saliendo ? "Saliendo…" : "Cerrar sesión", nil, rojo: true)
                    }
                    .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gFillStrong))
                    .disabled(saliendo)
                    .accessibilityIdentifier("cerrar-sesion")
                    divisorWA
                    // Borrar la cuenta. Apple lo exige dentro de la app (5.1.1(v)).
                    Button { confirmarBorrado = true } label: {
                        renglonWA("trash", borrando ? "Borrando…" : "Borrar mi cuenta", nil, rojo: true)
                    }
                    .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gFillStrong))
                    .disabled(borrando || saliendo)
                    .accessibilityIdentifier("borrar-cuenta")
                    .confirmationDialog("¿Borrar tu cuenta?", isPresented: $confirmarBorrado, titleVisibility: .visible) {
                        Button("Borrar mi cuenta", role: .destructive) {
                            borrando = true
                            Task {
                                falloAlBorrar = await store.borrarCuenta()
                                borrando = false
                                if falloAlBorrar == nil, enHoja { dismiss() }
                            }
                        }
                        Button("Cancelar", role: .cancel) {}
                    } message: {
                        Text("Se borran tus agentes, tus conversaciones y tus archivos. No se puede deshacer.")
                    }
                }
                if let falloAlBorrar {
                    Text(falloAlBorrar).gCaption().foregroundStyle(Color.gDangerInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(PerfilView.version).gCaption().frame(maxWidth: .infinity)
            }
            .padding(.top, 24)
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Color.gBg)
                .shadow(color: .black.opacity(0.06), radius: 8, y: -2)
        )
    }

    /// La foto de 128, con borde blanco de 4, montada en el borde de la hoja, y el botón de
    /// cámara. Sin foto, la inicial en marca.
    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let foto {
                    Image(uiImage: foto).resizable().scaledToFill()
                } else {
                    Text(String((Self.nombreCorto(store.correo) ?? "G").prefix(1)))
                        .font(.system(size: 52, weight: .bold))
                        .foregroundStyle(Color.gPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.gPrimaryTint)
                }
            }
            .frame(width: 128, height: 128)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.gBg, lineWidth: 4))
            .overlay { if subiendoFoto { ProgressView().tint(.white).padding(8).background(.black.opacity(0.35), in: Circle()) } }

            PhotosPicker(selection: $eligiendoFoto, matching: .images) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.gPrimary, in: Circle())
                    .overlay(Circle().stroke(Color.gBg, lineWidth: 3))
            }
            .accessibilityLabel("Cambiar foto")
            .accessibilityIdentifier("perfil-foto")
        }
    }

    /// Una sección: tarjeta redondeada gris claro, como los grupos del perfil de WhatsApp en iOS.
    private func seccion<C: View>(@ViewBuilder _ contenido: () -> C) -> some View {
        VStack(spacing: 0) { contenido() }
            .background(Color.gFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var divisorWA: some View {
        Rectangle().fill(Color.gSeparator).frame(height: 0.5).padding(.leading, 56)
    }

    /// Renglón de WhatsApp: icono metal de 22, título y subtítulo gris.
    private func renglonWA(_ icono: String, _ titulo: String, _ subtitulo: String?,
                           chevron: Bool = false, rojo: Bool = false) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icono)
                .font(.system(size: 19))
                .foregroundStyle(rojo ? Color.gDanger : Color.gInk2)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo)
                    .font(.system(size: 16))
                    .foregroundStyle(rojo ? Color.gDanger : Color.gInk)
                if let subtitulo, !subtitulo.isEmpty {
                    Text(subtitulo)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.gInk3)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.gChevron)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    /// «2 conectadas» o la invitación a conectar.
    private var resumenDeIntegraciones: String {
        let n = store.conectores.filter(\.conectado).count
        return n == 0 ? "Conecta tus servicios" : n == 1 ? "1 conectada" : "\(n) conectadas"
    }

    private var resumenDeUso: String {
        guard let u = usoDelPlan else { return "Toca para ver tu uso" }
        if u.ownKey != nil { return "Tu llave · sin tope de uso" }
        if u.exempt == true { return "Sin tope · acceso anticipado" }
        if let p = u.week.pct { return "\(Self.porcentaje(p)) de tu semana · se renueva \(Self.renovacion(u.week.resetsAt))" }
        return "Sin tope esta semana"
    }

    /// «Esta sesión» y «Esta semana», si el plan tiene tope.
    @ViewBuilder
    private var barrasDeUso: some View {
        if let u = usoDelPlan, u.ownKey == nil, u.exempt != true {
            VStack(alignment: .leading, spacing: 8) {
                if let s = u.session {
                    barraConNombre("Esta sesión", s.pct)
                }
                if let w = u.week.pct {
                    barraConNombre("Esta semana", w)
                }
            }
            .padding(.leading, 56).padding(.trailing, 16).padding(.bottom, 14)
        }
    }

    private func barraConNombre(_ nombre: String, _ pct: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(nombre).font(.system(size: 12)).foregroundStyle(Color.gInk3)
                Spacer()
                Text(Self.porcentaje(pct)).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Color.gInk2)
            }
            barra(fraccion: pct, fondo: .gSeparator, relleno: pct > 0.9 ? .gDanger : .gPrimary, alto: 4)
        }
    }

    /// La parte del correo antes de @, con mayúscula («blissitos@…» → «Blissitos»).
    static func nombreCorto(_ correo: String?) -> String? {
        guard let local = correo?.split(separator: "@").first, !local.isEmpty else { return nil }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    private func cambiarFoto(_ item: PhotosPickerItem) async {
        defer { eligiendoFoto = nil }
        guard let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) else {
            falloDeFoto = "No pude leer esa foto."
            return
        }
        // Reducida a 1024 px, como Android: al instante aquí y después al servidor.
        let chica = FotoDePerfil.reducir(img, lado: 1024)
        guard let jpeg = chica.jpegData(compressionQuality: 0.85) else { return }
        foto = chica
        FotoDePerfil.guardar(jpeg)
        falloDeFoto = nil
        subiendoFoto = true
        defer { subiendoFoto = false }
        do { _ = try await GhostyAPI.subirAvatar(jpeg) }
        catch { falloDeFoto = "Se quedó en este teléfono; no pude subirla. \(error.localizedDescription)" }
    }

    // MARK: - Quién eres

    private var cabecera: some View {
        VStack(spacing: 6) {
            Text(Self.iniciales(store.correo))
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color(hex: 0x5A3A1E))
                .frame(width: 88, height: 88)
                .background(Color(hex: 0xE7C9A9), in: Circle())
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            if let nombre = Self.nombre(store.correo) {
                Text(nombre)
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.52)
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let correo = store.correo {
                Text(correo).font(.system(size: 14)).foregroundStyle(Color.gInk2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// «ana.rivera@…» → «AR»; «blissitos@…» → «BL».
    static func iniciales(_ correo: String?) -> String {
        guard let local = correo?.split(separator: "@").first, !local.isEmpty else { return "G" }
        let partes = local.split(whereSeparator: { ".-_+".contains($0) }).filter { !$0.isEmpty }
        let letras = partes.count >= 2
            ? String(partes[0].prefix(1)) + String(partes[1].prefix(1))
            : String(local.prefix(2))
        return letras.uppercased()
    }

    /// El nombre legible que se puede sacar del correo («ana.rivera» → «Ana Rivera»).
    /// Si parece un número o algo sin letras, no se inventa: sólo va el correo.
    static func nombre(_ correo: String?) -> String? {
        guard let local = correo?.split(separator: "@").first else { return nil }
        let palabras = local.split(whereSeparator: { ".-_+".contains($0) })
            .map { $0.filter(\.isLetter) }
            .filter { $0.count > 1 }
        guard !palabras.isEmpty else { return nil }
        return palabras.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    // MARK: - El plan

    private var tarjetaDelPlan: some View {
        Button { verUso = true } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Plan")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.gDarkInk2)
                    Spacer()
                    if let u = usoDelPlan {
                        Text(u.plan.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x15141B))
                            .padding(.vertical, 4).padding(.horizontal, 10)
                            .background(Color.gLavender, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.gDarkInk2)
                }
                cifraDelPlan
                barra(fraccion: pctDelPlan ?? 0, fondo: .white.opacity(0.12), relleno: Color(hex: 0x8B7DF2), alto: 6)
                    .opacity(pctDelPlan == nil ? 0.4 : 1)
                Text(pieDelPlan)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.gDarkInk2)
            }
            .padding(18)
            .background(Color(hex: 0x15141B), in: RoundedRectangle(cornerRadius: Theme.Radius.plan, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.plan, style: .continuous))
        }
        .buttonStyle(.gPressRow)
        .accessibilityIdentifier("tarjeta-plan")
        .animation(.easeOut(duration: 0.25), value: usoDelPlan)
    }

    /// El % de la semana, si el plan tiene tope y te aplica.
    private var pctDelPlan: Double? {
        guard let u = usoDelPlan, u.ownKey == nil, u.exempt != true else { return nil }
        return u.week.pct
    }

    @ViewBuilder
    private var cifraDelPlan: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let u = usoDelPlan {
                if u.ownKey != nil {
                    Text("Tu llave").font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                    Text("sin tope de uso").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gDarkInk2)
                } else if u.exempt == true {
                    Text("Sin tope").font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                    Text("acceso anticipado").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gDarkInk2)
                } else if let p = u.week.pct {
                    Text(Self.porcentaje(p))
                        .font(.system(size: 30, weight: .heavy).monospacedDigit())
                        .tracking(-0.6)
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("de tu semana").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gDarkInk2)
                } else {
                    Text("Sin tope").font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                    Text("esta semana").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.gDarkInk2)
                }
            } else {
                Text("—").font(.system(size: 30, weight: .heavy)).foregroundStyle(.white.opacity(0.5))
                GhostyDots(color: Color(hex: 0x8B7DF2), size: 5)
            }
        }
    }

    private var pieDelPlan: String {
        var partes: [String] = []
        if let u = usoDelPlan, pctDelPlan != nil {
            partes.append("Se renueva " + Self.renovacion(u.week.resetsAt))
        }
        partes.append("Mismo plan y saldo en la app y en la web")
        return partes.joined(separator: " · ")
    }

    static func porcentaje(_ p: Double) -> String {
        let n = p * 100
        if n > 0 && n < 1 { return "<1 %" }
        return "\(Int(n.rounded())) %"
    }

    static func renovacion(_ d: Date) -> String {
        let es = Locale(identifier: "es_MX")
        if Calendar.current.isDateInToday(d) { return "hoy" }
        if Calendar.current.isDateInTomorrow(d) { return "mañana" }
        return "el " + d.formatted(.dateTime.weekday(.wide).locale(es))
    }

    // MARK: - Uso por agente

    /// La barra de cada agente: la del espacio si es de uno, la del plan (mes si el plan
    /// tiene tope mensual, si no semana) si le aplica. Llave propia o sin tope: sin barra.
    private func medida(_ u: PersonalUsage?) -> (pct: Double, detalle: String, mes: Bool)? {
        guard let u else { return nil }
        if u.applies == false, let ws = u.workspace {
            return (ws.pct, "Del espacio \(ws.name.prefix(1).uppercased() + ws.name.dropFirst())", true)
        }
        if u.ownKey != nil || u.exempt == true || u.applies == false { return nil }
        // El % del plan es de la CUENTA, no del agente: repetirlo en cada fila hacía creer
        // que cada uno gastaba lo mismo. Ese número ya vive en la tarjeta del plan.
        return nil
    }

    @ViewBuilder
    private var usoPorAgente: some View {
        let agentes = store.agents
        if !agentes.isEmpty {
            let medidas = agentes.map { medida(usos.usos[$0.id]) }
            let porMes = medidas.compactMap { $0 }.allSatisfy(\.mes)
            VStack(alignment: .leading, spacing: 8) {
                Text("Uso por agente · \(porMes ? "este mes" : "esta semana")")
                    .gSectionCaps()
                    .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(Array(agentes.enumerated()), id: \.element.id) { i, a in
                        filaDeUso(a, medida: medidas[i], uso: usos.usos[a.id])
                            .ghostySeparator(inset: i == agentes.count - 1 ? .infinity : 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .ghostyCard(radius: Theme.Radius.list)
            }
            .padding(.bottom, 18)
        }
    }

    private func filaDeUso(_ a: Agent, medida m: (pct: Double, detalle: String, mes: Bool)?,
                           uso: PersonalUsage?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgentAvatar(tone: a.tone, size: 26)
                Text(a.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.gInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let m {
                    Text(Self.porcentaje(m.pct))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.gInk)
                        .contentTransition(.numericText())
                } else if uso == nil {
                    GhostySpinner(size: 12, lineWidth: 1.6)
                }
            }
            if let m {
                barra(fraccion: m.pct, fondo: .gSeparator, relleno: .gPrimary, alto: 5)
                    .transition(.opacity)
            }
            Text(detalle(a, medida: m, uso: uso))
                .font(.system(size: 12))
                .foregroundStyle(Color.gInk3)
                .lineLimit(1)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("uso-\(a.id)")
    }

    private func detalle(_ a: Agent, medida m: (pct: Double, detalle: String, mes: Bool)?,
                         uso: PersonalUsage?) -> String {
        let tipo = CambiarAgenteSheet.tipo(a)
        if let m { return m.detalle }
        if let u = uso, u.ownKey == nil, u.exempt != true, u.applies != false,
           u.month.pct != nil || u.week.pct != nil {
            return "\(tipo) · Cuenta en tu plan"
        }
        if let k = uso?.ownKey {
            let turnos = k.turnsWeek.map { " · \($0) turnos esta semana" } ?? ""
            return "\(tipo) · Con tu llave\(turnos)"
        }
        if uso?.exempt == true { return "\(tipo) · Sin tope" }
        if uso != nil, a.compartidoPor != nil { return "\(tipo) · Cuenta en el plan de quien lo comparte" }
        return tipo
    }

    // MARK: - Ajustes

    private var ajustes: some View {
        VStack(spacing: 0) {
            fila("Notificaciones", icono: "bell", valor: textoDeAvisos) {
                #if os(iOS)
                if let u = URL(string: UIApplication.openNotificationSettingsURLString) { abrir(u) }
                #endif
            }
            .accessibilityIdentifier("ajuste-notificaciones")

            // 5.1.2(i): el permiso de IA de terceros se revisa y se retira aquí.
            fila("IA de terceros", icono: "hand.raised", valor: consentGiven ? "Permitido" : "No permitido") {
                abrirConsentimiento = true
            }
            .accessibilityIdentifier("ai-consent-settings")

            if let a = store.almacenamiento {
                VStack(alignment: .leading, spacing: 8) {
                    filaEstatica("Almacenamiento", icono: "internaldrive", valor: a.texto)
                    // ⚠️ El tope lo dice el SERVIDOR, no se calcula aquí.
                    barra(fraccion: a.fraccion, fondo: .gSeparator,
                          relleno: a.fraccion > 0.9 ? .gDanger : .gPrimary, alto: 4)
                        .padding(.leading, 48).padding(.trailing, 16)
                        .padding(.bottom, 14)
                        .padding(.top, -6)
                }
                .ghostySeparator()
            }

            fila("En la web", icono: "globe", valor: "", girar: webAbierta) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { webAbierta.toggle() }
            }
            .accessibilityIdentifier("ajuste-web")
            if webAbierta {
                VStack(spacing: 0) {
                    ForEach(sitios, id: \.0) { nombre, detalle, url in
                        Button { abrir(url) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(nombre).font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.gInk)
                                    Text(detalle).font(.system(size: 12)).foregroundStyle(Color.gInk3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.gChevron)
                            }
                            .padding(.vertical, 10)
                            .padding(.leading, 48).padding(.trailing, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gCardPressed))
                    }
                }
                .padding(.bottom, 6)
                .background(Color.gCardSunken)
                .ghostySeparator()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ⚠️ El registro, a mano: es lo que se pide por teléfono cuando algo va mal.
            if !Bitacora.estaVacia {
                ShareLink(item: Bitacora.volcar()) {
                    renglon("Compartir registro", icono: "doc.text", valor: "", chevron: true)
                }
                .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gCardPressed))
                .ghostySeparator()
            }

            filaEstatica("Versión", icono: "info.circle", valor: PerfilView.versionCorta)
                .ghostySeparator()

            // Borrar la cuenta. Apple lo exige dentro de la app (5.1.1(v)).
            Button { confirmarBorrado = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: 17))
                        .frame(width: 20)
                    Text(borrando ? "Borrando…" : "Borrar mi cuenta")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if borrando { GhostySpinner(size: 14) }
                }
                .foregroundStyle(Color.gDanger)
                .padding(.vertical, 14).padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gCardPressed))
            .disabled(borrando || saliendo)
            .accessibilityIdentifier("borrar-cuenta")
            .confirmationDialog("¿Borrar tu cuenta?", isPresented: $confirmarBorrado, titleVisibility: .visible) {
                Button("Borrar mi cuenta", role: .destructive) {
                    borrando = true
                    Task {
                        falloAlBorrar = await store.borrarCuenta()
                        borrando = false
                        if falloAlBorrar == nil, enHoja { dismiss() }
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se borran tus agentes, tus conversaciones y tus archivos. No se puede deshacer.")
            }

            if let falloAlBorrar {
                Text(falloAlBorrar).gCaption().foregroundStyle(Color.gDangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ghostyCard(radius: Theme.Radius.list)
    }

    private var cerrarSesion: some View {
        Button {
            saliendo = true
            Task {
                // Cierra ANTES de despedir la hoja: al revés, la tarea se queda a medias.
                await store.cerrarSesion()
                if enHoja { dismiss() }
            }
        } label: {
            Text(saliendo ? "Saliendo…" : "Cerrar sesión")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.gDanger)
                .frame(maxWidth: .infinity)
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.gPressRow)
        .disabled(saliendo)
        .accessibilityIdentifier("cerrar-sesion")
    }

    // MARK: - Piezas

    private func fila(_ titulo: String, icono: String, valor: String, girar: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            renglon(titulo, icono: icono, valor: valor, chevron: true, girar: girar)
        }
        .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gCardPressed))
        .ghostySeparator()
    }

    private func filaEstatica(_ titulo: String, icono: String, valor: String) -> some View {
        renglon(titulo, icono: icono, valor: valor, chevron: false)
    }

    /// La fila del diseño: icono de trazo 20, etiqueta 500 15, valor 14 gris y chevron.
    private func renglon(_ titulo: String, icono: String, valor: String, chevron: Bool,
                         girar: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icono)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.gInk)
                .frame(width: 20)
            Text(titulo)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.gInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !valor.isEmpty {
                Text(valor)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.gInk3)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.gChevron)
                    .rotationEffect(.degrees(girar ? 90 : 0))
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    private func barra(fraccion: Double, fondo: Color, relleno: Color, alto: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(fondo)
                Capsule().fill(relleno)
                    .frame(width: max(fraccion > 0 ? alto : 0, geo.size.width * min(1, max(0, fraccion))))
            }
        }
        .frame(height: alto)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraccion)
    }

    // MARK: - Datos del teléfono

    private var textoDeAvisos: String {
        switch avisos {
        case .authorized, .provisional, .ephemeral: "Al terminar"
        case .denied: "Apagadas"
        case .notDetermined: "Sin decidir"
        default: ""
        }
    }

    private func leerAvisos() async {
        let ajustes = await UNUserNotificationCenter.current().notificationSettings()
        avisos = ajustes.authorizationStatus
    }

    /// Qué build trae este teléfono. Sin esto no hay forma de saberlo sin cable.
    static var version: String {
        let b = Bundle.main
        let v = b.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let n = b.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let commit = b.infoDictionary?["GhostyCommit"] as? String ?? ""
        let sufijo = (commit.isEmpty || commit.hasPrefix("$(")) ? "" : " · \(commit)"
        return "Ghosty \(v) (build \(n))\(sufijo)"
    }

    static var versionCorta: String {
        let b = Bundle.main
        let v = b.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let n = b.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(n))"
    }
}

/// El detalle completo del uso: la tarjeta del plan abre esto (y «Ver mi uso» de la hoja
/// de límite). Es el `UsagePane` de siempre, con su título.
struct DetalleDeUso: View {
    let agente: Agent?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tu uso")
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(Color.gInk)
                Spacer()
                Button { dismiss() } label: {
                    TintedIcon(systemName: "xmark", tint: .gInk, background: .gSeparator, size: 34)
                }
                .buttonStyle(.gPressIcon)
                .accessibilityIdentifier("cerrar-uso")
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 20)
            .padding(.bottom, 14)
            ScrollView {
                if let agente {
                    UsagePane(agent: agente).padding(.bottom, 28)
                } else {
                    EmptyState(icon: "chart.bar", title: "Sin agentes",
                               detail: "Cuando tengas un agente verás aquí cuánto lleva tu plan.")
                        .padding(.top, 40)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Color.gBg.ignoresSafeArea())
        .accessibilityIdentifier("detalle-uso")
    }
}

private struct SubidaDelPerfil: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// La portada del perfil: fondo lila claro con dibujitos (chat, estrella, destellos,
/// carpeta, pieza, corazón, micrófono, rayo) en la marca al 22 %, girados ±25° y en filas
/// escalonadas, como el patrón de fondo de WhatsApp.
struct PortadaDePerfil: View {
    private static let dibujos = ["bubble.left.fill", "star.fill", "sparkles", "folder.fill",
                                  "puzzlepiece.fill", "heart.fill", "mic.fill", "bolt.fill"]

    var body: some View {
        GeometryReader { g in
            let paso: CGFloat = 56
            let columnas = Int(g.size.width / paso) + 2
            let filas = Int(g.size.height / paso) + 2
            ZStack(alignment: .topLeading) {
                Color(hex: 0xF5F5FC)
                ForEach(0..<filas, id: \.self) { f in
                    ForEach(0..<columnas, id: \.self) { c in
                        let i = f * 3 + c
                        Image(systemName: Self.dibujos[i % Self.dibujos.count])
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x8483E0).opacity(0.22))
                            .rotationEffect(.degrees(i % 2 == 0 ? 25 : -25))
                            .position(x: CGFloat(c) * paso + (f % 2 == 0 ? 0 : paso / 2),
                                      y: CGFloat(f) * paso + 20)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
