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
    /// El ⋯: menú propio (tarjeta blanca, radio 18, borde fino), no el nativo.
    @State private var menuAbierto = false
    /// Modo selección de WhatsApp: mantener presionada una fila o «Seleccionar chats».
    @State private var seleccionando = false
    @State private var seleccion: Set<String> = []
    /// Conversaciones favoritas (`agente/sesión`) y el filtro «sólo favoritos».
    @State private var favoritas: Set<String> = ChatsFavoritos.ids
    @AppStorage("app.chats.soloFavoritos") private var soloFavoritos = false
    /// Chats fijados arriba (deslizar a la derecha → Fijar), como WhatsApp.
    @State private var fijadas: Set<String> = ChatsFijados.ids
    /// El chat que se va a archivar (confirmación).
    @State private var porArchivar: Fila?
    /// Qué conversación se está renombrando (agente, sesión) y el texto del campo.
    @State private var renombrando: (agente: String, sesion: String)?
    @State private var nombreNuevo = ""

    /// Color de no leídos (insignia, hora y palomita de selección): el lila de la marca,
    /// por decisión de bliss (2026-09-29), no el verde de WhatsApp.
    static let verde = Color.gPrimary

    // MARK: - Modelo de la lista

    /// Una fila: una conversación abierta en el teléfono o una guardada en la caja.
    /// La usa también «Enviar a un chat» (misma fuente que esta lista).
    struct Fila: Identifiable {
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

    /// Los agentes por último uso: su conversación más reciente o su última actividad.
    private func agentesOrdenados(_ todas: [Fila]) -> [Agent] {
        var ultima: [String: Date] = [:]
        for f in todas where f.fecha > (ultima[f.agente.id] ?? .distantPast) { ultima[f.agente.id] = f.fecha }
        func cuando(_ a: Agent) -> Date { max(ultima[a.id] ?? .distantPast, a.ultimaActividad ?? .distantPast) }
        return store.agents.sorted { a, b in
            let x = cuando(a), y = cuando(b)
            if x != y { return x > y }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// TODAS las filas de todos los agentes (sin filtro ni búsqueda): los chips cuentan
    /// sus no leídos de aquí.
    private var todas: [Fila] { Self.filas(store) }

    /// Las conversaciones de todos los agentes, como las pinta Chats.
    static func filas(_ store: LiveAgentStore) -> [Fila] {
        func titulo(_ s: ACPClient.Session, de agente: Agent) -> String {
            if !TitleStore.isGeneric(s.title) { return s.title }
            return store.titulos.titulo(agente.id, s.id) ?? "Conversación sin abrir"
        }
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
        if soloFavoritos { filas = filas.filter { favoritas.contains($0.llaveArchivo) } }
        let q = busqueda.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let opciones: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            filas = filas.filter {
                $0.titulo.range(of: q, options: opciones) != nil
                    || $0.agente.name.range(of: q, options: opciones) != nil
                    || ($0.previa?.texto.range(of: q, options: opciones) != nil)
            }
        }
        return filas.sorted { a, b in
            let fa = fijadas.contains(a.llaveArchivo), fb = fijadas.contains(b.llaveArchivo)
            if fa != fb { return fa }
            return a.fecha > b.fecha
        }
    }

    private var variosAgentes: Bool { store.agents.count > 1 }

    // MARK: - Pantalla

    var body: some View {
        let todas = todas
        let filas = visibles(todas)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Grande a la izquierda; al hacer scroll sube a la barra, al centro (WhatsApp).
                Text("Chats")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.gInk)
                    .padding(.horizontal, 2)
                    .opacity(tituloArriba ? 0 : 1)
                    .background {
                        GeometryReader { g in
                            Color.clear.preference(key: FondoDelTitulo.self,
                                                   value: g.frame(in: .named("chats")).maxY)
                        }
                    }
                    .padding(.bottom, 10)
                buscador.padding(.bottom, 12)
                if variosAgentes { chips(todas, orden: agentesOrdenados(todas)).padding(.bottom, 8) }
                lista(filas)
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .coordinateSpace(name: "chats")
        // Cuánto se ha desplazado la lista: pasado el título grande, sube el chico al centro.
        .modifier(SeguirDesplazamiento { y in
            let arriba = y > 38
            if arriba != tituloArriba { withAnimation(.easeOut(duration: 0.18)) { tituloArriba = arriba } }
        })
        .safeAreaInset(edge: .top, spacing: 0) {
            if seleccionando { barraDeSeleccion(todas) } else { barraSuperior }
        }
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
        .overlay(alignment: .topLeading) {
            if menuAbierto {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { menuAbierto = false } }
                    MenuDeGhosty(opciones: [
                        .init(titulo: "Marcar como leídos", simbolo: "checkmark.message") { store.leerTodo() },
                        .init(titulo: "Seleccionar chats", simbolo: "checkmark.circle") {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { seleccionando = true }
                        },
                    ]) { withAnimation(.easeOut(duration: 0.15)) { menuAbierto = false } }
                    .padding(.leading, Theme.Space.screenH - 6)
                    .padding(.top, 46)
                    .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
                }
            }
        }
        .sheet(isPresented: $nueva) {
            NuevaConversacionSheet(agentes: agentesOrdenados(todas)) { agente in
                nueva = false
                empezar(con: agente.id)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Theme.Radius.sheet)
        }
        .confirmationDialog(porArchivar.map { "¿Archivar «\($0.titulo)»?" } ?? "",
                            isPresented: Binding(get: { porArchivar != nil }, set: { if !$0 { porArchivar = nil } }),
                            titleVisibility: .visible) {
            Button("Archivar", role: .destructive) {
                if let f = porArchivar { archivar(f) }
                porArchivar = nil
            }
            Button("Cancelar", role: .cancel) { porArchivar = nil }
        } message: {
            Text("Se quita de tus chats y de tu agente.")
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

    /// ⋯ · «Chats» (cuando el grande ya se fue) · ☆ · +
    private var barraSuperior: some View {
        HStack(spacing: 2) {
            // Como WhatsApp: icono solo, sin fondo.
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { menuAbierto.toggle() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.gInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .cristalCircular()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Menú")
            .accessibilityIdentifier("chats-mas")

            Spacer()

            // Donde WhatsApp pone la cámara: la estrella de «sólo favoritos».
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { soloFavoritos.toggle() }
            } label: {
                Image(systemName: soloFavoritos ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(soloFavoritos ? Self.oro : Color.gInk)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .cristalCircular()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sólo favoritos")
            .accessibilityAddTraits(soloFavoritos ? .isSelected : [])
            .accessibilityIdentifier("chats-favoritos")
            .padding(.trailing, 12)

            Button { nueva = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .cristalCircular(tinte: .gPrimary)
            }
            .buttonStyle(.plain)
            .disabled(store.agents.isEmpty)
            .accessibilityLabel("Nueva conversación")
            .accessibilityIdentifier("nueva-conversacion-lista")
        }
        // «Chats» chico al centro sólo cuando el grande ya subió, como WhatsApp.
        .overlay {
            Text("Chats")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.gInk)
                .opacity(tituloArriba ? 1 : 0)
                .offset(y: tituloArriba ? 0 : 8)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, Theme.Space.screenH - 4)
        .padding(.vertical, 4)
        .frame(height: 56)
        // Lo que pasa por debajo se difumina (Liquid Glass): la lista corre DETRÁS de la barra.
        .background {
            FondoDeBarraDifuminado(intensidad: tituloArriba ? 1 : 0)
                .padding(.bottom, -18)
                .animation(.easeOut(duration: 0.2), value: tituloArriba)
        }
    }

    /// La barra del modo selección: ✕, cuántos, y las acciones sobre los elegidos.
    private func barraDeSeleccion(_ todas: [Fila]) -> some View {
        let elegidas = todas.filter { seleccion.contains($0.llaveArchivo) }
        let todasFavoritas = !elegidas.isEmpty && elegidas.allSatisfy { favoritas.contains($0.llaveArchivo) }
        return HStack(spacing: 2) {
            Button(action: salirDeSeleccion) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.gPressIcon)
            .accessibilityLabel("Terminar selección")
            .accessibilityIdentifier("seleccion-cerrar")

            Text(elegidas.isEmpty ? "Selecciona chats" : "\(elegidas.count)")
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.numericText())
            Spacer()

            accion(todasFavoritas ? "star.slash" : "star.fill",
                   todasFavoritas ? "Quitar de favoritos" : "Agregar a favoritos", activa: !elegidas.isEmpty) {
                for f in elegidas where favoritas.contains(f.llaveArchivo) == todasFavoritas {
                    ChatsFavoritos.alternar(f.llaveArchivo)
                }
                favoritas = ChatsFavoritos.ids
                salirDeSeleccion()
            }
            accion("checkmark.message", "Marcar como leídos", activa: !elegidas.isEmpty) {
                for f in elegidas { marcarLeida(f) }
                salirDeSeleccion()
            }
            if elegidas.count == 1, let f = elegidas.first, let sid = f.sesion {
                accion("pencil", "Cambiar nombre", activa: true) {
                    nombreNuevo = f.titulo == "Conversación sin abrir" || f.titulo == "Conversación nueva" ? "" : f.titulo
                    renombrando = (f.agente.id, sid)
                    salirDeSeleccion()
                }
            }
            accion("archivebox", "Archivar", activa: !elegidas.isEmpty) {
                for f in elegidas { archivar(f) }
                salirDeSeleccion()
            }
        }
        .foregroundStyle(Color.gPrimary)
        .padding(.horizontal, Theme.Space.screenH - 10)
        .frame(height: 50)
        .background(Color.gPrimaryRing.ignoresSafeArea(edges: .top))
        .transition(.opacity)
    }

    private func accion(_ simbolo: String, _ nombre: String, activa: Bool, _ hacer: @escaping () -> Void) -> some View {
        Button(action: hacer) {
            Image(systemName: simbolo)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 42, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.gPressIcon)
        .disabled(!activa)
        .opacity(activa ? 1 : 0.4)
        .accessibilityLabel(nombre)
    }

    private func salirDeSeleccion() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            seleccionando = false
            seleccion = []
        }
    }

    /// Píldora baja y gris tenue, como WhatsApp.
    private var buscador: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.gInk3)
            TextField("", text: $busqueda,
                      prompt: Text(soloFavoritos ? "Buscar en chats favoritos" : "Buscar").foregroundStyle(Color.gInk3))
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
        .frame(height: 44)
        .background(Color.gFill, in: Capsule())
        .animation(.easeOut(duration: 0.2), value: busqueda.isEmpty)
    }

    // MARK: - Chips

    private func chips(_ todas: [Fila], orden: [Agent]) -> some View {
        let sinLeer = Dictionary(grouping: todas.filter { $0.pendientes > 0 }, by: \.agente.id).mapValues(\.count)
        return ScrollViewReader { lector in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(titulo: "Todos", activo: filtro == nil, noLeidos: 0, id: "chip-todos") {
                        filtro = nil
                    } icono: { EmptyView() }
                    ForEach(orden) { a in
                        chip(titulo: a.name, activo: filtro == a.id, noLeidos: sinLeer[a.id] ?? 0,
                             id: "chip-\(a.id)") {
                            filtro = filtro == a.id ? nil : a.id
                        } icono: {
                            AgentAvatar(tone: a.tone, size: 24)
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

    /// El chip de WhatsApp: el activo con relleno lila suave, borde lila y texto morado; los
    /// demás blancos con borde gris.
    private func chip<I: View>(titulo: String, activo: Bool, noLeidos: Int, id: String,
                               action: @escaping () -> Void,
                               @ViewBuilder icono: () -> I) -> some View {
        let tinta = activo ? Color.gPrimary : Color.gInk2
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { action() }
        } label: {
            HStack(spacing: 6) {
                icono()
                Text(titulo)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if noLeidos > 0 {
                    Text("\(noLeidos)")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(tinta)
            .padding(.leading, id == "chip-todos" ? 16 : 6).padding(.trailing, 16)
            .frame(height: 36)
            .background(activo ? Self.chipActivo : Color.gCard, in: Capsule())
            .overlay(Capsule().strokeBorder(activo ? Self.chipBorde : Color.gSeparator, lineWidth: 1.2))
            .contentShape(Capsule())
        }
        .buttonStyle(.gPressPill)
        .accessibilityAddTraits(activo ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    static let chipActivo = Color(light: 0xECECFB, dark: 0x2A2650)
    static let chipBorde = Color(light: 0xAEADEF, dark: 0x5B55A8)
    /// Estrella de favoritos: bird de la paleta oficial.
    static let oro = Color.gBird

    // MARK: - La lista

    @ViewBuilder
    private func lista(_ filas: [Fila]) -> some View {
        if filas.isEmpty {
            vacio.padding(.vertical, 36).frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(filas) { f in
                    fila(f)
                        // Divisor hairline desde donde empieza el texto, menos en la última.
                        .overlay(alignment: .bottom) {
                            if f.id != filas.last?.id {
                                Rectangle().fill(Color.gHairline).frame(height: 1).padding(.leading, 58)
                            }
                        }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
        }
    }

    /// Los vacíos de WhatsApp: ilustración, qué pasa y una acción.
    @ViewBuilder
    private var vacio: some View {
        let q = busqueda.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            VacioIlustrado(simbolo: "magnifyingglass", titulo: "Nada con «\(q)»",
                           texto: "Busca por el título, el agente o lo que se dijo.",
                           accion: "Borrar búsqueda") { withAnimation { busqueda = "" } }
        } else if soloFavoritos {
            VacioIlustrado(simbolo: "star.fill", titulo: "Añade a tu lista de favoritos",
                           texto: "Tus chats favoritos salen aquí para encontrarlos rápido.",
                           accion: "Elegir chats") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    soloFavoritos = false
                    seleccionando = true
                }
            }
        } else if let filtro, let agente = store.agents.first(where: { $0.id == filtro }) {
            VacioIlustrado(simbolo: "bubble.left.and.bubble.right.fill", titulo: "Todavía no hablas con \(agente.name)",
                           texto: "Pídeme algo y la conversación aparecerá aquí.",
                           accion: "Nueva conversación") { empezar(con: agente.id) }
        } else {
            VacioIlustrado(simbolo: "bubble.left.and.bubble.right.fill", titulo: "Empieza tu primera conversación",
                           texto: "Pídele a tu agente una cotización, un resumen o una tabla.",
                           accion: "Nueva conversación") { nueva = true }
        }
    }

    private func fila(_ f: Fila) -> some View {
        let elegida = seleccionando && seleccion.contains(f.llaveArchivo)
        return HStack(spacing: 10) {
            // Sólo el fantasma, sin aro ni fondo: como la foto de un contacto.
            // El fantasma solo, a su tamaño: dentro del círculo blanco de `AgentAvatar` se
            // dibujaba al 66 % y ese hueco invisible separaba mucho el título.
            GhostyMascot(tone: f.agente.tone, height: 54)
                .frame(width: 48, height: 58)
                // Seleccionada: la palomita verde sobre el avatar, como WhatsApp.
                .overlay(alignment: .bottomTrailing) {
                    if elegida {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Self.verde, in: Circle())
                            .overlay(Circle().stroke(Color.gBg, lineWidth: 1.5))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
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
                HStack(spacing: 6) {
                    subtitulo(f)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if fijadas.contains(f.llaveArchivo) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.gInk3)
                            .rotationEffect(.degrees(45))
                            .accessibilityLabel("Fijado")
                    }
                    if favoritas.contains(f.llaveArchivo) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Self.oro)
                            .accessibilityLabel("Favorito")
                    }
                    marca(f)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, Theme.Space.screenH)
        .background(elegida ? Color.gPrimaryRing : Color.clear)
        .padding(.horizontal, -Theme.Space.screenH)
        .contentShape(Rectangle())
        .onTapGesture {
            if seleccionando { alternarSeleccion(f) } else { abrir(f) }
        }
        // Mantener presionado entra al modo selección con esa fila elegida, como WhatsApp.
        // ⚠️ SIMULTÁNEO, no `onLongPressGesture`: ése compite con el scroll de la lista y lo
        // bloqueaba a ratos («hay que reintentar varias veces», 2026-09-29).
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { seleccionando = true }
                alternarSeleccion(f)
            }
        )
        .sensoryFeedback(.selection, trigger: seleccion)
        // Deslizar como WhatsApp: izquierda → Archivar; derecha → Leído/No leído y Fijar.
        .modifier(DeslizarChat(
            fijado: fijadas.contains(f.llaveArchivo),
            sinLeer: f.pendientes > 0,
            habilitado: !seleccionando,
            alArchivar: { porArchivar = f },
            alLeido: { alternarLeido(f) },
            alFijar: {
                ChatsFijados.alternar(f.llaveArchivo)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { fijadas = ChatsFijados.ids }
            }))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { abrir(f) }
        .accessibilityIdentifier(f.id)
    }

    /// La línea gris, como Android: «Espera tu permiso» (rojo) manda, luego «Trabajando…»
    /// (morado), lo último que se dijo («Tú: …»), o «No terminó» si falló. Con el filtro en
    /// Todos, empieza por el nombre del agente.
    private func subtitulo(_ f: Fila) -> some View {
        let (texto, color): (String, Color) = {
            if esperaPermiso(f) { return ("Espera tu permiso", .gDangerInk) }
            if trabajando(f) { return ("Trabajando…", .gPrimary) }
            if let p = f.previa { return ((p.deTi ? "Tú: " : "") + p.texto, .gInk3) }
            if fallo(f) { return ("No terminó", .gDangerInk) }
            return ("", .gInk3)
        }()
        let conAgente = filtro == nil && variosAgentes
        return (Text(conAgente ? f.agente.name + (texto.isEmpty ? "" : " · ") : "").foregroundColor(.gInk3)
                + Text(texto).foregroundColor(color))
            .font(.system(size: 14))
            .lineLimit(1)
    }

    private func fallo(_ f: Fila) -> Bool {
        switch f.tipo {
        case .abierta(let h): h.fallo != nil
        case .guardada(let s): s.ultimoTurno?.estado == "error"
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

    private func alternarSeleccion(_ f: Fila) {
        if seleccion.contains(f.llaveArchivo) { seleccion.remove(f.llaveArchivo) } else { seleccion.insert(f.llaveArchivo) }
    }

    /// Deslizar a la derecha → Leído / No leído.
    private func alternarLeido(_ f: Fila) {
        if f.pendientes > 0 { marcarLeida(f); return }
        switch f.tipo {
        case .abierta(let h):
            if h.termino == nil { h.termino = Date() }
            h.visto = false
            if let sid = h.sesionID { VistoHasta.marcar(f.agente.id, sid, .distantPast) }
        case .guardada(let s):
            VistoHasta.marcar(f.agente.id, s.id, .distantPast)
        }
        store.marcarLeidas()
    }

    private func marcarLeida(_ f: Fila) {
        switch f.tipo {
        case .abierta(let h):
            h.visto = true
            if let sid = h.sesionID { VistoHasta.marcar(f.agente.id, sid) }
        case .guardada(let s):
            VistoHasta.marcar(f.agente.id, s.id)
        }
        store.marcarLeidas()
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

    /// Agrupados por espacio: Tuyos → cada espacio (alfabético) → Compartidos contigo. Dentro,
    /// el orden que llega (último uso). Igual que Android.
    private var grupos: [(titulo: String, agentes: [Agent])] {
        var tuyos: [Agent] = [], compartidos: [Agent] = []
        var espacios: [String: [Agent]] = [:]
        for a in agentes {
            switch a.space?.kind {
            case .workspace?: espacios[a.space!.title, default: []].append(a)
            case .shared?: compartidos.append(a)
            default: if a.compartidoPor != nil { compartidos.append(a) } else { tuyos.append(a) }
            }
        }
        var r: [(String, [Agent])] = []
        if !tuyos.isEmpty { r.append(("Tuyos", tuyos)) }
        for k in espacios.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            r.append((k, espacios[k]!))
        }
        if !compartidos.isEmpty { r.append(("Compartidos contigo", compartidos)) }
        return r
    }

    private func fila(_ a: Agent) -> some View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nueva conversación")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.gInk)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let gs = grupos
                    ForEach(Array(gs.enumerated()), id: \.offset) { _, g in
                        // Encabezado sólo si hay más de un grupo (como Android).
                        if gs.count > 1 {
                            Text(g.titulo)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.gInk3)
                                .padding(EdgeInsets(top: 14, leading: 24, bottom: 4, trailing: 24))
                        }
                        ForEach(g.agentes) { a in
                            fila(a)
                                .overlay(alignment: .bottom) {
                                    // Hairline desde donde empieza el nombre, entre agentes del grupo.
                                    if a.id != g.agentes.last?.id {
                                        Rectangle().fill(Color.gHairline).frame(height: 1).padding(.leading, 82)
                                    }
                                }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color.gBg)
    }
}


/// Un vacío estilo WhatsApp: libreta lila con contorno oscuro, la hoja de atrás girada y un
/// sello morado con el icono. Luego el título, qué pasa y la acción en texto de marca.
struct VacioIlustrado: View {
    let simbolo: String
    let titulo: String
    let texto: String
    let accion: String
    var alTocar: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: 0xAEADEF))
                    .frame(width: 92, height: 112)
                    .rotationEffect(.degrees(10))
                    .offset(x: 14, y: -4)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: 0xF5F5FC))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(hex: 0x191A20), lineWidth: 3))
                    .overlay(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(0..<3, id: \.self) { i in
                                Capsule().fill(Color(hex: 0xAEADEF)).frame(width: i == 2 ? 30 : 48, height: 5)
                            }
                        }
                        .padding(.leading, 16)
                    }
                    .frame(width: 92, height: 112)
                Circle()
                    .fill(Color.gPrimary)
                    .frame(width: 46, height: 46)
                    .overlay(Circle().stroke(Color(hex: 0x191A20), lineWidth: 3))
                    .overlay { Image(systemName: simbolo).font(.system(size: 18, weight: .bold)).foregroundStyle(.white) }
                    .offset(x: 40, y: 44)
            }
            .frame(height: 150)
            .padding(.bottom, 6)
            Text(titulo)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.gInk)
                .multilineTextAlignment(.center)
            Text(texto)
                .font(.system(size: 15))
                .foregroundStyle(Color.gInk2)
                .multilineTextAlignment(.center)
            Button(accion, action: alTocar)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.gPrimary)
                .padding(.top, 4)
        }
        .frame(maxWidth: 300)
        .gIn()
    }
}

