import SwiftUI

/// Lo que el agente hace ahora y lo que hizo hoy — con sus tokens y su duración.
///
/// ⚠️ Registra **lo que pasó por este teléfono**. La caja `ghosty-lite` no expone el
/// API de administración (su passthrough contesta 502 en `/admin/…/activity`), así
/// que un turno lanzado desde otro cliente no aparece. Se dice en pantalla en vez de
/// dejar creer que es todo.
struct ActivityPane: View {
    let store: LiveAgentStore

    /// ⚠️ **Sólo lo que NO terminó bien.** Este panel listaba todos los turnos del día, y
    /// el prompt de un turno es el mismo texto que titula su conversación: era la lista de
    /// conversaciones otra vez, y encima sin poder tocarla para ir a ninguna. Lo que aquí
    /// no se puede ver en otro sitio es lo que costó y lo que se rompió.
    private var problemas: [TurnRecord] {
        store.bitacora.deHoy(agentID: store.selectedAgentID).filter { $0.outcome != .done }
    }
    private var resumen: (turnos: Int, tokens: Int, segundos: Int) {
        store.bitacora.resumen(agentID: store.selectedAgentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let turno = store.currentTurn {
                SectionHeader(title: "En curso").padding(.bottom, 12)
                enCurso(turno).padding(.bottom, 24)
            }

            if resumen.turnos > 0 {
                Text("Hoy").gSectionTitle().padding(.bottom, 12)
                resumenDeHoy.padding(.bottom, 8)
                // ⚠️ Sin esta línea el número parece un fallo de medición. No lo es: cada
                // turno le manda al modelo la conversación ENTERA otra vez, así que la
                // entrada crece con la conversación y es lo que domina el total. Es
                // también lo que se paga, así que sumarlo es correcto — lo que faltaba era
                // decir de qué está hecho.
                Text("La entrada incluye releer la conversación completa en cada turno, "
                     + "que es lo que de verdad se cobra. Por eso sube rápido.")
                    .gCaption()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 18)
                    .padding(.horizontal, 4)
            }

            if resumen.turnos == 0 && store.currentTurn == nil {
                EmptyState(icon: "waveform.path.ecg",
                           title: "Sin actividad todavía",
                           detail: "Cuando le escribas, aquí queda lo que tardó y lo que costó.")
                    .padding(.top, 50)
            } else {
                if !problemas.isEmpty {
                    Text("No salieron").gSectionTitle().padding(.bottom, 12)
                    VStack(spacing: 0) {
                        ForEach(Array(problemas.enumerated()), id: \.element.id) { i, r in
                            fila(r).ghostySeparator(inset: i == problemas.count - 1 ? .infinity : 44)
                        }
                    }
                }

                Text("Sólo los turnos que pasaron por este teléfono. Lo que el agente haga desde otro cliente no se ve aquí. Las conversaciones están en su pestaña.")
                    .gCaption()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, Theme.Space.screenH)
    }

    // MARK: - Piezas

    private func enCurso(_ turno: TurnActivity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                TintedIcon(systemName: "waveform", tint: .gPrimary, background: .gPrimaryTint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(turno.title).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gInk).lineLimit(2)
                    Text(turno.detail).gMeta()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { Task { await store.stopTurn() } } label: {
                    RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
                        .fill(Color.gInk)
                        .frame(width: 32, height: 32)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 9, height: 9)
                        }
                }
                .buttonStyle(.plain)
            }
            TurnProgress(turn: turno)
        }
        .padding(15)
        .ghostyCard()
    }

    private var resumenDeHoy: some View {
        HStack(spacing: 0) {
            dato("\(resumen.turnos)", resumen.turnos == 1 ? "turno" : "turnos")
            divisor
            dato(formatearTokens(resumen.tokens), "tokens")
            divisor
            dato(formatearTiempo(resumen.segundos), "trabajando")
        }
        .padding(.vertical, 14)
        .ghostyCard()
    }

    private var divisor: some View {
        Rectangle().fill(Color.gSeparator).frame(width: 1, height: 30)
    }

    private func dato(_ valor: String, _ etiqueta: String) -> some View {
        VStack(spacing: 3) {
            Text(valor).font(.system(size: 19, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.gInk)
            Text(etiqueta).gCaption()
        }
        .frame(maxWidth: .infinity)
    }

    private func fila(_ r: TurnRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            TintedIcon(systemName: icono(r.outcome),
                       tint: tono(r.outcome).0, background: tono(r.outcome).1)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.prompt).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gInk).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detalle(r)).gMeta()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(r.startedAt.formatted(date: .omitted, time: .shortened))
                .gMono(size: 12.5, weight: .regular).foregroundStyle(Color.gInk4)
        }
        .padding(.vertical, Theme.Space.row)
    }

    private func detalle(_ r: TurnRecord) -> String {
        switch r.outcome {
        case .stopped: return "Lo detuviste a los \(r.elapsedText)"
        case .failed:  return "Se cortó a los \(r.elapsedText)"
        case .done:
            let t = r.totalTokens > 0 ? " · \(formatearTokens(r.totalTokens)) tokens" : ""
            return "\(r.elapsedText)\(t)"
        }
    }

    private func icono(_ o: TurnRecord.Outcome) -> String {
        switch o {
        case .done: return "checkmark"
        case .stopped: return "stop.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func tono(_ o: TurnRecord.Outcome) -> (Color, Color) {
        switch o {
        case .done: return (.gGreenInk, .gGreenTint)
        case .stopped: return (.gInk2, .gFill)
        case .failed: return (.gDangerInk, .gDangerTint)
        }
    }

    /// ⚠️ Llegaba hasta `k` y nada más, así que un día normal se leía **«1424.5k»**: un
    /// número que hay que dividir a mano para entenderlo, y que por eso parece un error de
    /// medición cuando no lo es.
    private func formatearTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func formatearTiempo(_ s: Int) -> String {
        s >= 60 ? "\(s/60)m \(s%60)s" : "\(s)s"
    }
}
