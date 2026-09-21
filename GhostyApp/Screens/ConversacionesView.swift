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

    /// Qué agentes tienen desplegadas sus conversaciones guardadas.
    @State private var desplegados: Set<String> = []
    /// Favoritos (por teléfono). Estado local para repintar al tocar la estrella.
    @State private var favoritos: Set<String> = Favoritos.ids
    /// Sólo favoritos. Recordado.
    @AppStorage("app.soloFavoritos") private var soloFavoritos = false
    /// Qué conversación se está renombrando (agente, sesión) y el texto del campo.
    @State private var renombrando: (agente: String, sesion: String)?
    @State private var nombreNuevo = ""

    /// Favoritos arriba, luego el resto; cada grupo por último uso (sin uso al final, por
    /// nombre). Con «sólo favoritos», nada más el primer grupo.
    private var agentesOrdenados: [Agent] {
        func porUso(_ a: Agent, _ b: Agent) -> Bool {
            switch (a.ultimaActividad, b.ultimaActividad) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        let favs = store.agents.filter { favoritos.contains($0.id) }.sorted(by: porUso)
        let resto = store.agents.filter { !favoritos.contains($0.id) }.sorted(by: porUso)
        return soloFavoritos && !favs.isEmpty ? favs : favs + resto
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                cabecera
                ForEach(agentesOrdenados) { agente in
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
        .alert("Nombre de la conversación", isPresented: Binding(
            get: { renombrando != nil }, set: { if !$0 { renombrando = nil } })) {
            TextField("Lista del súper", text: $nombreNuevo)
            Button("Guardar") {
                if let r = renombrando {
                    Task { await store.renombrar(r.sesion, de: r.agente, a: nombreNuevo) }
                }
                renombrando = nil
            }
            Button("Cancelar", role: .cancel) { renombrando = nil }
        }
    }

    private var cabecera: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Conversaciones").gScreenTitle()
                Text(resumen).gMeta()
            }
            Spacer()
            // Sólo favoritos. Apagado si no hay ninguno marcado.
            if !favoritos.isEmpty || soloFavoritos {
                Button { soloFavoritos.toggle() } label: {
                    TintedIcon(systemName: soloFavoritos ? "star.fill" : "star",
                               tint: soloFavoritos ? Color(hex: 0xF5B300) : .gInk3,
                               background: .gCard, size: 36)
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .disabled(favoritos.isEmpty)
                .accessibilityLabel("Sólo favoritos")
            }
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

            // El mismo orden que la barra de abajo: lo más reciente primero.
            ForEach(Array(canal.recientes.enumerated()), id: \.element.clave) { i, h in
                filaDeHilo(h, canal: canal, agente: agente)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("conversacion-\(agente.id)-\(i)")
                    // Se encoge y se desvanece al irse: la fila SALE en vez de dejar de
                    // estar, que es lo que hace que el borrado se sienta hecho.
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                    .ghostySeparator(inset: 0)
            }

            nuevaConversacion(agente)
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
                HStack(spacing: 6) {
                    Text(agente.name).gRowTitle()
                    // El motor distingue homónimos («Ghosty» ×4); «compartido» dice que
                    // es de otra cuenta y corre con sus llaves.
                    Text(agente.engine).gMeta()
                    if agente.compartidoPor != nil {
                        Text("compartido").gChip().foregroundStyle(Color.gInk3)
                    }
                }
                StatusLine(status: store.estado(de: agente.id)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Favorito: arriba de la lista. Toggle sin cambiar de agente.
            Button {
                Favoritos.alternar(agente.id)
                favoritos = Favoritos.ids
            } label: {
                Image(systemName: favoritos.contains(agente.id) ? "star.fill" : "star")
                    .font(.system(size: 15))
                    .foregroundStyle(favoritos.contains(agente.id) ? Color(hex: 0xF5B300) : Color.gInk3)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favoritos.contains(agente.id) ? "Quitar de favoritos" : "Marcar favorito")

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
        // Sólo las que ya existen en el agente se pueden nombrar: una sin sesión no
        // tiene a qué ponérselo.
        .deslizarParaBorrar("¿Borrar «\(h.titulo)»?",
                             consecuencia: h.sesionID == nil
                                ? "Todavía no existe en tu agente: se descarta y ya."
                                : "Se borra también de tu agente. No se puede deshacer.",
                             alRenombrar: h.sesionID.map { sid in { pedirNombre(agente.id, sid, actual: h.titulo) } }) {
            Task { await store.borrarConversacion(h) }
        }
    }

    private func icono(_ h: Hilo, mirando: Bool) -> some View {
        Group {
            if h.trabajando {
                ProgressView().frame(width: 28, height: 28)
            } else if h.interrumpido {
                // ⚠️ Antes de esta rama caía en la palomita de «listo» si la conversación
                // ya había contestado alguna vez: un hilo cortado a media respuesta se
                // pintaba con la misma marca que uno terminado. Sigue trabajando allá, y
                // el icono lo dice sin alarmar.
                // ⚠️ Un reloj de arena, NO `wifi.slash`: ese decía «te quedaste sin
                // internet», que es lo contrario de lo que pasa —el agente sigue
                // trabajando, sólo que allá—. Y salía dos veces, aquí y en el texto.
                TintedIcon(systemName: "hourglass", tint: .gInk3,
                           background: .gFill, size: 28)
            } else if h.fallo != nil {
                TintedIcon(systemName: "exclamationmark.triangle.fill", tint: .gDangerInk,
                           background: .gDangerTint, size: 28)
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

    /// Empezar una conversación con este agente.
    ///
    /// ⚠️ Aquí había un campo «Pídele algo…» que mandaba SIN llevarte al chat, y prometía
    /// algo que no cumplía: caía en la conversación ACTIVA de ese agente —cuál era, no lo
    /// decía—, la lista no cambiaba a la vista, y si se pasaba del tope de turnos el aviso
    /// se quedaba dentro de esa conversación, donde no lo veías. Un botón que crea una
    /// conversación y te lleva a ella no tiene ninguna de esas dudas.
    private func nuevaConversacion(_ agente: Agent) -> some View {
        Button {
            store.seleccionar(agente.id)
            store.nuevaConversacion()
            store.pedirTeclado = true
            onAbrir()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                Text("Nueva conversación").gChip()
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.gPrimary)
            .padding(.horizontal, Theme.Space.cardH - 4)
            .padding(.vertical, 10)
            .background(Color.gPrimaryTint,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nueva-\(agente.id)")
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
                                    Text(Self.esGenerico(s.title) ? (store.titulos.titulo(agente.id, s.id) ?? nombre(s)) : s.title)
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
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .deslizarParaBorrar("¿Borrar esta conversación?",
                                             consecuencia: "Se borra de tu agente. No se puede deshacer.",
                                             alRenombrar: { pedirNombre(agente.id, s.id, actual: nombre(s)) }) {
                            Task { await store.borrarGuardada(s, de: agente.id) }
                        }
                    }
                }
            }
        }
    }

    /// Abre el campo con el nombre que tiene ahora, para corregirlo en vez de reescribirlo.
    private func pedirNombre(_ agente: String, _ sesion: String, actual: String) {
        nombreNuevo = actual == "Conversación sin abrir" || actual == "Conversación nueva" ? "" : actual
        renombrando = (agente, sesion)
    }

    private func nombre(_ s: ACPClient.Session) -> String {
        if !Self.esGenerico(s.title) { return s.title }
        return "Conversación sin abrir"
    }

    /// Los nombres que pone la caja o gs cuando aún no hay bautizo.
    static func esGenerico(_ t: String) -> Bool {
        t.isEmpty || t == "New Chat" || t == "Sin título" || t == "Conversación" || t == "Conversación nueva"
            || TitleStore.esFontaneria(t)
    }

    private func detalle(_ s: ACPClient.Session) -> String {
        // Primero cómo acabó su último turno, que lo dice el servidor: es lo que hace de
        // la lista un buzón aunque la respuesta llegara con la app cerrada.
        if let u = s.ultimoTurno {
            let cuando = u.terminado.map { " · " + Hilo.hace($0) } ?? ""
            switch u.estado {
            case "running", "queued": return "Trabajando…"
            case "error":   return "Falló: \(u.error ?? "el turno se cortó")"
            case "stopped": return "Detenido" + cuando
            default:        return "Contestó" + cuando
            }
        }
        var partes: [String] = []
        if let n = s.messageCount { partes.append(n == 1 ? "1 mensaje" : "\(n) mensajes") }
        if let f = s.updatedAt { partes.append(Hilo.hace(f)) }
        return partes.joined(separator: " · ")
    }

}
