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
    /// Mientras el turno vive se enseñan todos; al cerrar se colapsan.
    ///
    /// ⚠️ Colapsar NO es esconder: el historial ya leído se pliega y se puede volver a
    /// abrir. Ocultar el trabajo del agente ya fue un error dos veces —en code-mode ESO es
    /// el trabajo— y el resultado era un "Trabajando…" mudo casi todo el turno.
    @State private var abierto: Bool

    init(run: ToolRun, abierto: Bool) {
        self.run = run
        _abierto = State(initialValue: abierto)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if abierto {
                ForEach(run.herramientas) { h in
                    PasoFila(h: h)
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .opacity))
                }
            }
            resumen
        }
        .frame(maxWidth: 300, alignment: .leading)
        // Al terminar el turno se pliega solo. ⚠️ Un `@State` no se re-inicializa cuando
        // cambian las props, así que sin esto se quedaría abierto para siempre.
        .onChange(of: run.corriendo?.id) { _, ahora in
            if ahora == nil {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { abierto = false }
            }
        }
    }

    /// La línea que abre y cierra. Dice lo justo para no tener que abrirla.
    private var resumen: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { abierto.toggle() }
        } label: {
            HStack(spacing: 7) {
                if let viva = run.corriendo {
                    ProgressView().controlSize(.mini)
                    Text(viva.titulo)
                        .lineLimit(1)
                } else if run.fallidas > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.gDangerInk)
                    Text("\(run.count) pasos · \(run.fallidas) con problemas")
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.gGreenInk)
                    Text("\(run.count) paso\(run.count == 1 ? "" : "s")")
                        .contentTransition(.numericText())
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(abierto ? 180 : 0))
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.gInk3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Una herramienta: qué es, cómo va y qué devolvió.
private struct PasoFila: View {
    let h: Herramienta

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            icono
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(h.titulo)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(h.estado == .fallida ? Color.gDangerInk : Color.gInk)
                        .lineLimit(1)
                    if let d = h.donde {
                        Text(d).gMono(size: 11).foregroundStyle(Color.gInk3).lineLimit(1)
                    }
                }
                if let s = h.salida, !s.isEmpty { asomo(s) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.gCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
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
