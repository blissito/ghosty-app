import SwiftUI

/// El agente se detuvo para preguntar antes de algo que no se deshace (enviar, publicar,
/// comprar). Va encima del compositor: es lo único que lo destraba, y en una pestaña de la
/// hoja nadie lo encontraba.
struct PermissionCard: View {
    let request: PermissionRequest
    let onDecide: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                TintedIcon(systemName: icon, tint: .gPrimary, background: .gPrimaryTint, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.question).gCardTitle().fixedSize(horizontal: false, vertical: true)
                    Text(request.detail).gMeta().fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                ActionButton(title: "Sí, dale", kind: .primary) { onDecide(.allowOnce) }
                    .accessibilityIdentifier("permiso-si")
                ActionButton(title: "No, mejor no") { onDecide(.deny) }
                    .accessibilityIdentifier("permiso-no")
            }
            // El de en medio evita aprobar todo a ciegas: sólo vale en esta conversación.
            Button { onDecide(.allowForTask) } label: {
                Text("Sí, y ya no me preguntes en esta plática")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.gPrimary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("permiso-siempre")
        }
        .padding(14)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var icon: String {
        switch request.kind {
        case .email:    return "envelope"
        case .purchase: return "cart"
        case .push:     return "arrow.trianglehead.branch"
        case .publish:  return "globe"
        }
    }
}