/// El menú de la app (⋯): tarjeta blanca, radio 18, borde fino y sombra. No el nativo:
/// así se ve igual que en Android.
struct MenuDeGhosty: View {
    struct Opcion: Identifiable {
        let titulo: String
        let simbolo: String
        var destructiva = false
        let hacer: () -> Void
        var id: String { titulo }
    }
    let opciones: [Opcion]
    var cerrar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(opciones) { o in
                Button {
                    cerrar()
                    o.hacer()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: o.simbolo).font(.system(size: 17)).frame(width: 24)
                        Text(o.titulo).font(.system(size: 16))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(o.destructiva ? Color.gDanger : Color.gInk)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gFill))
            }
        }
        .padding(.vertical, 6)
        .frame(width: 240)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.gSeparator, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

/// Avisa cuánto se desplazó un ScrollView (iOS 18+: `onScrollGeometryChange`, lo nativo).
private struct SeguirDesplazamiento: ViewModifier {
    var alCambiar: (CGFloat) -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentOffset.y + g.contentInsets.top
            } action: { _, y in alCambiar(y) }
        } else {
            content.onPreferenceChange(FondoDelTitulo.self) { maxY in alCambiar(maxY < 4 ? 100 : 0) }
        }
    }
}

/// Los chats fijados arriba, por `agente/sesión`. En el teléfono.
enum ChatsFijados {
    private static let clave = "app.chats.fijadas"
    static var ids: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: clave) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: clave) }
    }
    static func alternar(_ id: String) {
        var s = ids
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        ids = s
    }
}

