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
                    Text("Preguntándole a tu agente…").gMeta()
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
                if store.hilosRemotos.isEmpty && (store.canalActivo?.hilos.count ?? 0) <= 1 {
                    EmptyState(icon: "clock.arrow.circlepath",
                               title: "Sin hilos",
                               detail: "Las conversaciones que tengas con este agente se guardan solas, y las puedes retomar.")
                        .padding(.top, 60)
                } else {
                    lista
                }
            }
        }
        .padding(.horizontal, Theme.Space.screenH)
        // ⚠️ Se pide SIEMPRE, no sólo `.sinPedir`: con la lista cacheada el estado nace
        // en `.listo` y esa condición no volvería a refrescar nunca. `cargarHilos` ya se
        // protege de pedirlo dos veces a la vez, y con caché no enseña spinner.
        .task { await store.cargarHilos() }
    }

    /// Las de la caja que NO están ya abiertas arriba.
    ///
    /// ⚠️ Sin esto la misma conversación salía dos veces —una en cada sección— y no había
    /// forma de saber que eran la misma.
    private var guardadas: [ACPClient.Session] {
        let abiertas = Set((store.canalActivo?.hilos ?? []).compactMap(\.sesionID))
        return store.hilosRemotos.filter { !abiertas.contains($0.id) }
    }

    /// Las conversaciones que tienes abiertas EN LA APP, con su estado vivo.
    ///
    /// ⚠️ Van arriba y separadas de las guardadas porque no son lo mismo: éstas están
    /// aquí, algunas contestando ahora, y tocarlas no cuesta un `session/load` — sólo
    /// cambia de conversación. Antes no existían: había una por agente.
    @ViewBuilder
    private var abiertas: some View {
        if let canal = store.canalActivo, canal.hilos.count > 1 || canal.trabajando {
            Text("Abiertas").gSectionTitle().padding(.bottom, 12)
            VStack(spacing: 0) {
                ForEach(Array(canal.hilos.enumerated()), id: \.element.clave) { i, h in
                    // ⚠️ `onTapGesture` y NO un `Button`, porque la fila lleva dentro el
                    // botón de cerrar: un `Button` dentro del `label` de otro `Button` se
                    // come el toque y la fila entera deja de responder. Es el mismo patrón
                    // que ya usa la Flota.
                    filaAbierta(h, activa: h.clave == canal.activa)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.mirar(h)
                            onAbrir?()
                        }
                        // Un solo elemento accesible: así se puede tocar por su nombre
                        // sin confundirlo con una burbuja del chat que diga lo mismo.
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("hilo-abierto-\(i)")
                        .ghostySeparator(inset: i == canal.hilos.count - 1 ? .infinity : 44)
                }
            }
            .padding(.bottom, 22)
        }
    }

    private func filaAbierta(_ h: Hilo, activa: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if h.trabajando {
                ProgressView().frame(width: 32, height: 32)
            } else if h.termino != nil, !h.visto {
                // Ya contestó y no lo has visto: es la razón por la que abriste esto.
                TintedIcon(systemName: "checkmark", tint: .gGreenInk, background: .gGreenTint)
            } else {
                TintedIcon(systemName: activa ? "checkmark" : "bubble.left.and.bubble.right",
                           tint: activa ? .gPrimary : .gInk2,
                           background: activa ? .gPrimaryTint : .gFill)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(h.titulo).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gInk).lineLimit(1)
                EstadoDelHilo(hilo: h)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Cerrar la conversación de la app. No la borra de la caja.
            if !h.trabajando, store.canalActivo?.hilos.count ?? 0 > 1 {
                Button { store.cerrarHilo(h) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.gInk4)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Theme.Space.row)
    }

    private var lista: some View {
        VStack(alignment: .leading, spacing: 0) {
            abiertas
            if !guardadas.isEmpty {
            HStack {
                Text("Guardadas").gSectionTitle()
                Spacer()
                if let info = store.infoDeLaCaja {
                    Text(info).gCaption()
                }
            }
            .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(Array(guardadas.enumerated()), id: \.element.id) { i, h in
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
                    .ghostySeparator(inset: i == guardadas.count - 1 ? .infinity : 44)
                }
            }
            }

            Text("Estas conversaciones no viven en el teléfono: las ves iguales desde cualquier dispositivo.")
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
        // Último recurso: un hilo que nació en otro cliente y que nunca se ha
        // abierto aquí. En cuanto se abra, su primer mensaje se vuelve el título.
        if let n = h.messageCount, n > 0 {
            return "Conversación sin abrir"
        }
        return "Conversación \(h.id)"
    }

    private func detalle(_ h: ACPClient.Session) -> String {
        var partes: [String] = []
        if let n = h.messageCount { partes.append(n == 1 ? "1 mensaje" : "\(n) mensajes") }
        // ⚠️ En español y a mano: `.relative` sigue el idioma del SISTEMA, así que en un
        // teléfono en inglés salía «22 minutes ago» en medio de una pantalla en español.
        if let f = h.updatedAt { partes.append(Hilo.hace(f)) }
        return partes.joined(separator: " · ")
    }
}
