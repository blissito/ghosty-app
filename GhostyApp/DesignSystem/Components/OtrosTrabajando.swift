import SwiftUI

/// Los OTROS agentes que siguen trabajando mientras miras esta conversación.
///
/// ⚠️ Existe porque el trabajo en paralelo, sin esto, es invisible: dejas a un agente
/// con una tarea larga, te vas con otro, y no hay ni un pixel que diga que el primero
/// sigue vivo — así que parece cancelado aunque no lo esté. Un chip por agente, con lo
/// que hace y cuánto lleva, y tocarlo te devuelve a su hilo.
///
/// No lista al agente ACTIVO: su turno ya se ve en el hilo, y repetirlo aquí sería
/// decir dos veces lo mismo en la misma pantalla.
struct OtrosTrabajando: View {
    let store: LiveAgentStore
    var alTocar: (String) -> Void

    private var otros: [Canal] {
        store.agents.compactMap { store.canales[$0.id] }
            .filter { $0.cuenta.id != store.selectedAgentID }
            .filter { $0.trabajando || $0.permisoPendiente != nil }
    }

    var body: some View {
        if !otros.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(otros, id: \.cuenta.id) { canal in
                        chip(canal)
                    }
                }
                .padding(.horizontal, Theme.Space.cardH)
            }
            .padding(.bottom, Theme.Space.row - 3)
        }
    }

    private func chip(_ canal: Canal) -> some View {
        let esperaPermiso = canal.permisoPendiente != nil
        return Button { alTocar(canal.cuenta.id) } label: {
            HStack(spacing: 7) {
                if esperaPermiso {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gDanger)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(canal.cuenta.name)
                    .gChip()
                    .foregroundStyle(Color.gInk)
                // El reloj en cifras de ancho fijo: si no, el chip se ensancha cada
                // segundo y la fila entera tiembla.
                Text(esperaPermiso ? "espera permiso" : canal.transcurrido)
                    .gMono(size: 12.5, weight: .regular)
                    .foregroundStyle(esperaPermiso ? Color.gDangerInk : Color.gInk3)
            }
            .padding(.horizontal, Theme.Space.cardH - 4)
            .padding(.vertical, 7)
            // ⚠️ El que espera permiso va en rojo, no en el primario: es lo mismo que
            // dice `StatusLine` para este estado, y su turno está DETENIDO — no es una
            // notita, es lo único de la pantalla que te está esperando a ti.
            .background(esperaPermiso ? Color.gDangerTint : Color.gCard, in: Capsule())
            // La misma elevación que el resto de superficies blancas sobre el fondo. Sin
            // ella el chip se lee pegado, y es la única tarjeta plana de la app.
            .shadow(color: .black.opacity(0.055), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 7, y: 4)
        }
        .buttonStyle(.plain)
    }
}
