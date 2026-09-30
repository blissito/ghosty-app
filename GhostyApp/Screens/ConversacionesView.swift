import SwiftUI

/// «Chats»: la pantalla de inicio, como WhatsApp (rediseño 2026-09-29, el mismo de Android).
///
/// - ⋯ a la izquierda (Plan y uso, Leer todo, Ajustes) y + a la derecha («Nueva
///   conversación» con todos los agentes, por último uso).
/// - Título grande «Chats» que al hacer scroll pasa a la barra de arriba.
/// - Buscador en píldora: título, agente y vista previa, en TODAS las conversaciones.
/// - Chips: «Todos» + uno por agente con sus no leídos. El filtro lo guarda `RootView`,
///   porque tocar el avatar de la barra lo pone.
/// - Filas sin divisores: avatar, título, hora (verde si hay pendientes), una línea de
///   vista previa y la insignia verde con el NÚMERO de respuestas sin ver.
/// - Mantener presionado: Cambiar nombre / Archivar (optimista).
///
/// ⚠️ Lo que se conserva de la lista anterior, porque tiene función detrás: el estado real
/// del servidor (trabajando, espera tu permiso) y lo guardado en la caja que no está
/// abierto aquí («guardadas») en la misma lista.
struct ChatsView: View {
    let store: LiveAgentStore
    /// El agente por el que se filtra. `nil` = Todos.
    @Binding var filtro: String?
    /// Se abrió una conversación: `RootView` entra al hilo.
    var onAbrir: () -> Void
    var onPlanYUso: () -> Void
    var onAjustes: () -> Void

    @State private var busqueda = ""
    @FocusState private var buscando: Bool
    /// ¿Ya se fue el título grande hacia arriba? Entonces sale el chico en la barra.
    @State private var tituloArriba = false
    @State private var nueva = false
    /// Qué conversación se está renombrando (agente, sesión) y el texto del campo.
    @State private var renombrando: (agente: String, sesion: String)?
    @State private var nombreNuevo = ""

    static let verde = Color(hex: 0x25A35A)

    // MARK: - Modelo de la lista

    /// Una fila: una conversación abierta en el teléfono o una guardada en la caja.
    private struct Fila: Identifiable {
        enum Tipo { case abierta(Hilo), guardada(ACPClient.Session) }
        let tipo: Tipo
        let agente: Agent
        let titulo: String
        let fecha: Date
        let sesion: String?
        let previa: VistaPrevia?
        /// Respuestas del agente sin ver. 0 = al día.
        let pendientes: Int
        var id: String {
            switch tipo {
            case .abierta(let h): "h-\(agente.id)-\(h.clave)"
            case .guardada(let s): "s-\(agente.id)-\(s.id)"
            }
        }
        /// `agente/sesión`: la llave con la que el store esconde lo que se está archivando.
        var llaveArchivo: String { "\(agente.id)/\(sesion ?? claveLocal)" }
        /// La clave local del hilo, para uno que todavía no tiene sesión en la caja.
        var claveLocal = ""
    }

