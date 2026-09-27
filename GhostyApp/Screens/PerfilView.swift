import SwiftUI
import UserNotifications

/// El uso de cada agente (`/me/usage?agente=…`), compartido por Perfil y «Cambiar de
/// agente» para no volver a pedirlo en cada apertura ni hacer parpadear las barras.
@MainActor @Observable
final class UsosDeAgentes {
    static let compartido = UsosDeAgentes()
    private(set) var usos: [String: PersonalUsage] = [:]
    private var pedidoEn: [String: Date] = [:]

    /// Pide lo que falte o tenga más de un minuto. Best-effort: lo que falle, no se pinta.
    func cargar(_ agentes: [Agent]) async {
        if DemoData.encendido {
            withAnimation(.easeOut(duration: 0.25)) { for a in agentes { usos[a.id] = UsagePane.demo } }
            return
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cabecera
                    .padding(.top, 18)
                    .padding(.bottom, 22)
                    .gIn()
                tarjetaDelPlan
                    .padding(.bottom, 18)
                    .gIn(delay: 0.05)
                usoPorAgente
                    .gIn(delay: 0.1)
                ajustes
                    .gIn(delay: 0.15)
                cerrarSesion
                    .padding(.top, 14)
                Text(PerfilView.version)
                    .gCaption()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
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
        .sheet(isPresented: $verUso) {
            DetalleDeUso(agente: agenteDelPlan)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(Theme.Radius.sheet)
                #endif
        }
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
        if let m = u.month.pct { return (m, "De tu plan este mes", true) }
        if let w = u.week.pct { return (w, "De tu plan esta semana", false) }
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
