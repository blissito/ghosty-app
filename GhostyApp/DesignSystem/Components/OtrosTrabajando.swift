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
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)
        }
    }

    private func chip(_ canal: Canal) -> some View {
        let esperaPermiso = canal.permisoPendiente != nil
        return Button { alTocar(canal.cuenta.id) } label: {
            HStack(spacing: 7) {
                if esperaPermiso {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(canal.cuenta.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.gInk)
                Text(esperaPermiso ? "espera permiso" : canal.transcurrido)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.gInk3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(esperaPermiso ? Color.gPrimaryTint : Color.gCard, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
