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

    private var otros: [(canal: Canal, hilo: Hilo)] {
        let mirando = store.hiloActivo?.clave
        return store.enCurso.filter { $0.hilo.clave != mirando }
    }

    var body: some View {
        if !otros.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(otros, id: \.hilo.clave) { par in
                        chip(par.canal, par.hilo)
                    }
                }
                .padding(.horizontal, Theme.Space.cardH)
            }
            .padding(.bottom, Theme.Space.row - 3)
        }
    }

    private func chip(_ canal: Canal, _ hilo: Hilo) -> some View {
        let esperaPermiso = hilo.permisoPendiente != nil
        // El nombre del agente sólo si NO es el que miras: dentro del mismo agente lo
        // que distingue una conversación de otra es de qué va, no de quién es.
        let mismoAgente = canal.cuenta.id == store.selectedAgentID
        let etiqueta = mismoAgente ? hilo.titulo : canal.cuenta.name

        return Button {
            store.mirar(hilo, de: canal.cuenta.id)
        } label: {
            HStack(spacing: 7) {
                if esperaPermiso {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gDanger)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(etiqueta)
                    .gChip()
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                // El reloj en cifras de ancho fijo: si no, el chip se ensancha cada
                // segundo y la fila entera tiembla.
                Text(esperaPermiso ? "espera permiso" : hilo.transcurrido)
                    .gMono(size: 12.5, weight: .regular)
                    .foregroundStyle(esperaPermiso ? Color.gDangerInk : Color.gInk3)
            }
            .frame(maxWidth: 210)
            .padding(.horizontal, Theme.Space.cardH - 4)
            .padding(.vertical, 7)
            // ⚠️ El que espera permiso va en rojo, no en el primario: es lo mismo que
            // dice `StatusLine` para este estado, y su turno está DETENIDO — no es una
            // notita, es lo único de la pantalla que te está esperando a ti.
            .background(esperaPermiso ? Color.gDangerTint : Color.gCard, in: Capsule())
            // La misma elevación que el resto de superficies blancas sobre el fondo.
            .shadow(color: .black.opacity(0.055), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 7, y: 4)
        }
        .buttonStyle(.plain)
    }
}
