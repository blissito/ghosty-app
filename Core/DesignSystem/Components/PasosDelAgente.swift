import SwiftUI

/// Lo que el agente corrió, paso a paso.
///
/// ⚠️ Antes esto era una línea: *"Corrió 4 herramientas"* con un chevron **decorativo** que
/// no desplegaba nada. Prometía detalle y no lo daba, y durante un turno largo la pantalla
/// no decía si buscaba, leía o estaba atascada.
///
/// El patrón es el de Muse, mirado en sus capturas: **se nombra la herramienta y se enseña
/// lo que produjo**, en vez de contar cuántas corrieron.
struct PasosDelAgente: View {
    let run: ToolRun
    /// ¿El turno sigue vivo? Con las herramientas ya terminadas pero el turno en marcha,
    /// la línea seguía enseñando el icono de la última — y un icono quieto se lee como
    /// «terminó», justo cuando el modelo está pensando la siguiente.
    var vivo: Bool = false
    /// Enseñar «Pensando el siguiente paso…»: sólo con el turno vivo, sin herramienta
    /// corriendo, sin texto todavía y sin otra pieza (la caja de imagen) que ya lo diga.
    var pensando: Bool
    /// `abierto` se conserva por compatibilidad con quien llama; el detalle vive en el
    /// drawer. Sin `pensando` explícito, vale «vivo y nada corre».
    init(run: ToolRun, abierto: Bool = false, vivo: Bool = false, pensando: Bool? = nil) {
        self.run = run
        self.vivo = vivo
        self.pensando = pensando ?? (vivo && run.corriendo == nil)
    }

    @State private var drawer = false

    /// Cuántos pasos se ven (en vivo y al terminar, los MISMOS: al cerrar el turno no
    /// cambia el alto). Un turno largo corre treinta herramientas: se enseñan los últimos
    /// y el resto vive en el drawer.
    private static let visibles = 4

    private var mostrados: [Herramienta] { Array(run.herramientas.suffix(Self.visibles)) }
    private var ocultos: Int { max(0, run.count - Self.visibles) }

    /// En vivo, cada herramienta es un renglón suelto bajo tu mensaje (como claude.ai); al
    /// terminar el turno la MISMA vista se vuelve la tarjeta del diseño (blanca, borde
    /// fino, r16): sólo aparece el fondo y el borde, con el mismo padding, así que nada
    /// brinca. Palomita verde si terminó, el giro morado si corre, rojo si falló. Los
    /// rótulos son los REALES de cada herramienta; el plan de pasos pendientes el servidor
    /// no lo manda y no se inventa.
    ///
    /// Tocarla abre el drawer con la línea de tiempo completa y lo que devolvió cada paso.
    var body: some View {
        Button { drawer = true } label: {
            VStack(alignment: .leading, spacing: 7) {
                if ocultos > 0 {
                    Text(ocultos == 1 ? "1 paso antes" : "\(ocultos) pasos antes")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.gInk4)
                }
                ForEach(mostrados) { h in
                    FilaDePaso(h: h)
                        .transition(.gIn)
                }
                // Entre una herramienta y la siguiente el modelo PIENSA: sin esta fila la
                // lista parecía terminada justo cuando más se tarda.
                if pensando {
                    HStack(spacing: 9) {
                        GhostySpinner()
                        Text("Pensando el siguiente paso…")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Color.gInk3)
                    .transition(.gIn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.threadCard, style: .continuous)
                    .fill(Color.gCard)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.threadCard, style: .continuous)
                            .strokeBorder(Color.gSeparator, lineWidth: 1)
                    }
                    .opacity(vivo ? 0 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.threadCard, style: .continuous))
            .animation(.easeOut(duration: 0.3), value: run.herramientas.map(\.id))
            .animation(.easeOut(duration: 0.3), value: pensando)
            .animation(.easeOut(duration: 0.35), value: vivo)
        }
        .buttonStyle(.gPressRow)
        .accessibilityIdentifier("pasos-del-agente")
        .accessibilityHint("Abre el detalle de los pasos")
        .sheet(isPresented: $drawer) {
            DrawerDePasos(run: run)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.gBg)
        }
    }
}

/// Un renglón de la tarjeta: `400 13px #5E5D6B`, icono de 16 a la izquierda.
private struct FilaDePaso: View {
    let h: Herramienta

    var body: some View {
        HStack(spacing: 9) {
            estado
            // Qué CLASE de paso es (leer, buscar, terminal, imagen…): se distingue antes de leer.
            Image(systemName: h.esImagen ? Herramienta.Clase.imagen.icono : h.clase.icono)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.gInk3)
                .frame(width: 14)
            Text(h.rotulo)
                .font(.system(size: 13))
                .foregroundStyle(h.estado == .fallida ? Color.gDangerInk : Color(hex: 0x5E5D6B))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var estado: some View {
        switch h.estado {
        case .corriendo:
            GhostySpinner()
        case .hecha:
            Circle().fill(Color.gGreenTint)
                .frame(width: 16, height: 16)
                .overlay { ChatIcons.check.dibujo(Color.gGreen, size: 9, ancho: 2) }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .fallida:
            Circle().fill(Color.gDangerTint)
                .frame(width: 16, height: 16)
                .overlay {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.gDanger)
                }
        }
    }
}

/// El drawer: la línea de tiempo de lo que corrió, con hilo vertical entre pasos.
private struct DrawerDePasos: View {
    let run: ToolRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Pasos").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.gInk)
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.gInk2)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cerrar-pasos")
                    Spacer()
                }
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(run.herramientas.enumerated()), id: \.element.id) { i, h in
                        PasoFila(h: h, ultimo: i == run.herramientas.count - 1)
                    }
                }
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.vertical, 10)
            }
        }
    }
}

/// Una herramienta: qué es, cómo va y qué devolvió.
private struct PasoFila: View {
    let h: Herramienta
    var ultimo = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                icono
                if !ultimo {
                    Rectangle().fill(Color.gSeparator).frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(h.rotulo)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(h.estado == .fallida ? Color.gDangerInk : Color.gInk)
                    .lineLimit(2)
                if let d = h.donde {
                    Text(d).gMono(size: 11.5).foregroundStyle(Color.gInk3).lineLimit(1)
                }
                if let s = h.salida, !s.isEmpty { asomo(s) }
            }
            .padding(.bottom, ultimo ? 0 : 18)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icono: some View {
        if h.esperando {
            ProgressView().controlSize(.mini).frame(width: 22, height: 22)
        } else {
            Image(systemName: h.estado == .fallida ? "exclamationmark" : h.clase.icono)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(h.estado == .fallida ? Color.gDangerInk : h.clase.tinte.fg)
                .frame(width: 22, height: 22)
                .background(h.estado == .fallida ? Color.gDangerTint : h.clase.tinte.bg,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                // Nativo: el icono da un brinco al terminar. Es el mismo `.bounce` que ya
                // usa el bote de la grabación.
                .symbolEffect(.bounce, value: h.estado)
        }
    }

    /// Las primeras líneas de lo que devolvió.
    ///
    /// ⚠️ Recortado y monoespaciado: la salida de un `shell` puede ser un volcado entero, y
    /// meterlo completo en el hilo es lo mismo que echarlo al contexto — ruido que tapa la
    /// respuesta.
    private func asomo(_ s: String) -> some View {
        Text(s.split(separator: "\n", omittingEmptySubsequences: false).prefix(3)
            .joined(separator: "\n"))
            .gMono(size: 11)
            .foregroundStyle(Color.gInk2)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
