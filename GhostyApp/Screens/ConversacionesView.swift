import SwiftUI

/// «Chats»: todas tus conversaciones, de todos tus agentes, por fecha (diseño 2026-09).
///
/// ⚠️ Sustituye a la Flota y a la lista agrupada por agente. Lo que se conserva de ellas,
/// porque tiene función detrás:
/// - **Estado real** en el subtítulo (`EstadoDelHilo` / el `ultimoTurno` del servidor), no
///   un resumen inventado, y un icono a la derecha sólo cuando hay algo que ver.
/// - **Favoritos** (por agente), renombrar, borrar deslizando y detener todo.
/// - **Espacios**: con más de un agente salen como filtros, ordenados por espacio
///   (tuyos, cada workspace, compartidos), y cada fila dice de quién es.
/// - Lo que vive en la caja y no está abierto aquí («guardadas») entra en la misma lista.
struct ConversacionesView: View {
    let store: LiveAgentStore
    var onCuenta: () -> Void
    /// Tocar una conversación te lleva a ella: quien cambia de pestaña es `RootView`.
    var onAbrir: () -> Void
    /// «Ver plan y uso» de un agente.
    var onAgentTap: (Agent) -> Void = { _ in }

    // ⚠️ El filtro nace YA puesto: ponerlo en `onAppear` pintaba primero todos los agentes y
    // luego saltaba al actual, y la apertura se sentía lenta.
    init(store: LiveAgentStore, onCuenta: @escaping () -> Void, onAbrir: @escaping () -> Void,
         onAgentTap: @escaping (Agent) -> Void = { _ in }) {
        self.store = store
        self.onCuenta = onCuenta
        self.onAbrir = onAbrir
        self.onAgentTap = onAgentTap
        _soloAgente = State(initialValue: store.agents.count > 1 ? store.selectedAgentID : nil)
    }

    @State private var busqueda = ""
    @FocusState private var buscando: Bool
    /// El agente por el que se filtra. `nil` = todos.
    /// Arranca en el agente actual: lo que esperas ver son SUS conversaciones. «Todos»
    /// sigue a un toque en los chips.
    @State private var soloAgente: String?
    /// Favoritos (por teléfono). Estado local para repintar al tocar la estrella.
    @State private var favoritos: Set<String> = Favoritos.ids
    /// Sólo favoritos. Recordado.
    @AppStorage("app.soloFavoritos") private var soloFavoritos = false
    /// Qué conversación se está renombrando (agente, sesión) y el texto del campo.
    @State private var renombrando: (agente: String, sesion: String)?
    @State private var nombreNuevo = ""

    // MARK: - Modelo de la lista

    /// Una fila: una conversación abierta en el teléfono o una guardada en la caja.
    private struct Fila: Identifiable {
        enum Tipo { case abierta(Hilo, Canal), guardada(ACPClient.Session) }
        let tipo: Tipo
        let agente: Agent
        let titulo: String
        let fecha: Date
        var id: String {
            switch tipo {
            case .abierta(let h, _): "h-\(h.clave)"
            case .guardada(let s): "s-\(agente.id)-\(s.id)"
            }
        }
    }