/// Deslizar una fila de Chats como WhatsApp. Izquierda: Archivar. Derecha: Leído / No leído
/// y Fijar. Sólo se lleva el arrastre HORIZONTAL (|dx| > |dy|): no le roba el scroll a la
/// lista, y la fila gana sobre el pager de pestañas (medido en el simulador).
private struct DeslizarChat: ViewModifier {
    let fijado: Bool
    let sinLeer: Bool
    let habilitado: Bool
    var alArchivar: () -> Void
    var alLeido: () -> Void
    var alFijar: () -> Void

    @State private var dx: CGFloat = 0
    /// -1 = abierta a la izquierda (Archivar) · 1 = abierta a la derecha · 0 = cerrada.
    @State private var lado = 0
    private let boton: CGFloat = 78

    func body(content: Content) -> some View {
        ZStack {
            if lado == 1 || dx > 0 {
                HStack(spacing: 0) {
                    accion(sinLeer ? "Leído" : "No leído",
                           sinLeer ? "checkmark.message.fill" : "message.badge.filled.fill", Color.gPrimary, alLeido)
                    accion(fijado ? "Desfijar" : "Fijar", fijado ? "pin.slash.fill" : "pin.fill", Color.gInk3, alFijar)
                    Spacer(minLength: 0)
                }
            }
            if lado == -1 || dx < 0 {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    accion("Archivar", "archivebox.fill", Color.gDark, alArchivar)
                }
            }
            content
                .background(Color.gBg)
                .offset(x: dx)
                .allowsHitTesting(lado == 0)
            if lado != 0 {
                // Con la fila abierta, tocarla la cierra.
                Color.clear.contentShape(Rectangle())
                    .padding(.leading, lado == 1 ? boton * 2 : 0)
                    .padding(.trailing, lado == -1 ? boton : 0)
                    .onTapGesture { cerrar() }
            }
        }
        .clipped()
        .panHorizontal(alCambiar: { tx in
            guard habilitado else { return }
            let base: CGFloat = lado == -1 ? -boton : lado == 1 ? boton * 2 : 0
            dx = min(boton * 2 + 20, max(-boton - 20, base + tx))
        }, alTerminar: { tx in
            guard habilitado else { return }
            let fin = (lado == -1 ? -boton : lado == 1 ? boton * 2 : 0) + tx
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if fin < -50 { lado = -1; dx = -boton }
                else if fin > 60 { lado = 1; dx = boton * 2 }
                else { lado = 0; dx = 0 }
            }
        })
        .accessibilityAction(named: "Archivar", alArchivar)
        .accessibilityAction(named: sinLeer ? "Marcar como leído" : "Marcar como no leído", alLeido)
        .accessibilityAction(named: fijado ? "Desfijar" : "Fijar", alFijar)
        .sensoryFeedback(.impact(weight: .light), trigger: lado)
    }

    private func accion(_ titulo: String, _ simbolo: String, _ color: Color, _ hacer: @escaping () -> Void) -> some View {
        Button {
            cerrar()
            hacer()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: simbolo).font(.system(size: 18, weight: .semibold))
                Text(titulo).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: boton)
            .frame(maxHeight: .infinity)
            .background(color)
        }
        .buttonStyle(.plain)
    }

    private func cerrar() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { lado = 0; dx = 0 }
    }
}
