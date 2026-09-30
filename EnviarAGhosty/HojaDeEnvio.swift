import SwiftUI

/// La hoja «Enviar a Ghosty»: qué se manda, a quién, y qué hacer con ello.
struct HojaDeEnvio: View {
    @Bindable var modelo: ModeloDeEnvio
    @FocusState private var escribiendo: Bool

    var body: some View {
        VStack(spacing: 0) {
            cabecera
            Divider().overlay(Color.gSeparator)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    contenido
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color.gBg.ignoresSafeArea())
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: modelo.estado)
    }

    // MARK: - Cabecera

    private var cabecera: some View {
        HStack(spacing: 12) {
            AgentAvatar(tone: .lila, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Enviar a Ghosty").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.gInk)
                if modelo.estado == .listo, modelo.agentes.count > 0 { selectorDeAgente }
            }
            Spacer()
            Button { modelo.cerrar() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.gInk2)
                    .frame(width: 30, height: 30)
                    .background(Color.gFill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// El agente al que va. Tocarlo abre la lista de los demás.
    private var selectorDeAgente: some View {
        Menu {
            ForEach(modelo.agentes) { a in
                Button {
                    modelo.agenteID = a.id
                } label: {
                    if a.id == modelo.agenteID { Label(a.rotulo, systemImage: "checkmark") }
                    else { Text(a.rotulo) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(modelo.agente?.name ?? "Elige un agente")
                if modelo.agentes.count > 1 {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.gPrimary)
        }
        .disabled(modelo.agentes.count < 2)
    }

    // MARK: - Contenido por estado

    @ViewBuilder
    private var contenido: some View {
        switch modelo.estado {
        case .cargando:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
        case .sinSesion:
            aviso("person.crop.circle.badge.exclamationmark", "Abre Ghosty para iniciar sesión",
                  "La hoja de compartir usa la misma cuenta que la app.",
                  boton: "Abrir Ghosty") { modelo.abrirLaApp() }
        case .sinConsentimiento:
            aviso("hand.raised", "Falta tu permiso de IA",
                  "Abre Ghosty y acepta que tu agente use IA de terceros; luego vuelve a compartir.",
                  boton: "Abrir Ghosty") { modelo.abrirLaApp() }
        case .sinAgentes:
            aviso("person.2.slash", "No tienes agentes todavía",
                  "Crea uno en ghosty.studio o ábrelo desde la app.",
                  boton: "Abrir Ghosty") { modelo.abrirLaApp() }
        case .listo:
            formulario
        case .enviando(let paso):
            miniaturas.disabled(true)
            HStack(spacing: 10) {
                ProgressView()
                Text(paso).gMeta()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        case .enviado:
            enviado
        case .fallo(let m):
            aviso("exclamationmark.triangle", "No se pudo mandar", m,
                  boton: "Reintentar") { modelo.estado = .listo }
        }
    }

    private var formulario: some View {
        VStack(alignment: .leading, spacing: 16) {
            miniaturas
            ForEach(modelo.avisos, id: \.self) { a in
                Label(a, systemImage: "exclamationmark.circle").gCaption().foregroundStyle(Color.gDangerInk)
            }
            TextField("¿Qué hago con esto?", text: $modelo.instruccion, axis: .vertical)
                .lineLimit(2...6)
                .focused($escribiendo)
                .font(.system(size: 16))
                .padding(14)
                .background(Color.gCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.gSeparator))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ModeloDeEnvio.atajos, id: \.self) { t in
                        Button { modelo.instruccion = t } label: {
                            Text(t)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(modelo.instruccion == t ? .white : Color.gPrimary)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(modelo.instruccion == t ? Color.gPrimary : Color.gPrimaryTint,
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(spacing: 10) {
                ActionButton(title: "Enviar", kind: .primary) {
                    escribiendo = false
                    modelo.enviar()
                }
                .disabled(!modelo.hayAlgo && modelo.instruccion.isEmpty)
                ActionButton(title: "Abrir en Ghosty", kind: .secondary) { modelo.abrirSinMandar() }
            }
            .padding(.top, 4)
        }
    }

    private var enviado: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.gGreen)
            Text("Listo, \(modelo.agente?.name ?? "tu agente") ya está en ello")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.gInk)
                .multilineTextAlignment(.center)
            Text("La respuesta te espera en una conversación nueva.").gMeta().multilineTextAlignment(.center)
            ForEach(modelo.avisos, id: \.self) { a in
                Label(a, systemImage: "exclamationmark.circle").gCaption().foregroundStyle(Color.gDangerInk)
            }
            ActionButton(title: "Abrir en Ghosty", kind: .primary) { modelo.abrirConversacion() }
            ActionButton(title: "Listo", kind: .secondary) { modelo.cerrar() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    // MARK: - Piezas

    @ViewBuilder
    private var miniaturas: some View {
        if modelo.hayAlgo {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(modelo.piezas) { p in miniatura(p) }
                    ForEach(modelo.compartidoComoTexto, id: \.self) { t in tarjetaDeTexto(t) }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func miniatura(_ p: ModeloDeEnvio.Pieza) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = p.miniatura {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: p.adjunto.icono).font(.system(size: 22)).foregroundStyle(Color.gPrimary)
                        Text(p.adjunto.nombre).gCaption().lineLimit(2).multilineTextAlignment(.center)
                        Text(p.adjunto.peso).gCaption().foregroundStyle(Color.gInk3)
                    }
                    .padding(8)
                }
            }
            .frame(width: 84, height: 96)
            .background(Color.gCard)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.gSeparator))

            if modelo.estado == .listo {
                Button { withAnimation { modelo.quitar(p) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel("Quitar \(p.adjunto.nombre)")
            }
        }
    }

    private func tarjetaDeTexto(_ t: String) -> some View {
        let esEnlace = t.hasPrefix("http://") || t.hasPrefix("https://")
        return VStack(alignment: .leading, spacing: 6) {
            Image(systemName: esEnlace ? "link" : "text.alignleft")
                .font(.system(size: 16)).foregroundStyle(Color.gPrimary)
            Text(t).gCaption().lineLimit(4)
        }
        .padding(10)
        .frame(width: 150, height: 96, alignment: .topLeading)
        .background(Color.gCard)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.gSeparator))
    }

    private func aviso(_ icono: String, _ titulo: String, _ detalle: String,
                       boton: String, accion: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icono).font(.system(size: 36)).foregroundStyle(Color.gPrimary)
            Text(titulo).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.gInk)
                .multilineTextAlignment(.center)
            Text(detalle).gMeta().multilineTextAlignment(.center)
            ActionButton(title: boton, kind: .primary, action: accion).padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}
