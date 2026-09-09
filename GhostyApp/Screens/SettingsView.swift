import SwiftUI

/// Tu cuenta: quién eres, qué agentes tienes y cómo salir.
///
/// ⚠️ Aquí ya NO se pega ningún token. La credencial sale del login contra
/// ghosty.studio y el servidor dice qué agentes hay; teclear un id de agente en un
/// teléfono era justo lo que hacía que la app no sirviera para nadie más que nosotros.
struct SettingsView: View {
    var store: LiveAgentStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var abrir

    @State private var saliendo = false
    @State private var conectores = false

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

    /// Lo que se abre en el navegador. La sesión la resuelve la web con su propio
    /// handshake, así que la app no tiene que llevar ninguna credencial ahí.
    private let sitios: [(String, String, URL)] = [
        ("Teams", "Conversaciones, documentos y llamadas",
         URL(string: "https://teams.ghosty.studio")!),
        ("Tasks", "Tableros y pendientes",
         URL(string: "https://tasks.ghosty.studio")!),
        ("Sales", "Tu embudo y tus conversaciones de venta",
         URL(string: "https://sales.ghosty.studio")!),
    ]

    var body: some View {
        contenido
            .sheet(isPresented: $conectores) {
                ConectoresView(store: store)
                    #if os(iOS)
                    .presentationDetents([.large])
                    .presentationCornerRadius(Theme.Radius.sheet)
                    #endif
            }
    }

    private var contenido: some View {
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
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tu cuenta").gScreenTitle()
                        if let correo = store.correo {
                            Text(correo).gMeta()
                        }
                    }

                    if !store.agents.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tus agentes").gSectionTitle()
                            // El ÚNICO sitio donde se nombra la máquina, y se nombra en
                            // posesivo y como promesa. El molde es el de Meta con Muse
                            // ("your own dedicated computer in the cloud" · "Your computer,
                            // your data"): primero lo que es tuyo, y lo técnico sólo si
                            // hace falta. En una pantalla vacía sería plomería; aquí es la
                            // respuesta a "¿dónde queda lo que le mando?".
                            //
                            // Es verdad y se sostiene: la máquina de un agente es SUYA
                            // (dominio fijo por agente) y lo que se le manda vive en su
                            // disco, no en un montón compartido.
                            Text("Ghosty vive en su propia computadora en la nube. Lo que le das se queda ahí.")
                                .gMeta()
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 2)
                            ForEach(store.agents) { a in
                                HStack(spacing: 10) {
                                    Text(a.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Color.gInk)
                                    Text(a.engine).gMeta()
                                    Spacer()
                                    if a.id == store.selectedAgentID {
                                        Text("activo").gMeta()
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("En la web").gSectionTitle()
                        ForEach(sitios, id: \.0) { nombre, detalle, url in
                            Button { abrir(url) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(nombre)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(Color.gInk)
                                        Text(detalle).gMeta()
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.gInk3)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                    }

                    // ⚠️ Sólo si el servidor lo soporta. Enseñar "Integraciones" y que abra
                    // una lista vacía sería prometer lo que no hay — la regla que ya nos
                    // costó las pestañas de Ideas y Metas.
                    if store.hayConectores {
                        Button { conectores = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Integraciones")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Color.gInk)
                                    Text(store.conectores.filter(\.conectado).isEmpty
                                         ? "Conecta las apps que ya usas"
                                         : "\(store.conectores.filter(\.conectado).count) conectadas")
                                        .gMeta()
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.gInk3)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if let a = store.almacenamiento {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Almacenamiento").gSectionTitle()
                            // ⚠️ El tope lo dice el SERVIDOR, no se calcula aquí: un número
                            // metido en un binario tarda días en poder corregirse, y este
                            // tier todavía está sin diseñar.
                            ProgressView(value: a.fraccion)
                                .tint(a.fraccion > 0.9 ? Color.gDanger : Color.gPrimary)
                            Text(a.texto).gMeta()
                        }
                    }

                    Text(Self.version).gMeta()

                    ActionButton(title: saliendo ? "Saliendo…" : "Cerrar sesión", kind: .destructive) {
                        saliendo = true
                        Task {
                            // Cierra ANTES de despedir la hoja: si se hace al revés, la
                            // vista se va y la tarea se queda a medias.
                            await store.cerrarSesion()
                            dismiss()
                        }
                    }
                    .disabled(saliendo)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .background(Color.gBg.ignoresSafeArea())
    }
}
