import SwiftUI

/// Memorias: lo que tu agente recuerda de ti en todos tus chats (gs `api/v2/me/memories`).
/// Ocupa el lugar de la pestaña de Integraciones, que se fue a Perfil.
///
/// ⚠️ Son de la CUENTA. Una con agente sólo la usa ése («Sólo Nube»); sin agente, todos.
/// Nunca se usan con los clientes de WhatsApp o Messenger: eso lo garantiza gs y aquí se dice.
struct MemoriasView: View {
    let store: LiveAgentStore

    @State private var memorias: [MemoriaDelAgente] = []
    @State private var cargando = true
    @State private var fallo: String?
    /// La que se edita (o una nueva, con id vacío) en la hoja.
    @State private var editando: MemoriaDelAgente?
    @State private var porBorrar: MemoriaDelAgente?

    private static let explicacion = "Lo que tu agente recuerda de ti en todos tus chats. Dile «recuerda que…» o agrégalo aquí. Nunca se usa con tus clientes de WhatsApp o Messenger."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Memorias").gScreenTitle()
                    Spacer()
                    Button { editando = MemoriaDelAgente(id: "", texto: "") } label: {
                        TintedIcon(systemName: "plus", tint: .gPrimary, background: .gPrimaryTint, size: 36)
                    }
                    .buttonStyle(.gPressIcon)
                    .accessibilityLabel("Agregar memoria")
                    .accessibilityIdentifier("memoria-agregar")
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 4)

                if !memorias.isEmpty {
                    Text(Self.explicacion)
                        .gScreenSubtitle()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                        .padding(.bottom, 18)
                }

                if let fallo {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
                        Text(fallo).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { self.fallo = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Color.gDangerInk)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gDangerTint,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .padding(.bottom, 14)
                    .transition(.gIn)
                }

                if memorias.isEmpty && cargando && !DemoData.encendido {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if memorias.isEmpty {
                    VStack(spacing: 16) {
                        EmptyState(icon: "lightbulb", title: "Aún no recuerdo nada de ti", detail: Self.explicacion)
                        Button { editando = MemoriaDelAgente(id: "", texto: "") } label: {
                            Text("Agregar una memoria")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.gPrimary)
                                .padding(.horizontal, 18).frame(height: 40)
                                .background(Color.gPrimaryTint, in: Capsule())
                        }
                        .buttonStyle(.gPressPill)
                    }
                    .padding(.top, 50)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(memorias.enumerated()), id: \.element.id) { i, m in
                            fila(m)
                                .ghostySeparator(inset: i == memorias.count - 1 ? .infinity : 0)
                                .gIn(delay: min(Double(i), 8) * 0.03)
                        }
                    }
                    .ghostyCard(radius: Theme.Radius.list)
                }
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: memorias)
        }
        .scrollIndicators(.hidden)
        .task { await cargar() }
        .refreshable { await cargar() }
        .sheet(item: $editando) { m in
            EditorDeMemoria(memoria: m, agentes: store.agents) { texto, agente in
                await guardar(m, texto: texto, agente: agente)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmarBorrado("¿Olvidar esta memoria?", consecuencia: "Tu agente dejará de tenerla en cuenta en todos tus chats.",
                          preguntando: Binding(get: { porBorrar != nil }, set: { if !$0 { porBorrar = nil } })) {
            if let m = porBorrar { Task { await olvidar(m) } }
        }
    }

    /// Tocar edita; el bote borra (con confirmación).
    private func fila(_ m: MemoriaDelAgente) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { editando = m } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.texto)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.gInk)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detalle(m))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.gInk3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("memoria-\(m.id)")
            Button { porBorrar = m } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.gInk3)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.gPressIcon)
            .accessibilityLabel("Olvidar")
            .accessibilityIdentifier("memoria-borrar-\(m.id)")
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 10)
    }

    /// «Guardada por tu agente · Sólo Nube», «Tú».
    private func detalle(_ m: MemoriaDelAgente) -> String {
        var partes = [m.delAgente ? "Guardada por tu agente" : "Tú"]
        if let a = m.agenteID {
            partes.append("Sólo \(store.agents.first { $0.id == a }?.name ?? "un agente")")
        }
        return partes.joined(separator: " · ")
    }

    private func cargar() async {
        if DemoData.encendido {
            if memorias.isEmpty { memorias = DemoData.memorias }
            cargando = false
            return
        }
        cargando = true
        do { memorias = try await MemoriasAPI.listar(); fallo = nil }
        catch { fallo = error.localizedDescription }
        cargando = false
    }

    /// Devuelve el fallo para enseñarlo en la hoja (y no cerrarla), o `nil` si se guardó.
    private func guardar(_ m: MemoriaDelAgente, texto: String, agente: String?) async -> String? {
        if DemoData.encendido {
            var nueva = m
            nueva.texto = texto
            if m.id.isEmpty {
                nueva = MemoriaDelAgente(id: UUID().uuidString, texto: texto, agenteID: agente, creada: Date())
                memorias.insert(nueva, at: 0)
            } else if let i = memorias.firstIndex(where: { $0.id == m.id }) { memorias[i] = nueva }
            return nil
        }
        do {
            if m.id.isEmpty {
                memorias.insert(try await MemoriasAPI.crear(texto, agente: agente), at: 0)
            } else {
                let editada = try await MemoriasAPI.editar(m.id, texto: texto)
                if let i = memorias.firstIndex(where: { $0.id == m.id }) { memorias[i] = editada }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Optimista: se va de la lista ya y vuelve si gs no pudo.
    private func olvidar(_ m: MemoriaDelAgente) async {
        guard let i = memorias.firstIndex(where: { $0.id == m.id }) else { return }
        memorias.remove(at: i)
        porBorrar = nil
        if DemoData.encendido { return }
        do { try await MemoriasAPI.olvidar(m.id) }
        catch {
            memorias.insert(m, at: min(i, memorias.count))
            fallo = error.localizedDescription
        }
    }
}

/// La hoja de agregar/editar: el texto y, al crear, para qué agente es.
private struct EditorDeMemoria: View {
    let memoria: MemoriaDelAgente
    let agentes: [Agent]
    let alGuardar: (String, String?) async -> String?

    @Environment(\.dismiss) private var cerrar
    @State private var texto = ""
    @State private var agente: String?
    @State private var guardando = false
    @State private var fallo: String?
    @FocusState private var enfocado: Bool

    private var nueva: Bool { memoria.id.isEmpty }
    private var limpio: String { texto.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Cancelar") { cerrar() }
                    .foregroundStyle(Color.gInk2)
                Spacer()
                Text(nueva ? "Nueva memoria" : "Editar memoria").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    guardando = true
                    Task {
                        fallo = await alGuardar(limpio, agente)
                        guardando = false
                        if fallo == nil { cerrar() }
                    }
                } label: {
                    if guardando { GhostySpinner(size: 14) } else { Text("Guardar").fontWeight(.semibold) }
                }
                .foregroundStyle(Color.gPrimary)
                .disabled(limpio.isEmpty || limpio.count > 500 || guardando)
                .accessibilityIdentifier("memoria-guardar")
            }

            TextEditor(text: $texto)
                .focused($enfocado)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 120)
                .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if texto.isEmpty {
                        Text("Ej. Mi negocio es una imprenta en Puebla.")
                            .font(.system(size: 16)).foregroundStyle(Color.gInk4)
                            .padding(.horizontal, 15).padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("memoria-texto")

            HStack {
                // Al crear se elige; después ya es de quien es (gs sólo edita el texto).
                if nueva, agentes.count > 1 {
                    Menu {
                        Button("Todos tus agentes") { agente = nil }
                        ForEach(agentes) { a in Button("Sólo \(a.name)") { agente = a.id } }
                    } label: {
                        HStack(spacing: 4) {
                            Text(agente.flatMap { id in agentes.first { $0.id == id }.map { "Sólo \($0.name)" } } ?? "Todos tus agentes")
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.gInk2)
                    }
                }
                Spacer()
                Text("\(limpio.count)/500")
                    .font(.system(size: 12))
                    .foregroundStyle(limpio.count > 500 ? Color.gDangerInk : Color.gInk3)
            }

            if let fallo {
                Text(fallo).gCaption().foregroundStyle(Color.gDangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.screenH)
        .background(Color.gBg.ignoresSafeArea())
        .onAppear {
            texto = memoria.texto
            agente = memoria.agenteID
            enfocado = true
        }
    }
}
