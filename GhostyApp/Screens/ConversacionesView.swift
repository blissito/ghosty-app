import SwiftUI

/// Todas tus conversaciones, agrupadas por agente.
///
/// ⚠️ **Sustituye a la Flota**, no se suma a ella. La Flota era una lista de agentes a la
/// que se le fue metiendo qué hace cada uno, su cronómetro, detener y «pídele algo»: media
/// lista de conversaciones con otro nombre. Y las conversaciones se veían en tres sitios
/// —la barra sobre el compositor, «Abiertas» dentro de la hoja del agente, y de rebote en
/// la bitácora de Actividad—. Ésta es la lista de verdad; la barra de abajo se queda como
/// el cambio rápido, que es otra cosa.
struct ConversacionesView: View {
    let store: LiveAgentStore
    var onCuenta: () -> Void
    /// Tocar una conversación te lleva a ella: quien cambia de pestaña es `RootView`.
    var onAbrir: () -> Void

    @State private var borradores: [String: String] = [:]
    /// Qué agentes tienen desplegadas sus conversaciones guardadas.
    @State private var desplegados: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                cabecera
                ForEach(store.agents) { agente in
                    if let canal = store.canales[agente.id] {
                        grupo(agente, canal)
                    }
                }
                Text("Tus agentes salen de tu cuenta de Ghosty Studio. Para crear o configurar uno, entra desde la web.")
                    .gCaption()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 8)
        }
        // ⚠️ Entrar ES verlo: apagar el punto de la pestaña vivía SÓLO en la Flota, así que
        // al sustituirla había que traérselo o el punto no se apagaría nunca.
        .onAppear { store.vistoTodo() }
    }

    private var cabecera: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Conversaciones").gScreenTitle()
                Text(resumen).gMeta()
            }
            Spacer()
            Button(action: onCuenta) {
                TintedIcon(systemName: "person.crop.circle", tint: .gInk, background: .gCard, size: 36)
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cuenta")
        }
    }

    /// Cuántas hay y cuántas están ocupadas. Con trabajo en paralelo es lo que dice
    /// de un vistazo si hay algo corriendo sin tener que leer la lista entera.
    private var resumen: String {
        let abiertas = store.canales.values.reduce(0) { $0 + $1.hilos.count }
        let ocupadas = store.enCurso.count
        let base = abiertas == 1 ? "1 conversación" : "\(abiertas) conversaciones"
        guard ocupadas > 0 else { return base }
        return base + (ocupadas == 1 ? " · 1 trabajando" : " · \(ocupadas) trabajando")
    }

    // MARK: - Un agente y lo suyo

    private func grupo(_ agente: Agent, _ canal: Canal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cabeceraDeAgente(agente, canal)
                .padding(.vertical, Theme.Space.row)
                .ghostySeparator(inset: 0)

            ForEach(Array(canal.hilos.enumerated()), id: \.element.clave) { i, h in
                filaDeHilo(h, canal: canal, agente: agente)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("conversacion-\(agente.id)-\(i)")
                    .ghostySeparator(inset: 0)
            }

            pedir(agente, canal)
                .padding(.vertical, 10)

            guardadas(agente, canal)
        }
        .padding(.horizontal, Theme.Space.cardH)
        .ghostyCard()
    }

    private func cabeceraDeAgente(_ agente: Agent, _ canal: Canal) -> some View {
        HStack(spacing: 12) {
            GhostyMascot(tone: agente.tone, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(agente.name).gRowTitle()
                StatusLine(status: store.estado(de: agente.id)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if canal.enCurso.count > 1 {
                Text("\(canal.enCurso.count) en curso").gChip().foregroundStyle(Color.gInk3)
            }
            // Detener TODO lo de este agente. Es la única forma de pararlo sin entrar a
            // cada conversación.
            if canal.trabajando {
                Button { store.detenerTodo(canal) } label: {
                    RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
                        .fill(Color.gInk)
                        .frame(width: 32, height: 32)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2.5).fill(Color.white)
                                .frame(width: 8, height: 8)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("detener-\(agente.id)")
            }
            // ⚠️ Aquí NO va un «…». Estuvo, y abría Ajustes, donde la lista de agentes es
            // de sólo lectura: un botón que prometía editar algo que no se puede editar.
        }
        .contentShape(Rectangle())
        .onTapGesture { store.seleccionar(agente.id) }
    }

    private func filaDeHilo(_ h: Hilo, canal: Canal, agente: Agent) -> some View {
        let mirando = h.clave == store.hiloActivo?.clave && agente.id == store.selectedAgentID
        return HStack(alignment: .top, spacing: 11) {
            icono(h, mirando: mirando)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.titulo)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                EstadoDelHilo(hilo: h)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !h.trabajando, canal.hilos.count > 1 {
                Button { store.cerrarHilo(h) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gInk4)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            store.mirar(h, de: agente.id)
            onAbrir()
        }
    }

    private func icono(_ h: Hilo, mirando: Bool) -> some View {
        Group {
            if h.trabajando {
                ProgressView().frame(width: 28, height: 28)
            } else if h.permisoPendiente != nil {
                TintedIcon(systemName: "hand.raised.fill", tint: .gDangerInk,
                           background: .gDangerTint, size: 28)
            } else if h.termino != nil, !h.visto {
                TintedIcon(systemName: "checkmark", tint: .gGreenInk,
                           background: .gGreenTint, size: 28)
            } else if mirando {
                TintedIcon(systemName: "checkmark", tint: .gPrimary,
                           background: .gPrimaryTint, size: 28)
            } else {
                TintedIcon(systemName: "bubble.left.and.bubble.right", tint: .gInk3,
                           background: .gFill, size: 28)
            }
        }
    }

    /// Mandarle algo sin entrar. ⚠️ Sin adjuntos: adjuntar es del chat, y traerlo aquí
    /// duplicaría medio compositor dentro de una fila.
    @ViewBuilder
    private func pedir(_ agente: Agent, _ canal: Canal) -> some View {
        HStack(spacing: 8) {
            TextField("Pídele algo…", text: Binding(
                get: { borradores[agente.id] ?? "" },
                set: { borradores[agente.id] = $0 }))
                .gBody()
                .textFieldStyle(.plain)
                .accessibilityIdentifier("pedir-\(agente.id)")
                .submitLabel(.send)
                .onSubmit { mandar(a: agente.id) }

            if !(borradores[agente.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { mandar(a: agente.id) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Theme.primaryGradient, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.cardH - 4)
        .padding(.vertical, 8)
        .background(Color.gFill,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    /// Lo que vive en la caja y no tienes abierto.
    ///
    /// ⚠️ Plegado y PEREZOSO: pedir la lista cuesta despertar la caja, y hacerlo para
    /// todos los agentes al abrir esta pantalla sería despertarlas todas cada vez.
    @ViewBuilder
    private func guardadas(_ agente: Agent, _ canal: Canal) -> some View {
        let abiertas = Set(canal.hilos.compactMap(\.sesionID))
        let lista = canal.hilosRemotos.filter { !abiertas.contains($0.id) }
        let desplegado = desplegados.contains(agente.id)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                if desplegado { desplegados.remove(agente.id) }
                else {
                    desplegados.insert(agente.id)
                    if agente.id != store.selectedAgentID { store.seleccionar(agente.id) }
                    Task { await store.cargarHilos() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(desplegado ? 90 : 0))
                    Text(lista.isEmpty && !desplegado ? "Guardadas" : "Guardadas (\(lista.count))")
                        .gChip()
                    Spacer()
                }
                .foregroundStyle(Color.gInk3)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("guardadas-\(agente.id)")

            if desplegado {
                if case .cargando = canal.estadoHilos, lista.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Preguntándole a tu agente…").gMeta()
                    }
                    .padding(.bottom, 10)
                } else if lista.isEmpty {
                    Text("No hay más conversaciones guardadas.").gMeta().padding(.bottom, 10)
                } else {
                    ForEach(lista) { s in
                        Button {
                            Task {
                                if agente.id != store.selectedAgentID { store.seleccionar(agente.id) }
                                await store.abrirHilo(s)
                                onAbrir()
                            }
                        } label: {
                            HStack(spacing: 11) {
                                TintedIcon(systemName: "clock.arrow.circlepath", tint: .gInk3,
                                           background: .gFill, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.titulos.titulo(s.id) ?? nombre(s))
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Color.gInk).lineLimit(1)
                                    Text(detalle(s)).gMeta()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.gInk4)
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func nombre(_ s: ACPClient.Session) -> String {
        if s.title != "New Chat", !s.title.isEmpty, s.title != "Sin título" { return s.title }
        return "Conversación sin abrir"
    }

    private func detalle(_ s: ACPClient.Session) -> String {
        var partes: [String] = []
        if let n = s.messageCount { partes.append(n == 1 ? "1 mensaje" : "\(n) mensajes") }
        if let f = s.updatedAt { partes.append(Hilo.hace(f)) }
        return partes.joined(separator: " · ")
    }

    private func mandar(a id: String) {
        let texto = (borradores[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texto.isEmpty else { return }
        borradores[id] = ""
        Task { await store.send(texto, a: id) }
    }
}
