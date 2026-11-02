import SwiftUI

/// El agente se detuvo para preguntar antes de algo que no se deshace (enviar, cobrar,
/// publicar, borrar). Va encima del compositor: es lo único que lo destraba, y en una pestaña
/// de la hoja nadie lo encontraba.
///
/// Con el borrador de gs (`preview`) enseña lo que va a salir, al estilo Claude Duet:
/// encabezado con el tipo, campos (Para, Asunto…), el cuerpo recortado con «Ver todo» y
/// «Ahora no» / el verbo de la acción. Sin él, la pregunta de siempre.
struct PermissionCard: View {
    let request: PermissionRequest
    let onDecide: (PermissionDecision) -> Void

    /// Renglones del cuerpo antes de «Ver todo».
    private let bodyLines = 8
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pv = request.preview {
                draft(pv)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    TintedIcon(systemName: icon, tint: .gPrimary, background: .gPrimaryTint, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(request.question).gCardTitle().fixedSize(horizontal: false, vertical: true)
                        Text(request.detail).gMeta().fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                ActionButton(title: request.preview == nil ? "No, mejor no" : "Ahora no") { onDecide(.deny) }
                    .accessibilityIdentifier("permission-no")
                ActionButton(title: request.preview?.verb ?? "Sí, dale", kind: .primary) { onDecide(.allowOnce) }
                    .accessibilityIdentifier("permission-yes")
            }
            // Evita aprobar todo a ciegas: sólo vale en esta conversación. gs no lo ofrece en
            // pagos ni borrados.
            if request.allowsAlways {
                Button { onDecide(.allowForTask) } label: {
                    Text("Sí, y ya no me preguntes en esta plática")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("permission-always")
            }
        }
        .padding(14)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 16).padding(.bottom, 8)
        // Otra tarjeta en el mismo lugar empieza recortada.
        .onChange(of: request.id) { _, _ in showAll = false }
    }

    @ViewBuilder
    private func draft(_ pv: ApprovalPreview) -> some View {
        HStack(spacing: 10) {
            TintedIcon(systemName: icon(pv.kind), tint: .gPrimary, background: .gPrimaryTint, size: 30)
            Text(pv.label).gCardTitle().lineLimit(1)
            Spacer(minLength: 0)
        }
        if !pv.fields.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pv.fields, id: \.self) { f in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(f.label).gMeta().frame(width: 76, alignment: .leading)
                        Text(f.value).gBody()
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        if let text = pv.body {
            VStack(alignment: .leading, spacing: 6) {
                Divider().overlay(Color.gHairline)
                // Más de 8 renglones o muy largo: recortado con «Ver todo».
                // Abierto, se desplaza dentro de la tarjeta para no empujar el compositor fuera.
                if showAll {
                    ScrollView {
                        Text(text).gBody()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 320)
                } else {
                    Text(text).gBody()
                        .lineLimit(bodyLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isLong(text) {
                    Button(showAll ? "Ver menos" : "Ver todo") {
                        withAnimation(.easeOut(duration: 0.2)) { showAll.toggle() }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.gPrimary)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("permission-show-all")
                }
            }
        }
    }

    /// ¿Pasa de ~8 renglones? Cuenta saltos y estima los renglones de los párrafos largos.
    private func isLong(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 42))) }
        return lines > bodyLines
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "email":    return "envelope"
        case "message":  return "bubble.left"
        case "payment":  return "creditcard"
        case "purchase": return "shippingbox"
        case "publish":  return "globe"
        case "delete":   return "trash"
        case "schedule": return "clock"
        case "calendar": return "calendar"
        case "database": return "cylinder"
        default:         return "checkmark.shield"
        }
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