    private enum Grupo: Int, CaseIterable {
        case hoy, semana, antes
        var titulo: String {
            switch self {
            case .hoy: "Hoy"
            case .semana: "Esta semana"
            case .antes: "Antes"
            }
        }
        static func de(_ fecha: Date, ahora: Date = Date()) -> Grupo {
            let cal = Calendar.current
            if cal.isDateInToday(fecha) { return .hoy }
            if let hace = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: ahora)),
               fecha >= hace { return .semana }
            return .antes
        }
    }

    /// Los agentes por espacio (tuyos, cada workspace, compartidos) y, dentro, favoritos
    /// primero y luego por último uso.
    private var agentesOrdenados: [Agent] {
        func rango(_ a: Agent) -> Int {
            switch (a.space ?? .personal).kind { case .personal: 0; case .workspace: 1; case .shared: 2 }
        }
        // Por último uso: el agente con el que acabas de hablar va primero, sea del espacio
        // que sea (así lo buscas). `rango` sólo desempata.
        return store.agents.sorted { a, b in
            let fa = favoritos.contains(a.id), fb = favoritos.contains(b.id)
            if fa != fb { return fa }
            switch (a.ultimaActividad, b.ultimaActividad) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if rango(a) != rango(b) { return rango(a) < rango(b) }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// De qué agentes se enseñan conversaciones.
    private var agentesVisibles: [Agent] {
        var lista = agentesOrdenados
        if soloFavoritos, !favoritos.isEmpty { lista = lista.filter { favoritos.contains($0.id) } }
        if let soloAgente { lista = lista.filter { $0.id == soloAgente } }
        return lista
    }

    private var filas: [Fila] {
        var todas: [Fila] = []
        for agente in agentesVisibles {
            guard let canal = store.canales[agente.id] else { continue }
            let remotas = Dictionary(canal.hilosRemotos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for h in canal.hilos {
                // La fecha del servidor, si la conversación también vive allá y es más nueva.
                let delServidor = h.sesionID.flatMap { remotas[$0]?.updatedAt }
                let fecha = delServidor ?? h.tocado
                todas.append(Fila(tipo: .abierta(h, canal), agente: agente, titulo: h.titulo, fecha: fecha))
            }
            let abiertas = Set(canal.hilos.compactMap(\.sesionID))
            for s in canal.hilosRemotos where !abiertas.contains(s.id) {
                todas.append(Fila(tipo: .guardada(s), agente: agente, titulo: titulo(s, de: agente),
                                  fecha: s.updatedAt ?? .distantPast))
            }
        }
        let q = busqueda.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            todas = todas.filter {
                $0.titulo.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || $0.agente.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return todas.sorted { $0.fecha > $1.fecha }
    }

    private var variosAgentes: Bool { store.agents.count > 1 }

    // MARK: - Pantalla

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cabecera.padding(.bottom, 14)
                buscador.padding(.bottom, variosAgentes ? 12 : 18)
                if variosAgentes { filtroDeAgentes.padding(.bottom, 16) }
                avisos
                lista
                pie.padding(.top, 4)
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .scrollIndicators(.hidden)
        // ⚠️ Entrar ES verlo: el punto del historial se apaga aquí.
        .onAppear { store.vistoTodo() }
        // Lo guardado del agente activo; los demás vienen del caché y de `repasarLaFlota`.
        .task { await store.cargarHilos() }
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
        HStack(alignment: .center, spacing: 4) {
            Text("Chats").gScreenTitle()
                .padding(.horizontal, 2)
            Spacer()
            if !favoritos.isEmpty || soloFavoritos {
                botonDeIcono(soloFavoritos ? "star.fill" : "star",
                             tinta: soloFavoritos ? Color(hex: 0xF5B300) : .gInk) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { soloFavoritos.toggle() }
                }
                .disabled(favoritos.isEmpty)
                .accessibilityLabel("Sólo favoritos")
            }
            botonDeIcono("person.crop.circle", tinta: .gInk, action: onCuenta)
                .accessibilityLabel("Perfil")
                .accessibilityIdentifier("cuenta")
            botonDeIcono("square.and.pencil", tinta: .gInk) { nueva(en: soloAgente ?? store.selectedAgentID) }
                .accessibilityLabel("Nueva conversación")
                .accessibilityIdentifier("nueva-conversacion-lista")
        }
    }

    private func botonDeIcono(_ simbolo: String, tinta: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: simbolo)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tinta)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.gPressIcon)
    }

    /// «Buscar en tus chats»: por título (y por nombre del agente), en el teléfono.
    private var buscador: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.gInk3)
            TextField("", text: $busqueda,
                      prompt: Text("Buscar en tus chats").foregroundStyle(Color.gInk4))
                .font(.system(size: 15))
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
        .frame(height: 42)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: busqueda.isEmpty)
    }

    // MARK: - Agentes (filtro por espacio)

    private var filtroDeAgentes: some View {
        ScrollViewReader { lector in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(titulo: "Todos", activo: soloAgente == nil, id: "chip-todos") {
                    soloAgente = nil
                } icono: { EmptyView() }
                let agentes = agentesOrdenados
                ForEach(Array(agentes.enumerated()), id: \.element.id) { i, a in
                    // Un filete entre espacios: la agrupación sólo se nota donde importa.
                    if i > 0, (agentes[i - 1].space ?? .personal) != (a.space ?? .personal) {
                        Rectangle().fill(Color.gFillStrong).frame(width: 1, height: 20)
                            .padding(.horizontal, 2)
                    }
                    chipDeAgente(a).id(a.id)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        // El elegido siempre a la vista: al abrir (sin animación) y al cambiarlo.
        .onAppear { if let id = soloAgente { lector.scrollTo(id, anchor: .center) } }
        .onChange(of: soloAgente) { _, id in
            guard let id else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { lector.scrollTo(id, anchor: .center) }
        }
        }
    }

    private func chipDeAgente(_ a: Agent) -> some View {
        let canal = store.canales[a.id]
        return chip(titulo: a.name, activo: soloAgente == a.id, id: "chip-\(a.id)",
                    trabajando: canal?.trabajando == true) {
            soloAgente = soloAgente == a.id ? nil : a.id
        } icono: {
            ZStack(alignment: .topTrailing) {
                AgentAvatar(tone: a.tone, size: 22)
                if favoritos.contains(a.id) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color(hex: 0xF5B300))
                        .offset(x: 3, y: -3)
                }
            }
        }
        .contextMenu {
            Button {
                Favoritos.alternar(a.id)
                withAnimation { favoritos = Favoritos.ids }
            } label: {
                Label(favoritos.contains(a.id) ? "Quitar de favoritos" : "Marcar favorito",
                      systemImage: favoritos.contains(a.id) ? "star.slash" : "star")
            }
            Button { nueva(en: a.id) } label: {
                Label("Nueva conversación", systemImage: "square.and.pencil")
            }
            Button { onAgentTap(a) } label: {
                Label("Plan y uso", systemImage: "chart.bar")
            }
            if let canal, canal.trabajando {
                Button(role: .destructive) { store.detenerTodo(canal) } label: {
                    Label("Detener todo", systemImage: "stop.fill")
                }
            }
        }
    }

    private func chip<I: View>(titulo: String, activo: Bool, id: String, trabajando: Bool = false,
                               action: @escaping () -> Void,
                               @ViewBuilder icono: () -> I) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { action() }
        } label: {
            HStack(spacing: 6) {
                icono()
                Text(titulo)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if trabajando { GhostySpinner(size: 11, lineWidth: 1.5) }
            }
            .foregroundStyle(activo ? Color.white : Color.gInk2)
            .padding(.leading, 10).padding(.trailing, 13)
            .frame(height: 32)
            .background(activo ? Color.gDark : Color.gCard, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.gPressPill)
        .accessibilityAddTraits(activo ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    // MARK: - Lo que está pasando ahora

    /// Los agentes que NO están en reposo: trabajando (aquí o en otra superficie) o
    /// detenidos esperando tu visto bueno. Con su botón de detener todo.
    @ViewBuilder
    private var avisos: some View {
        let activos = agentesVisibles.filter {
            if case .idle = store.estado(de: $0.id) { return false }
            return true
        }
        if !activos.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(activos.enumerated()), id: \.element.id) { i, a in
                    HStack(spacing: 10) {
                        AgentAvatar(tone: a.tone, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.gInk)
                            StatusLine(status: store.estado(de: a.id)).lineLimit(1)
                                .accessibilityIdentifier("estado-\(a.id)")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let canal = store.canales[a.id], canal.trabajando {
                            Button { store.detenerTodo(canal) } label: {
                                Text("Detener")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.gInk)
                                    .padding(.horizontal, 11).padding(.vertical, 7)
                                    .background(Color.gFill, in: Capsule())
                            }
                            .buttonStyle(.gPressPill)
                            .accessibilityIdentifier("detener-\(a.id)")
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .ghostySeparator(inset: i == activos.count - 1 ? .infinity : 0)
                }
            }
            .background(Color.gCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.list, style: .continuous))
            .padding(.bottom, 20)
            .transition(.gIn)
        }
    }

    // MARK: - La lista por fecha

    @ViewBuilder
    private var lista: some View {
        let todas = filas
        if todas.isEmpty {
            EmptyState(icon: busqueda.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                       title: busqueda.isEmpty ? "Sin conversaciones" : "Nada con «\(busqueda)»",
                       detail: busqueda.isEmpty
                        ? "Empieza una y aparecerá aquí."
                        : "Busca por el título de la conversación o el nombre del agente.")
                .padding(.vertical, 40)
        } else {
            let grupos = Dictionary(grouping: todas) { Grupo.de($0.fecha) }
            ForEach(Grupo.allCases, id: \.self) { g in
                if let filasDelGrupo = grupos[g], !filasDelGrupo.isEmpty {
                    Text(g.titulo).gSectionCaps()
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                    VStack(spacing: 0) {
                        ForEach(Array(filasDelGrupo.enumerated()), id: \.element.id) { i, f in
                            fila(f)
                                .ghostySeparator(inset: i == filasDelGrupo.count - 1 ? .infinity : 16)
                                .transition(.opacity)
                                // Se encoge y se desvanece al irse: la fila SALE en vez de
                                // dejar de estar, que es lo que hace sentir el borrado hecho.
                                .transition(.scale(scale: 0.94).combined(with: .opacity))
                        }
                    }
                    .background(Color.gCard)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.list, style: .continuous))
                    .padding(.bottom, 20)
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: todas.map(\.id))
        }
    }

    @ViewBuilder
    private func fila(_ f: Fila) -> some View {
        switch f.tipo {
        case .abierta(let h, let canal): filaAbierta(h, canal: canal, fila: f)
        case .guardada(let s): filaGuardada(s, fila: f)
        }
    }

    /// El identificador de UI tests de siempre: `conversacion-<agente>-<índice>`.
    private func idDeFila(_ f: Fila) -> String {
        guard case .abierta(let h, let canal) = f.tipo,
              let i = canal.recientes.firstIndex(where: { $0.clave == h.clave }) else {
            return "guardada-\(f.id)"
        }
        return "conversacion-\(f.agente.id)-\(i)"
    }

    private func filaAbierta(_ h: Hilo, canal: Canal, fila f: Fila) -> some View {
        let mirando = h.clave == store.hiloActivo?.clave && f.agente.id == store.selectedAgentID
        return Button {
            store.mirar(h, de: f.agente.id)
            onAbrir()
        } label: {
            renglon(titulo: f.titulo, agente: f.agente, fecha: f.fecha) {
                EstadoDelHilo(hilo: h).lineLimit(1)
            } marca: {
                marca(de: h, mirando: mirando)
            }
        }
        .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gCardPressed))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(idDeFila(f))
        // Sólo las que ya existen en el agente se pueden nombrar.
        .deslizarParaBorrar("¿Borrar «\(h.titulo)»?",
                             consecuencia: h.sesionID == nil
                                ? "Todavía no existe en tu agente: se descarta y ya."
                                : "Se borra también de tu agente. No se puede deshacer.",
                             alRenombrar: h.sesionID.map { sid in { pedirNombre(f.agente.id, sid, actual: h.titulo) } }) {
            Task { await store.borrarConversacion(h) }
        }
    }

    private func filaGuardada(_ s: ACPClient.Session, fila f: Fila) -> some View {
        Button {
            Task {
                if f.agente.id != store.selectedAgentID { store.seleccionar(f.agente.id) }
                await store.abrirHilo(s)
                onAbrir()
            }
        } label: {
            renglon(titulo: f.titulo, agente: f.agente, fecha: f.fecha) {
                Text(detalle(s)).gMeta().lineLimit(1)
            } marca: {
                marca(de: s)
            }
        }
        .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gCardPressed))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(idDeFila(f))
        .deslizarParaBorrar("¿Borrar esta conversación?",
                             consecuencia: "Se borra de tu agente. No se puede deshacer.",
                             alRenombrar: { pedirNombre(f.agente.id, s.id, actual: f.titulo) }) {
            Task { await store.borrarGuardada(s, de: f.agente.id) }
        }
    }

    /// La fila del diseño: título 600 15 y subtítulo 13 gris; con varios agentes y sin
    /// filtro, el subtítulo empieza por el nombre del agente.
    private func renglon<S: View, M: View>(titulo: String, agente: Agent, fecha: Date,
                                           @ViewBuilder subtitulo: () -> S,
                                           @ViewBuilder marca: () -> M) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(titulo)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Cuándo se usó: hace legible que la lista va de lo último a lo viejo.
                    if fecha > .distantPast {
                        Text(Self.cuando(fecha))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Color.gInk3)
                            .fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    if variosAgentes, soloAgente == nil {
                        Text("\(agente.name) ·").gMeta().lineLimit(1).fixedSize()
                    }
                    subtitulo()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            marca()
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    /// «ahora», «12 min», «3 h», «ayer», «lun», «12 sep».
    static func cuando(_ d: Date, ahora: Date = Date()) -> String {
        let seg = ahora.timeIntervalSince(d)
        if seg < 60 { return "ahora" }
        if seg < 3600 { return "\(Int(seg / 60)) min" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "\(Int(seg / 3600)) h" }
        if cal.isDateInYesterday(d) { return "ayer" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = seg < 6 * 86400 ? "EEE" : "d MMM"
        return f.string(from: d).replacingOccurrences(of: ".", with: "")
    }

    /// El icono de estado, sólo cuando dice algo: trabajando, cortada, falló, espera
    /// permiso, contestó sin verse o es la que tienes abierta. (El fallo ya lo dice el
    /// subtítulo, en rojo y con su triángulo: no se repite.)
    @ViewBuilder
    private func marca(de h: Hilo, mirando: Bool) -> some View {
        if h.trabajando {
            GhostySpinner()
        } else if h.permisoPendiente != nil {
            simbolo("hand.raised.fill", .gDangerInk)
        } else if h.interrumpido {
            // ⚠️ Un reloj de arena, NO `wifi.slash`: el agente sigue trabajando allá.
            simbolo("hourglass", .gInk3)
        } else if h.termino != nil, !h.visto {
            Circle().fill(Color.gGreen).frame(width: 8, height: 8)
                .accessibilityLabel("Sin leer")
        } else if mirando {
            CheckIcon()
                .stroke(Color.gPrimary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 16)
                .accessibilityLabel("Abierta")
        }
    }

    @ViewBuilder
    private func marca(de s: ACPClient.Session) -> some View {
        if s.permisoPendiente != nil {
            simbolo("hand.raised.fill", .gDangerInk)
        } else if let u = s.ultimoTurno {
            if (u.estado == "running" || u.estado == "queued") && u.sigueVivo {
                GhostySpinner()
            } else if u.estado == "error" {
                simbolo("exclamationmark.triangle.fill", .gDangerInk)
            }
        }
    }

    private func simbolo(_ nombre: String, _ color: Color) -> some View {
        Image(systemName: nombre)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
    }

    /// Debajo de la lista: pedirle a la caja lo que tiene guardado (cuesta despertarla,
    /// por eso no se hace para todos los agentes al abrir).
    @ViewBuilder
    private var pie: some View {
        let agente = store.agents.first { $0.id == (soloAgente ?? store.selectedAgentID) }
        if let agente, let canal = store.canales[agente.id] {
            if case .cargando = canal.estadoHilos {
                HStack(spacing: 8) {
                    GhostySpinner()
                    Text("Preguntándole a \(agente.name) por sus conversaciones…").gCaption()
                }
                .padding(.horizontal, 4)
            } else if case .fallo = canal.estadoHilos {
                botonDeGuardadas(agente, texto: "No pude traer las guardadas de \(agente.name). Reintentar")
            } else if canal.estadoHilos == .sinPedir || agente.id != store.selectedAgentID {
                botonDeGuardadas(agente, texto: "Buscar más conversaciones de \(agente.name)")
            }
        }
    }

    private func botonDeGuardadas(_ agente: Agent, texto: String) -> some View {
        Button {
            if agente.id != store.selectedAgentID { store.seleccionar(agente.id) }
            Task { await store.cargarHilos() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold))
                Text(texto).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.gPrimary)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .buttonStyle(.gPressPill)
        .accessibilityIdentifier("guardadas-\(agente.id)")
    }

    // MARK: - Acciones

    /// Empezar una conversación con ese agente y llevarte a ella.
    private func nueva(en agenteID: String) {
        if agenteID != store.selectedAgentID { store.seleccionar(agenteID) }
        store.nuevaConversacion()
        store.pedirTeclado = true
        onAbrir()
    }

    /// Abre el campo con el nombre que tiene ahora, para corregirlo en vez de reescribirlo.
    private func pedirNombre(_ agente: String, _ sesion: String, actual: String) {
        nombreNuevo = actual == "Conversación sin abrir" || actual == "Conversación nueva" ? "" : actual
        renombrando = (agente, sesion)
    }

    private func titulo(_ s: ACPClient.Session, de agente: Agent) -> String {
        if !TitleStore.isGeneric(s.title) { return s.title }
        return store.titulos.titulo(agente.id, s.id) ?? "Conversación sin abrir"
    }

    private func detalle(_ s: ACPClient.Session) -> String {
        // Antes que nada: esta conversación está detenida hasta que alguien conteste.
        if let p = s.permisoPendiente { return "Espera tu visto bueno · \(p)" }
        // Primero cómo acabó su último turno, que lo dice el servidor.
        if let u = s.ultimoTurno {
            let cuando = u.terminado.map { " · " + Hilo.hace($0) } ?? ""
            switch u.estado {
            case "running", "queued":
                // ⚠️ Con fecha: un turno que dice «running» desde hace horas no está
                // trabajando, se quedó colgado.
                guard u.sigueVivo else {
                    return "Sin noticias" + (u.iniciado.map { " · " + Hilo.hace($0) } ?? "")
                }
                return "Trabajando…"
            case "error":   return "Falló: \(u.error ?? "el turno se cortó")"
            case "stopped": return "Detenido" + cuando
            default:        return "Contestó" + cuando
            }
        }
        var partes: [String] = []
        if let n = s.messageCount { partes.append(n == 1 ? "1 mensaje" : "\(n) mensajes") }
        if let f = s.updatedAt { partes.append(Hilo.hace(f)) }
        return partes.isEmpty ? "Guardada en tu agente" : partes.joined(separator: " · ")
    }
}
