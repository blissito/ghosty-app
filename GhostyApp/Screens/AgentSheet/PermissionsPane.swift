import SwiftUI

struct PermissionsPane: View {
    let store: LiveAgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let peticion = store.pendingPermission {
                SectionHeader(title: "Necesita tu visto bueno").padding(.bottom, 12)
                tarjeta(peticion).padding(.bottom, 24)
            } else {
                EmptyState(icon: "checkmark.shield",
                           title: "Nada pendiente",
                           detail: "Aquí aparece lo que el agente no puede deshacer: enviar, comprar, publicar.")
                    .padding(.top, 40)
                    .padding(.bottom, 30)
            }

            if !store.permissionHistory.isEmpty {
                Text("Historial").gSectionTitle().padding(.bottom, 4)
                VStack(spacing: 0) {
                    ForEach(Array(store.permissionHistory.enumerated()), id: \.element.id) { i, r in
                        HStack(alignment: .top, spacing: 12) {
                            TintedIcon(systemName: r.icon.systemName)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.title).font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.gInk)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(r.detail).gMeta().fixedSize(horizontal: false, vertical: true)
                                Text(r.outcome).gCaption()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, Theme.Space.row)
                        .ghostySeparator(inset: i == store.permissionHistory.count - 1 ? .infinity : 44)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.screenH)
    }

    private func tarjeta(_ p: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                TintedIcon(systemName: icono(p.kind), tint: .gDanger, background: .gDangerTint, size: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(p.question).gCardTitle().fixedSize(horizontal: false, vertical: true)
                    Text(p.detail).gMeta().lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let adjunto = p.attachment {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.gInk2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(adjunto.filename).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.gInk).lineLimit(1)
                        Text(adjunto.meta).gCaption()
                    }
                    Spacer(minLength: 0)
                    Text("Ver").font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 46)
                .background(Color.gBg)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

            // Tres respuestas, no dos: sin "para esta tarea" la gente aprueba todo
            // con tal de avanzar, y eso es la ceguera de banner.
            VStack(spacing: 8) {
                ActionButton(title: "Permitir esta vez", kind: .primary) {
                    Task { await store.decide(p, .allowOnce) }
                }
                ActionButton(title: "Permitir para esta tarea") {
                    Task { await store.decide(p, .allowForTask) }
                }
                ActionButton(title: "Rechazar") {
                    Task { await store.decide(p, .deny) }
                }
            }
        }
        .padding(16)
        .ghostyCard()
    }

    private func icono(_ k: PermissionRequest.Kind) -> String {
        switch k {
        case .email:    return "envelope"
        case .purchase: return "cart"
        case .push:     return "arrow.trianglehead.branch"
        case .publish:  return "globe"
        }
    }
}
