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
    /// Se conserva por compatibilidad con quien llama; la línea es siempre una y el
    /// detalle vive en el drawer.
    init(run: ToolRun, abierto: Bool = false, vivo: Bool = false) {
        self.run = run
        self.vivo = vivo
    }

    @State private var drawer = false

    /// UNA línea, como Claude: el paso que corre ahora (o el último), con su icono y un
    /// chevron. Tocarla abre el drawer con la línea de tiempo completa. La lista de
    /// tarjetas en el hilo ocupaba media pantalla en un turno largo y empujaba la
    /// respuesta fuera de la vista.
    var body: some View {
        Button { drawer = true } label: {
            HStack(spacing: 8) {
                if let viva = run.corriendo {
                    ProgressView().controlSize(.mini)
                    Text(viva.rotulo).lineLimit(1)
                } else if run.fallidas > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.gDangerInk)
                    Text("\(run.count) pasos · \(run.fallidas) con problemas").lineLimit(1)
                } else if vivo, let ultima = run.herramientas.last {
                    ProgressView().controlSize(.mini)
                    Text(run.count == 1 ? ultima.rotulo : "\(ultima.rotulo) · \(run.count) pasos")
                        .lineLimit(1)
                } else if let ultima = run.herramientas.last {
                    Image(systemName: ultima.clase.icono)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gInk3)
                    Text(run.count == 1 ? ultima.rotulo : "\(ultima.rotulo) · \(run.count) pasos")
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.gInk4)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.gInk3)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pasos-del-agente")
        .sheet(isPresented: $drawer) {
            DrawerDePasos(run: run)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.gBg)
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