    /// Los agentes por último uso: el que acabas de usar, primero.
    private var agentesOrdenados: [Agent] {
        store.agents.sorted { a, b in
            switch (a.ultimaActividad, b.ultimaActividad) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// TODAS las filas de todos los agentes (sin filtro ni búsqueda): los chips cuentan
    /// sus no leídos de aquí.
    private var todas: [Fila] {
        var filas: [Fila] = []
        for agente in store.agents {
            guard let canal = store.canales[agente.id] else { continue }
            let remotas = Dictionary(canal.hilosRemotos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for h in canal.hilos {
                // Una conversación nueva sin estrenar no es un chat todavía.
                if h.sesionID == nil && h.mensajes.isEmpty { continue }
                let fecha = h.sesionID.flatMap { remotas[$0]?.updatedAt }.map { max($0, h.tocado) } ?? h.tocado
                let previa = h.mensajes.isEmpty ? store.vistaPrevia(agente.id, h.sesionID) : VistaPrevia.de(h.mensajes)
                let sinVer = h.termino != nil && !h.visto
                filas.append(Fila(tipo: .abierta(h), agente: agente, titulo: h.titulo, fecha: fecha,
                                  sesion: h.sesionID, previa: previa,
                                  pendientes: sinVer ? max(1, previa?.respuestas ?? 1) : 0,
                                  claveLocal: h.clave))
            }
            let abiertas = Set(canal.hilos.compactMap(\.sesionID))
            for s in canal.hilosRemotos where !abiertas.contains(s.id) {
                let previa = store.vistaPrevia(agente.id, s.id)
                let sinVer = store.sinLeer(s, agente: agente.id)
                filas.append(Fila(tipo: .guardada(s), agente: agente, titulo: titulo(s, de: agente),
                                  fecha: s.updatedAt ?? .distantPast, sesion: s.id, previa: previa,
                                  pendientes: sinVer ? max(1, previa?.respuestas ?? 1) : 0))
            }
        }
        return filas.filter { !store.archivando.contains($0.llaveArchivo) }
    }

    private func visibles(_ todas: [Fila]) -> [Fila] {
        var filas = todas
        if let filtro { filas = filas.filter { $0.agente.id == filtro } }
        let q = busqueda.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let opciones: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            filas = filas.filter {
                $0.titulo.range(of: q, options: opciones) != nil
                    || $0.agente.name.range(of: q, options: opciones) != nil
                    || ($0.previa?.texto.range(of: q, options: opciones) != nil)
            }
        }
        return filas.sorted { $0.fecha > $1.fecha }
    }

    private var variosAgentes: Bool { store.agents.count > 1 }

    // MARK: - Pantalla

    var body: some View {
        let todas = todas
        let filas = visibles(todas)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Chats")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.gInk)
                    .padding(.horizontal, 2)
                    .background {
                        GeometryReader { g in
                            Color.clear.preference(key: FondoDelTitulo.self,
                                                   value: g.frame(in: .named("chats")).maxY)
                        }
                    }
                    .padding(.bottom, 10)
                buscador.padding(.bottom, 12)
                if variosAgentes { chips(todas).padding(.bottom, 8) }
                lista(filas)
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 2)
            .padding(.bottom, 24)
        }
        .coordinateSpace(name: "chats")
        .onPreferenceChange(FondoDelTitulo.self) { maxY in
            let arriba = maxY < 4
            if arriba != tituloArriba { withAnimation(.easeOut(duration: 0.18)) { tituloArriba = arriba } }
        }
        .safeAreaInset(edge: .top, spacing: 0) { barraSuperior }
        .scrollDismissesKeyboard(.immediately)
        .scrollIndicators(.hidden)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: filas.map(\.id))
        // Entrar ES verlo: el punto del historial se apaga aquí.
        .onAppear { store.vistoTodo() }
        // Lo que hay se pinta YA; la red sólo si pasaron más de 20 s (lo frena el store).
        .task {
            store.recalcularVistasPrevias()
            store.repasarLaFlota()
            await store.precargarChats()
        }
        .sheet(isPresented: $nueva) {
            NuevaConversacionSheet(agentes: agentesOrdenados) { agente in
                nueva = false
                empezar(con: agente.id)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Theme.Radius.sheet)
        }
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

    /// ⋯ · «Chats» (cuando el grande ya se fue) · +
    private var barraSuperior: some View {
        HStack {
            Menu {
                Button { onPlanYUso() } label: { Label("Plan y uso", systemImage: "chart.bar") }
                Button { store.leerTodo() } label: { Label("Leer todo", systemImage: "checkmark.message") }
                Button { onAjustes() } label: { Label("Ajustes", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.gInk)
                    .frame(width: 34, height: 34)
                    .background(Color.gFill, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Más opciones")
            .accessibilityIdentifier("chats-mas")

            Spacer()

            Button { nueva = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.gPrimary, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.gPressIcon)
            .accessibilityLabel("Nueva conversación")
            .accessibilityIdentifier("nueva-conversacion-lista")
        }
        .overlay {
            Text("Chats")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.gInk)
                .opacity(tituloArriba ? 1 : 0)
                .offset(y: tituloArriba ? 0 : 6)
        }
        .padding(.horizontal, Theme.Space.screenH - 6)
        .frame(height: 50)
        .background {
            Color.gBg
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.gSeparator).frame(height: 0.5).opacity(tituloArriba ? 1 : 0)
                }
                .ignoresSafeArea(edges: .top)
        }
    }

