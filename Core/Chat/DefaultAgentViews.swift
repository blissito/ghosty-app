import SwiftUI

/// La pastilla «Principal» junto al nombre del agente principal, en cualquier lista de agentes.
struct DefaultAgentBadge: View {
    var body: some View {
        Text("Principal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.gPrimary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.gPrimaryTint, in: Capsule())
            .accessibilityIdentifier("agente-principal-insignia")
    }
}

/// La advertencia antes de cambiar de agente principal. Es propia, no la alerta del sistema:
/// tiene que decir qué cambia (lo nuevo, el resumen) y qué NO (los hilos de ahora).
struct MakeDefaultAgentConfirm: View {
    let agent: Agent
    let current: Agent?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AgentAvatar(tone: agent.tone, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("¿\(agent.name) como tu agente principal?")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color.gInk)
                    if let current, current.id != agent.id {
                        Text("Hoy es \(current.name).").gMeta().foregroundStyle(Color.gInk3)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                punto("sun.horizon", "Escribe tu resumen de la mañana, si no elegiste otro para eso.")
                punto("square.and.pencil", "Abre lo nuevo que llega sin agente, como lo que mandas con «Enviar a Ghosty».")
                punto("cpu", "Trabaja con su modelo (\(agent.model ?? agent.engine)) y sus integraciones.")
                punto("bubble.left.and.bubble.right", "Tus conversaciones de ahora no cambian: cada una sigue con su agente.")
            }
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("Cancelar")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gInk2)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color.gFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("principal-cancelar")
                Button(action: onConfirm) {
                    Text("Hacer principal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color.gPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("principal-confirmar")
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("principal-advertencia")
    }

    private func punto(_ icono: String, _ texto: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icono)
                .font(.system(size: 15))
                .foregroundStyle(Color.gPrimary)
                .frame(width: 22)
            Text(texto).gBody().foregroundStyle(Color.gInk2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// «Agente principal» de Perfil: tus agentes con el principal marcado. Elegir otro pasa
/// por la advertencia; «Automático» deja que gs lo decida (el último que usaste).
struct DefaultAgentPickerSheet: View {
    let store: LiveAgentStore
    @State private var defaults = DefaultAgentStore.shared
    @State private var pending: Agent?
    @Environment(\.dismiss) private var dismiss

    /// Sólo los tuyos: uno compartido o de un espacio no puede ser tu principal.
    private var agentes: [Agent] {
        store.agents.filter { $0.compartidoPor == nil && $0.space?.kind != .workspace && $0.space?.kind != .shared }
    }

    var body: some View {
        Group {
            if let pending {
                MakeDefaultAgentConfirm(
                    agent: pending,
                    current: agentes.first { defaults.isDefault($0.id) },
                    onConfirm: {
                        Task { await defaults.set(pending.id) }
                        dismiss()
                    },
                    onCancel: { withAnimation(.snappy) { self.pending = nil } })
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                lista.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.gBg)
        .task { await defaults.load(force: true) }
    }

    private var lista: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agente principal")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.gInk)
                .padding(.horizontal, 20).padding(.top, 22)
            Text("El que usa Ghosty cuando no eliges otro.")
                .gMeta().foregroundStyle(Color.gInk3)
                .padding(.horizontal, 20).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(agentes, id: \.id) { a in
                        let es = defaults.isDefault(a.id)
                        Button {
                            if !es { withAnimation(.snappy) { pending = a } }
                        } label: {
                            HStack(spacing: 12) {
                                AgentAvatar(tone: a.tone, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(a.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.gInk)
                                        if es { DefaultAgentBadge() }
                                    }
                                    Text(a.model ?? a.engine).font(.system(size: 13)).foregroundStyle(Color.gInk3)
                                }
                                Spacer(minLength: 0)
                                if es { Image(systemName: "checkmark").foregroundStyle(Color.gPrimary) }
                            }
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("principal-\(a.id)")
                    }
                    if defaults.saved != nil {
                        Button("Que lo decida Ghosty (el último que usaste)") {
                            Task { await defaults.set(nil) }
                            dismiss()
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                        .padding(.top, 14)
                        .accessibilityIdentifier("principal-automatico")
                    }
                    if let e = defaults.error {
                        Text(e).gCaption().foregroundStyle(Color.gDangerInk).padding(.top, 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
