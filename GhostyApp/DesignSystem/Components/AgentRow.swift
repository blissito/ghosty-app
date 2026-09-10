import SwiftUI

/// Punto de color + texto: el estado va DEBAJO del nombre, que es lo que hace que
/// una lista de agentes se lea de un vistazo.
///
/// ⚠️ Este archivo tenía además un `AgentRow` que **no usaba nadie** desde hacía tiempo:
/// sólo se le citaba en un comentario. Se borró. Lo que sí se usa —en el chat, en la hoja
/// y en la lista de conversaciones— es esto.
struct StatusLine: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .working(let tarea):
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.gPrimary)
                Text(tarea).gMeta().foregroundStyle(Color.gPrimary)
                    .lineLimit(1).truncationMode(.tail)
            case .awaitingApproval:
                Circle().fill(Color.gDanger).frame(width: 7, height: 7)
                Text("Espera tu visto bueno").gMeta()
            case .idle(let desde):
                Text("En reposo · \(desde)").gMeta().foregroundStyle(Color.gInk4)
            }
        }
    }
}
