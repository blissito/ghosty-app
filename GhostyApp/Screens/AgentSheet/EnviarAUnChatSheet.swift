import SwiftUI

/// «Enviar a un chat», como «Reenviar» de WhatsApp: buscador, «Nuevo chat con…» y los
/// chats recientes de TODOS los agentes (la misma fuente que Chats). Elegir uno lo abre con
/// el archivo ADJUNTO en su compositor (por id, sin re-subir) y sin mandarlo solo.
///
/// ⚠️ Antes «Usar en un chat» abría siempre una conversación NUEVA: para mandarle un archivo
/// a la conversación donde ya estabas trabajando no había camino.
struct EnviarAUnChatSheet: View {
    let store: LiveAgentStore
    @State private var busqueda = ""

    private var filas: [ChatsView.Fila] {
        let q = busqueda.trimmingCharacters(in: .whitespaces)
        return ChatsView.filas(store)
            .filter { q.isEmpty || $0.titulo.localizedCaseInsensitiveContains(q) || $0.agente.name.localizedCaseInsensitiveContains(q) }
            .sorted { $0.fecha > $1.fecha }
            .prefix(40)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Color.gInk3)
                TextField("Buscar un chat", text: $busqueda)
                    .font(.system(size: 15))
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("enviar-buscar")
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(Color.gFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

            GhostySheetRow(title: "Nuevo chat con…", subtitle: "Empieza una conversación con el archivo",
                           action: { store.nuevoChatConArchivos() }) {
                TintedIcon(systemName: "square.and.pencil", tint: .gPrimary, background: .gPrimaryTint, size: 36)
            } extra: { EmptyView() }
            .accessibilityIdentifier("enviar-nuevo-chat")

            if !filas.isEmpty {
                Text(busqueda.isEmpty ? "Chats recientes" : "Resultados").gSectionCaps().padding(.top, 6)
            }
            ForEach(filas) { f in
                GhostySheetRow(title: f.titulo,
                               subtitle: "\(f.agente.name) · \(ChatsView.hora(f.fecha))",
                               action: { elegir(f) }) {
                    AgentAvatar(tone: f.agente.tone, size: 36)
                } extra: { EmptyView() }
                .accessibilityIdentifier("enviar-chat-\(f.id)")
            }
            if filas.isEmpty && !busqueda.isEmpty {
                Text("No hay chats que coincidan.").gMeta().padding(.vertical, 12)
            }
        }
    }

    /// Lo abre como si lo tocaras en Chats; el compositor recoge el archivo al aparecer.
    private func elegir(_ f: ChatsView.Fila) {
        switch f.tipo {
        case .abierta(let h): store.mirar(h, de: f.agente.id)
        case .guardada(let s): store.abrirDesdeChats(agente: f.agente.id, sesion: s)
        }
        store.archivosListosEnElChat()
    }
}
