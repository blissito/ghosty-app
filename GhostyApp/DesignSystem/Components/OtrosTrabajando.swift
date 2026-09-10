import SwiftUI

/// Las OTRAS conversaciones que siguen vivas mientras miras ésta.
///
/// ⚠️ Era una fila de AGENTES, y ése era el error de fondo de toda la función: el
/// paralelismo se pensó por agente cuando la unidad real es la **conversación**. Un chip
/// por hilo —del agente que sea— es lo que hace que dejar dos cosas corriendo con el
/// mismo Ghosty se vea, y tocar uno te lleva a esa conversación sin cancelar nada.
///
/// No lista la conversación que ya estás mirando: su turno se ve en el hilo, y repetirlo
/// aquí sería decir dos veces lo mismo en la misma pantalla.
struct OtrosTrabajando: View {
    let store: LiveAgentStore

    /// ⚠️ TODAS las conversaciones abiertas, no sólo las que trabajan. Con la fila
    /// puesta arriba y sólo con las vivas, para cambiarte a una que ya contestó había que
    /// estirar el dedo hasta la cabeza del agente y abrir un panel. Ahora vive **junto al
    /// compositor**, que es donde está el pulgar.
    private var abiertas: [(canal: Canal, hilo: Hilo)] {
        var lista: [(Canal, Hilo)] = []
        if let c = store.canalActivo { lista += c.hilos.map { (c, $0) } }
        // De los otros agentes sólo lo que está vivo: sus conversaciones dormidas son de
        // otra pantalla.
        lista += store.enCurso.filter { $0.canal.cuenta.id != store.selectedAgentID }
            .map { ($0.canal, $0.hilo) }
        return lista
    }

    var body: some View {
        // ⚠️ La fila se enseña SIEMPRE que haya algo que enseñar, aunque sólo haya una
        // conversación: es la barra de conversaciones, y aquí es donde vive el «+». Con
        // el «+» escondido en el compositor había dos entradas para lo mismo y ninguna
        // decía que las conversaciones son una lista.
        if !abiertas.isEmpty {
            HStack(spacing: 7) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(abiertas, id: \.hilo.clave) { par in
                            chip(par.canal, par.hilo)
                        }
                    }
                    .padding(.leading, Theme.Space.cardH)
                    .padding(.vertical, 4)
                }
                // ⚠️ FUERA del scroll y clavado a la derecha. Puesto al final de la fila
                // se iba de la pantalla en cuanto había tres conversaciones, que es justo
                // cuando más falta hace empezar otra.
                nueva
                    .padding(.trailing, Theme.Space.cardH)
            }
            .padding(.bottom, 4)
        }
    }

    /// Empezar otra. Va al FINAL de la fila, que es donde acaba la lista de lo que hay.
    private var nueva: some View {
        Button {
            store.nuevaConversacion()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.gPrimary)
                .frame(width: 32, height: 32)
                .background(Color.gPrimaryTint, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nueva-conversacion")
    }

    private func fondo(_ permiso: Bool, _ contesto: Bool, _ activa: Bool) -> Color {
        if permiso { return .gDangerTint }
        if contesto { return .gGreenTint }
        return .gCard
    }

    private func chip(_ canal: Canal, _ hilo: Hilo) -> some View {
        let esperaPermiso = hilo.permisoPendiente != nil
        let activa = hilo.clave == store.hiloActivo?.clave
        let contesto = hilo.termino != nil && !hilo.visto && !hilo.trabajando
        // El nombre del agente sólo si NO es el que miras: dentro del mismo agente lo
        // que distingue una conversación de otra es de qué va, no de quién es.
        let mismoAgente = canal.cuenta.id == store.selectedAgentID
        let etiqueta = mismoAgente ? hilo.titulo : canal.cuenta.name

        return Button {
            store.mirar(hilo, de: canal.cuenta.id)
        } label: {
            HStack(spacing: 6) {
                if esperaPermiso {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gDanger)
                } else if hilo.trabajando {
                    ProgressView().controlSize(.mini)
                } else if contesto {
                    // Ya contestó y no lo has visto: es a donde hay que volver.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.gGreenInk)
                }
                Text(etiqueta)
                    .gChip()
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                // El reloj en cifras de ancho fijo: si no, el chip se ensancha cada
                // segundo y la fila entera tiembla.
                if esperaPermiso {
                    Text("permiso").gChip().foregroundStyle(Color.gDangerInk)
                } else if hilo.trabajando {
                    Text(hilo.transcurrido).gMono(size: 12.5, weight: .regular)
                        .foregroundStyle(Color.gInk3)
                }
            }
            .frame(maxWidth: 190)
            .padding(.horizontal, Theme.Space.cardH - 4)
            .padding(.vertical, 7)
            // ⚠️ El que espera permiso va en rojo, no en el primario: es lo mismo que
            // dice `StatusLine` para este estado, y su turno está DETENIDO — no es una
            // notita, es lo único de la pantalla que te está esperando a ti.
            .background(fondo(esperaPermiso, contesto, activa), in: Capsule())
            .overlay {
                // La que miras va perfilada, no rellena: rellena competía con el chip que
                // te está esperando, que es el que tiene que llamar la atención.
                if activa { Capsule().stroke(Color.gPrimary, lineWidth: 1.5) }
            }
            .shadow(color: .black.opacity(0.055), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 7, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chip-\(hilo.clave)")
    }
}