    /// Píldora baja y gris tenue, como WhatsApp.
    private var buscador: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.gInk3)
            TextField("", text: $busqueda,
                      prompt: Text("Buscar").foregroundStyle(Color.gInk3))
                .font(.system(size: 16))
                .foregroundStyle(Color.gInk)
                .focused($buscando)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("buscar-chats")
            if !busqueda.isEmpty {
                Button { withAnimation(.easeOut(duration: 0.2)) { busqueda = "" } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.gInk4)
                }
                .buttonStyle(.gPressIcon)
                .transition(.opacity.combined(with: .scale))
                .accessibilityLabel("Borrar búsqueda")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.gFill, in: Capsule())
        .animation(.easeOut(duration: 0.2), value: busqueda.isEmpty)
    }

    // MARK: - Chips

    private func chips(_ todas: [Fila]) -> some View {
        let sinLeer = Dictionary(grouping: todas.filter { $0.pendientes > 0 }, by: \.agente.id).mapValues(\.count)
        return ScrollViewReader { lector in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(titulo: "Todos", activo: filtro == nil, noLeidos: 0, id: "chip-todos") {
                        filtro = nil
                    } icono: { EmptyView() }
                    ForEach(agentesOrdenados) { a in
                        chip(titulo: a.name, activo: filtro == a.id, noLeidos: sinLeer[a.id] ?? 0,
                             id: "chip-\(a.id)") {
                            filtro = filtro == a.id ? nil : a.id
                        } icono: {
                            AgentAvatar(tone: a.tone, size: 22)
                        }
                        .id(a.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
            // El elegido siempre a la vista: al abrir y cuando lo pone la barra.
            .onAppear { if let id = filtro { lector.scrollTo(id, anchor: .center) } }
            .onChange(of: filtro) { _, id in
                guard let id else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { lector.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func chip<I: View>(titulo: String, activo: Bool, noLeidos: Int, id: String,
                               action: @escaping () -> Void,
                               @ViewBuilder icono: () -> I) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { action() }
        } label: {
            HStack(spacing: 6) {
                icono()
                Text(titulo)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if noLeidos > 0 {
                    Text("\(noLeidos)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(activo ? Color.gPrimary : Color.gInk3)
                }
            }
            .foregroundStyle(activo ? Color.gPrimary : Color.gInk2)
            .padding(.leading, 10).padding(.trailing, 13)
            .frame(height: 34)
            .background(activo ? Color.gPrimaryTint : Color.gCard, in: Capsule())
            .overlay(Capsule().strokeBorder(activo ? Color.clear : Color.gSeparator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.gPressPill)
        .accessibilityAddTraits(activo ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    // MARK: - La lista

    @ViewBuilder
    private func lista(_ filas: [Fila]) -> some View {
        if filas.isEmpty {
            EmptyState(icon: busqueda.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                       title: busqueda.isEmpty ? "Sin conversaciones" : "Nada con «\(busqueda)»",
                       detail: busqueda.isEmpty
                        ? "Toca + para empezar una."
                        : "Busca por el título, el agente o lo que se dijo.")
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(filas) { f in
                    fila(f)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
        }
    }

    private func fila(_ f: Fila) -> some View {
        HStack(spacing: 12) {
            AgentAvatar(tone: f.agente.tone, size: 40)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.gPrimaryTint))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(f.titulo)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if f.fecha > .distantPast {
                        Text(Self.hora(f.fecha))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(f.pendientes > 0 ? Self.verde : Color.gInk3)
                            .fixedSize()
                    }
                }
                HStack(spacing: 8) {
                    subtitulo(f)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    marca(f)
                }
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { abrir(f) }
        .contextMenu {
            if let sid = f.sesion {
                Button {
                    nombreNuevo = f.titulo == "Conversación sin abrir" || f.titulo == "Conversación nueva" ? "" : f.titulo
                    renombrando = (f.agente.id, sid)
                } label: { Label("Cambiar nombre", systemImage: "pencil") }
            }
            Button(role: .destructive) { archivar(f) } label: {
                Label("Archivar", systemImage: "archivebox")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { abrir(f) }
        .accessibilityIdentifier(f.id)
    }

    /// La línea gris: «Espera tu permiso» manda; luego lo último que se dijo.
    @ViewBuilder
    private func subtitulo(_ f: Fila) -> some View {
        if esperaPermiso(f) {
            Text("Espera tu permiso")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.gDangerInk)
                .lineLimit(1)
        } else if let p = f.previa {
            let prefijo = p.deTi ? "Tú: " : (filtro == nil && variosAgentes ? "\(f.agente.name) · " : "")
            Text(prefijo + p.texto)
                .font(.system(size: 14))
                .foregroundStyle(Color.gInk3)
                .lineLimit(1)
        } else {
            switch f.tipo {
            case .abierta(let h):
                EstadoDelHilo(hilo: h).lineLimit(1)
            case .guardada(let s):
                Text(detalle(s, agente: f.agente)).font(.system(size: 14)).foregroundStyle(Color.gInk3).lineLimit(1)
            }
        }
    }

    private func esperaPermiso(_ f: Fila) -> Bool {
        switch f.tipo {
        case .abierta(let h): h.permisoPendiente != nil
        case .guardada(let s): s.permisoPendiente != nil
        }
    }

    private func trabajando(_ f: Fila) -> Bool {
        switch f.tipo {
        case .abierta(let h): h.trabajando
        case .guardada(let s): s.ultimoTurno?.sigueVivo == true
        }
    }

    /// Spinner si trabaja; si no, la insignia verde con el número de respuestas sin ver.
    @ViewBuilder
    private func marca(_ f: Fila) -> some View {
        if trabajando(f) {
            GhostySpinner(size: 14, lineWidth: 1.8)
        } else if f.pendientes > 0 {
            Text("\(f.pendientes)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(Self.verde, in: Capsule())
                .accessibilityLabel("\(f.pendientes) sin leer")
        }
    }

    /// «6:26 p.m.» hoy, «Ayer», el día de la semana esta semana, y si no «d/M/yy».
    static func hora(_ d: Date, ahora: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        if cal.isDateInToday(d) {
            f.dateFormat = "h:mm a"
            return f.string(from: d)
        }
        if cal.isDateInYesterday(d) { return "Ayer" }
        if let hace = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: ahora)), d >= hace {
            f.dateFormat = "EEEE"
            return f.string(from: d).capitalized(with: Locale(identifier: "es_MX"))
        }
        f.dateFormat = "d/M/yy"
        return f.string(from: d)
    }

    // MARK: - Acciones

    private func abrir(_ f: Fila) {
        switch f.tipo {
        case .abierta(let h):
            store.mirar(h, de: f.agente.id)
        case .guardada(let s):
            store.abrirDesdeChats(agente: f.agente.id, sesion: s)
        }
        onAbrir()
    }

    private func archivar(_ f: Fila) {
        switch f.tipo {
        case .abierta(let h): store.archivar(agente: f.agente.id, sesion: h.sesionID, hilo: h)
        case .guardada(let s): store.archivar(agente: f.agente.id, sesion: s.id)
        }
    }

    /// Empezar una conversación con ese agente y llevarte a ella.
    private func empezar(con agenteID: String) {
        if agenteID != store.selectedAgentID { store.seleccionar(agenteID) }
        store.nuevaConversacion()
        store.pedirTeclado = true
        onAbrir()
    }

    private func titulo(_ s: ACPClient.Session, de agente: Agent) -> String {
        if !TitleStore.isGeneric(s.title) { return s.title }
        return store.titulos.titulo(agente.id, s.id) ?? "Conversación sin abrir"
    }

    private func detalle(_ s: ACPClient.Session, agente: Agent) -> String {
        if let u = s.ultimoTurno {
            switch u.estado {
            case "running", "queued": return u.sigueVivo ? "Trabajando…" : "Sin noticias"
            case "error": return "Falló: \(u.error ?? "el turno se cortó")"
            case "stopped": return "Detenido"
            default: return "Contestó"
            }
        }
        if let n = s.messageCount { return n == 1 ? "1 mensaje" : "\(n) mensajes" }
        return "Toca para abrirla"
    }
}

/// Dónde acaba el título grande, para saber cuándo pasa a la barra.
private struct FondoDelTitulo: PreferenceKey {
    static let defaultValue: CGFloat = 100
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// La hoja del +: todos los agentes por último uso. Tocar uno empieza una conversación.
struct NuevaConversacionSheet: View {
    let agentes: [Agent]
    var onElegir: (Agent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nueva conversación")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.gInk)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(agentes) { a in
                        Button { onElegir(a) } label: {
                            HStack(spacing: 12) {
                                AgentAvatar(tone: a.tone, size: 40)
                                    .frame(width: 48, height: 48)
                                    .background(Circle().fill(Color.gPrimaryTint))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Color.gInk)
                                        .lineLimit(1)
                                    Text(CambiarAgenteSheet.tipo(a))
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.gInk3)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("nueva-con-\(a.id)")
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color.gBg)
    }
}
