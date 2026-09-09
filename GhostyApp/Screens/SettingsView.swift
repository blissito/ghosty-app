import SwiftUI

/// Ajustes: aquí se pega la credencial. Existe para que la llave **no viaje en el
/// binario** — cada teléfono guarda la suya en su llavero y alcanza sólo a su agente.
struct SettingsView: View {
    var onGuardado: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var token = Credentials.apiKey ?? ""
    @State private var agente = Credentials.agentID ?? ""
    @State private var probando = false
    @State private var resultado: Resultado?

    private enum Resultado: Equatable {
        case bien(String)
        case mal(String)
    }

    private var esDeAgente: Bool { token.hasPrefix("agt_") }
    private var esDeCuenta: Bool { token.hasPrefix("eb_sk_") }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader { dismiss() }
                .padding(.horizontal, 18)
                .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Conexión").gScreenTitle()
                        Text("La credencial se guarda en el llavero de este teléfono. No sale de aquí.")
                            .gMeta().fixedSize(horizontal: false, vertical: true)
                    }

                    campo(titulo: "Token",
                          ayuda: "El del agente empieza con agt_ · el de cuenta con eb_sk_",
                          texto: $token,
                          monoespaciado: true)

                    if esDeCuenta {
                        aviso(icono: "exclamationmark.triangle",
                              texto: "Es la llave de tu cuenta: alcanza todos tus agentes y puede borrarlos. En un teléfono ajeno usa el agt_ del agente.",
                              tono: .gDanger, fondo: .gDangerTint)
                    } else if esDeAgente {
                        aviso(icono: "checkmark.shield",
                              texto: "Token de un solo agente. No puede listar ni borrar nada.",
                              tono: .gGreenInk, fondo: .gGreenTint)
                    }

                    campo(titulo: "Id del agente",
                          ayuda: esDeAgente
                            ? "Obligatorio: con un token de agente no se puede listar."
                            : "Opcional: si lo dejas vacío se elige el primero que esté encendido.",
                          texto: $agente,
                          monoespaciado: true)

                    if let resultado {
                        switch resultado {
                        case .bien(let d):
                            aviso(icono: "checkmark.circle", texto: d, tono: .gGreenInk, fondo: .gGreenTint)
                        case .mal(let d):
                            aviso(icono: "xmark.circle", texto: d, tono: .gDangerInk, fondo: .gDangerTint)
                        }
                    }

                    VStack(spacing: 9) {
                        ActionButton(title: probando ? "Probando…" : "Probar y guardar", kind: .primary) {
                            Task { await probarYGuardar() }
                        }
                        .disabled(probando || token.isEmpty)
                        .opacity(probando || token.isEmpty ? 0.55 : 1)

                        if Credentials.apiKey != nil {
                            ActionButton(title: "Olvidar credencial") {
                                Keychain.borrar(.token); Keychain.borrar(.agente)
                                token = ""; agente = ""; resultado = nil
                                onGuardado()
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
        }
        .background(Color.gBg)
    }

    // MARK: - Piezas

    private func campo(titulo: String, ayuda: String, texto: Binding<String>, monoespaciado: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(titulo).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.gInk)
            TextField("", text: texto)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: monoespaciado ? .monospaced : .default))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
                .background(Color.gCard)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            Text(ayuda).gCaption().fixedSize(horizontal: false, vertical: true)
        }
    }

    private func aviso(icono: String, texto: String, tono: Color, fondo: Color) -> some View {
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

        let cliente = EasyBitsClient(apiKey: token.trimmingCharacters(in: .whitespacesAndNewlines))
        if esDeAgente {
            guard !agente.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                resultado = .mal("Con un token de agente hace falta su id.")
                return
            }
            // Un token de agente no puede listar: se prueba con un turno mínimo.
            do {
                var contesto = false
                for try await evento in cliente.message(agentID: agente, content: "ping") {
                    if case .chunk = evento { contesto = true }
                    if case .done = evento { break }
                    if case .error(let d) = evento { resultado = .mal(d); return }
                }
                resultado = contesto ? .bien("El agente contestó.") : .mal("El turno cerró sin respuesta.")
            } catch {
                resultado = .mal(error.localizedDescription)
                return
            }
        } else {
            do {
                let lista = try await cliente.agents()
                let vivos = lista.filter { $0.status == "running" }
                resultado = .bien("\(lista.count) agentes · \(vivos.count) encendidos.")
            } catch {
                resultado = .mal(error.localizedDescription)
                return
            }
        }

        if case .bien = resultado {
            Credentials.guardar(token: token, agente: agente)
            onGuardado()
        }
    }
}
