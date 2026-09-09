import SwiftUI

/// Conectar un agente. La credencial se guarda en el llavero de este teléfono y
/// **nunca viaja en el binario** — salvo la del demo, que se hornea aparte.
struct SettingsView: View {
    /// Si viene un agente, se está editando; si no, se conecta uno nuevo.
    var editando: AgentAccount?
    var onGuardado: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var nombre: String
    @State private var agente: String
    @State private var token: String
    @State private var probando = false
    @State private var resultado: Resultado?

    init(editando: AgentAccount? = nil, onGuardado: @escaping () -> Void) {
        self.editando = editando
        self.onGuardado = onGuardado
        _nombre = State(initialValue: editando?.name ?? "")
        _agente = State(initialValue: editando?.id ?? "")
        _token  = State(initialValue: editando?.token ?? "")
    }

    private enum Resultado: Equatable { case bien(String), mal(String) }

    /// Qué build trae este teléfono. Sin esto no hay forma de saberlo sin cable, y
    /// ya me llevó a diagnosticar mal una vez.
    static var version: String {
        let b = Bundle.main
        let v = b.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let n = b.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let commit = b.infoDictionary?["GhostyCommit"] as? String ?? ""
        let sufijo = (commit.isEmpty || commit.hasPrefix("$(")) ? "" : " · \(commit)"
        return "Ghosty \(v) (build \(n))\(sufijo)"
    }

    private var esDeAgente: Bool { token.hasPrefix("agt_") }
    private var esDeCuenta: Bool { token.hasPrefix("eb_sk_") }
    private var listo: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty
        && !agente.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    TintedIcon(systemName: "xmark", tint: .gInk, background: .gSeparator, size: 34)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(editando == nil ? "Conectar agente" : "Editar agente").gScreenTitle()
                        Text("Se guarda en el llavero de este teléfono. No sale de aquí.")
                            .gMeta().fixedSize(horizontal: false, vertical: true)
                    }

                    campo("Nombre", "Cómo quieres verlo en la lista", $nombre, mono: false)
                    campo("Token", "El del agente empieza con agt_ · el de cuenta con eb_sk_", $token, mono: true)

                    if esDeCuenta {
                        aviso("exclamationmark.triangle",
                              "Es la llave de tu cuenta: alcanza todos tus agentes y puede borrarlos. En un teléfono ajeno usa el agt_ del agente.",
                              .gDanger, .gDangerTint)
                    } else if esDeAgente {
                        aviso("checkmark.shield",
                              "Token de un solo agente. No puede listar ni borrar nada.",
                              .gGreenInk, .gGreenTint)
                    }

                    campo("Id del agente", "Lo da EasyBits al crearlo", $agente, mono: true)

                    if let resultado {
                        switch resultado {
                        case .bien(let d): aviso("checkmark.circle", d, .gGreenInk, .gGreenTint)
                        case .mal(let d):  aviso("xmark.circle", d, .gDangerInk, .gDangerTint)
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").font(.system(size: 12))
                        Text(Self.version)
                    }
                    .gCaption()

                    VStack(spacing: 9) {
                        ActionButton(title: probando ? "Probando…" : "Probar y guardar", kind: .primary) {
                            Task { await probarYGuardar() }
                        }
                        .disabled(probando || !listo)
                        .opacity(probando || !listo ? 0.55 : 1)

                        if let editando {
                            ActionButton(title: "Quitar este agente", kind: .destructive) {
                                Credentials.quitar(editando.id)
                                onGuardado(); dismiss()
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
        }
        .background(Color.gBg)
    }

    // MARK: - Piezas

    private func campo(_ titulo: String, _ ayuda: String, _ texto: Binding<String>, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(titulo).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gInk)
            TextField("", text: texto)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: mono ? .monospaced : .default))
                .textInputAutocapitalization(mono ? .never : .words)
                .autocorrectionDisabled(mono)
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
                .background(Color.gCard)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            Text(ayuda).gCaption().fixedSize(horizontal: false, vertical: true)
        }
    }

    private func aviso(_ icono: String, _ texto: String, _ tono: Color, _ fondo: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icono).font(.system(size: 14, weight: .semibold)).foregroundStyle(tono)
            Text(texto).font(.system(size: 13.5)).foregroundStyle(Color.gInk2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fondo)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Se prueba ANTES de guardar: una credencial mala guardada deja la app en un
    /// estado que desde fuera parece un fallo del servicio.
    private func probarYGuardar() async {
        probando = true; resultado = nil
        defer { probando = false }

        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = agente.trimmingCharacters(in: .whitespacesAndNewlines)
        // ⚠️ Antes esto mandaba un "ping" por HTTP, y ese ping **apendaba al hilo
        // por defecto del agente**: probar la credencial ensuciaba una conversación.
        // El `initialize` del WebSocket verifica lo mismo —que el token alcanza a esa
        // caja— sin escribir nada, y de paso comprueba el transporte que la app usa
        // de verdad.
        let cliente = ACPClient(agentID: id, token: t)
        do {
            let info = try await cliente.conectar()
            await cliente.cerrar()
            resultado = .bien("Conectado · \(info)")
        } catch {
            // La caja puede estar dormida: se la levanta y se reintenta una vez.
            do {
                try await EasyBitsClient(apiKey: t).revive(agentID: id)
                let info = try await cliente.conectar()
                await cliente.cerrar()
                resultado = .bien("Conectado · \(info)")
            } catch {
                resultado = .mal(error.localizedDescription)
                return
            }
        }

        let limpio = nombre.trimmingCharacters(in: .whitespacesAndNewlines)
        Credentials.upsert(AgentAccount(id: id, token: t,
                                        name: limpio.isEmpty ? "Mi agente" : limpio))
        resultado = .bien("Conectado.")
        onGuardado()
        dismiss()
    }
}
