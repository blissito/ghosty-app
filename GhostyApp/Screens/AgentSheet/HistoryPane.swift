import SwiftUI

/// Los hilos que viven **en la caja**, no en este teléfono.
///
/// Llegan por WebSocket (`session/list`), así que sobreviven a reinstalar la app y los
/// comparten todos los clientes del agente. Tocar uno hace `session/load` y la caja
/// reproduce la conversación completa — con su markdown y las herramientas que corrió.
struct HistoryPane: View {
    let store: LiveAgentStore
    var onAbrir: (() -> Void)?

    @State private var abriendo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch store.estadoHilos {
            case .sinPedir, .cargando:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Preguntándole a la caja…").gMeta()
                }
                .frame(maxWidth: .infinity).padding(.top, 60)

            case .fallo(let d):
                VStack(spacing: 14) {
                    EmptyState(icon: "bolt.horizontal.circle",
                               title: "No pude leer los hilos",
                               detail: d)
                    Button("Reintentar") { Task { await store.cargarHilos() } }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                }
                .padding(.top, 50)

            case .listo:
                if store.hilosRemotos.isEmpty {
                    EmptyState(icon: "clock.arrow.circlepath",
                               title: "Sin hilos",
                               detail: "Las conversaciones que tengas con este agente quedan guardadas en su caja.")
                        .padding(.top, 60)
                } else {
                    lista
                }
            }
        }
        .padding(.horizontal, Theme.Space.screenH)
        .task { if store.estadoHilos == .sinPedir { await store.cargarHilos() } }
    }

    private var lista: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("En la caja").gSectionTitle()
                Spacer()
                if let info = store.infoDeLaCaja {
                    Text(info).gCaption()
                }
            }
            .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(Array(store.hilosRemotos.enumerated()), id: \.element.id) { i, h in
                    Button {
                        abriendo = h.id
                        Task {
                            await store.abrirHilo(h)
                            abriendo = nil
                            onAbrir?()
                        }
                    } label: {
                        fila(h)
                    }
                    .buttonStyle(.plain)
                    .disabled(abriendo != nil)
                    .ghostySeparator(inset: i == store.hilosRemotos.count - 1 ? .infinity : 44)
                }
            }

            Text("Estos hilos viven en la caja del agente, no en el teléfono: los ves iguales desde cualquier cliente.")
                .gCaption()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .padding(.horizontal, 4)
        }
    }

    private func fila(_ h: ACPClient.Session) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if abriendo == h.id {
                ProgressView().frame(width: 32, height: 32)
            } else {
                TintedIcon(systemName: h.id == store.hiloAbierto ? "checkmark" : "bubble.left.and.bubble.right",
                           tint: h.id == store.hiloAbierto ? .gPrimary : .gInk2,
                           background: h.id == store.hiloAbierto ? .gPrimaryTint : .gFill)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(nombre(h)).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gInk).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detalle(h)).gMeta()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.gInk4)
                .padding(.top, 4)
        }
        .padding(.vertical, Theme.Space.row)
        .contentShape(Rectangle())
    }

    /// ⚠️ La caja **no nombra los hilos**: `session/list` devuelve "New Chat" para
    /// todos con `userSetName: false`, y `session/set_title` no existe en el
    /// protocolo. El título sale del primer mensaje que se mandó desde aquí; para los
    /// hilos que nacieron en otro cliente, la fecha es lo único honesto que hay.
    private func nombre(_ h: ACPClient.Session) -> String {
        if let t = store.titulos.titulo(h.id) { return t }
        if h.title != "New Chat", !h.title.isEmpty, h.title != "Sin título" { return h.title }
        if let f = h.updatedAt {
            return "Conversación del " + f.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        return "Conversación \(h.id)"
    }

    private func detalle(_ h: ACPClient.Session) -> String {
        var partes: [String] = []
        if let n = h.messageCount { partes.append(n == 1 ? "1 mensaje" : "\(n) mensajes") }
        if let f = h.updatedAt {
            partes.append(f.formatted(.relative(presentation: .named)))
        }
        return partes.joined(separator: " · ")
    }
}
