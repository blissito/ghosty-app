import AVKit
import AVFoundation
import SwiftUI

/// Archivos: lo que subiste y lo que Ghosty generó (diseño de Brenda, 2026-09).
///
/// ⚠️ **Es de la cuenta, no del agente**. El modelo `File` no guarda `agentId` de forma
/// fiable y los artefactos se atribuyen al DUEÑO, así que filtrar por agente sería
/// inventar un dato que no existe. Por eso aquí no hay cabecera de agente.
///
/// La pestaña está SIEMPRE: vacía explica qué va a caer ahí.
struct ArtifactsView: View {
    let store: LiveAgentStore

    /// Los filtros del diseño. «Generados» = lo que entregó un agente (`origen == "agente"`
    /// o llegado en vivo por el relé); «Subidos» = lo que subió la persona.
    enum Filtro: String, CaseIterable, Identifiable {
        case todos, generados, subidos
        var id: String { rawValue }
        var nombre: String {
            switch self {
            case .todos: "Todos"
            case .generados: "Generados"
            case .subidos: "Subidos"
            }
        }
        /// El id de accesibilidad: `filtro-todo` se conserva del filtro viejo (UI tests).
        var identificador: String { self == .todos ? "filtro-todo" : "filtro-\(rawValue)" }
    }

    /// Segundo filtro, como la galería de un chat de WhatsApp («Multimedia, enlaces y
    /// documentos»): multimedia en cuadrícula, documentos en renglones, audio con reproductor.
    enum Pestana: String, CaseIterable, Identifiable {
        case multimedia, documentos, audio
        var id: String { rawValue }
        var nombre: String {
            switch self {
            case .multimedia: "Multimedia"
            case .documentos: "Documentos"
            case .audio: "Audio"
            }
        }
        static func de(_ e: Entrega) -> Pestana {
            switch e.categoria {
            case .imagen, .video: .multimedia
            case .audio: .audio
            default: .documentos
            }
        }
    }

    @State private var filtro: Filtro = .todos
    /// Filtro por agente (`nil` = todos). Se combina con el origen y las pestañas.
    @State private var agenteElegido: String?
    /// `nil` = la primera pestaña que tenga algo.
    @State private var pestanaElegida: Pestana?
    /// La fila de documento abierta: enseña su vista previa (`EntregaCard`).
    @State private var abierta: String?
    /// El video que se está mirando (hoja con su reproductor).
    @State private var mirandoVideo: Entrega?
    @Namespace private var subrayado
    @Environment(\.openURL) private var abrir
    @Environment(Visor.self) private var visor: Visor?

    /// Todo lo de la cuenta menos TUS notas de voz: ésas son la conversación, no archivos.
    /// Nota tuya = audio que no entregó un agente y trae duración o se llama «nota-de-voz…»
    /// (las que sube iOS no traen `meta.segundos`). La misma regla que Android.
    private var archivos: [Entrega] {
        store.artifactsList(for: store.selectedAgentID).filter { e in
            guard e.categoria == .audio, !e.generada else { return true }
            let n = e.titulo.lowercased()
            return !(e.segundosDeVoz != nil || n.hasPrefix("nota-de-voz") || n.hasPrefix("nota de voz"))
        }
        .sorted { $0.recibida > $1.recibida }
    }

    /// De qué agente es: el que dice gs o, si no, el dueño de la conversación donde nació.
    private func agenteDe(_ e: Entrega) -> String? {
        if !e.agentID.isEmpty { return e.agentID }
        guard let sid = e.sesionID else { return nil }
        return store.canales.first { _, c in
            c.hilosRemotos.contains { $0.id == sid } || c.hilos.contains { $0.sesionID == sid }
        }?.key
    }

    var body: some View {
        let conAgente = archivos.map { ($0, agenteDe($0)) }
        let agentesConArchivos = store.agents.filter { a in conAgente.contains { $0.1 == a.id } }
        let base = porOrigen(conAgente.filter { agenteElegido == nil || $0.1 == agenteElegido }.map(\.0))
        let conteo = Dictionary(grouping: base, by: Pestana.de).mapValues(\.count)
        let pestana = pestanaElegida ?? Pestana.allCases.first { (conteo[$0] ?? 0) > 0 } ?? .multimedia
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Archivos").gScreenTitle()
                    .padding(.horizontal, Theme.Space.screenH + 2)
                    .padding(.bottom, 12)

                filtros(agentes: agentesConArchivos).padding(.bottom, 4)
                pestanas(conteo: conteo, actual: pestana)

                avisoDeBorrado.padding(.horizontal, Theme.Space.screenH).padding(.top, 10)

                lista(base.filter { Pestana.de($0) == pestana }, pestana: pestana, hayAlgo: !archivos.isEmpty)

                if filtro == .todos, store.puedeVerArchivos {
                    almacenDeEasyBits
                        .padding(.horizontal, Theme.Space.screenH)
                        .padding(.top, 22)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .task(id: store.selectedAgentID) {
            async let cuenta: Void = store.loadAccountFiles()
            await store.cargarArchivos()
            await cuenta
        }
        .refreshable { await store.loadAccountFiles() }
        .fullScreenCover(item: $mirandoVideo) { e in
            VideoAPantallaCompleta(entrega: e)
        }
    }

    // MARK: - Filtros

    /// De dónde salió y de qué agente: los chips de «Chats» en una fila, con un filete
    /// entre los de origen y los de agente. Sólo salen agentes con archivos.
    private func filtros(agentes: [Agent]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filtro.allCases) { f in
                    chipDeFiltro(f.nombre, activo: filtro == f, id: f.identificador) {
                        filtro = f
                    } icono: { EmptyView() }
                }
                if agentes.count > 1 {
                    Rectangle().fill(Color.gSeparator).frame(width: 1, height: 20)
                    ForEach(agentes) { a in
                        chipDeFiltro(a.name, activo: agenteElegido == a.id, id: "archivos-agente-\(a.id)") {
                            agenteElegido = agenteElegido == a.id ? nil : a.id
                        } icono: { AgentAvatar(tone: a.tone, size: 24) }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.vertical, 6)
        }
    }

    private func chipDeFiltro<I: View>(_ titulo: String, activo: Bool, id: String,
                                       accion: @escaping () -> Void, @ViewBuilder icono: () -> I) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                accion()
                abierta = nil
            }
        } label: {
            HStack(spacing: 6) {
                icono()
                Text(titulo).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(activo ? Color.gPrimary : Color.gInk2)
            .padding(.leading, I.self == EmptyView.self ? 16 : 6).padding(.trailing, 16)
            .frame(height: 36)
            .background(activo ? ChatsView.chipActivo : Color.gCard, in: Capsule())
            .overlay(Capsule().strokeBorder(activo ? ChatsView.chipBorde : Color.gSeparator, lineWidth: 1.2))
            .contentShape(Capsule())
        }
        .buttonStyle(.gPressPill)
        .accessibilityAddTraits(activo ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    /// Segundo nivel, más ligero: texto que se subraya en la marca, como las pestañas de
    /// WhatsApp, con cuántos hay.
    private func pestanas(conteo: [Pestana: Int], actual: Pestana) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Pestana.allCases) { t in
                    let activa = t == actual
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            pestanaElegida = t
                            abierta = nil
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Text(t.nombre + ((conteo[t] ?? 0) > 0 ? " \(conteo[t]!)" : ""))
                                .font(.system(size: 14, weight: activa ? .semibold : .medium))
                                .foregroundStyle(activa ? Color.gPrimary : Color.gInk2)
                                .contentTransition(.numericText())
                            ZStack {
                                if activa {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.gPrimary)
                                        .matchedGeometryEffect(id: "subrayado", in: subrayado)
                                }
                            }
                            .frame(height: 3)
                            .padding(.horizontal, 18)
                        }
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(activa ? .isSelected : [])
                    .accessibilityIdentifier("pestana-\(t.rawValue)")
                }
            }
            .padding(.horizontal, 8)
            Rectangle().fill(Color.gSeparator).frame(height: 1)
        }
    }

    /// Lo último que falló al borrar. ⚠️ Se enseña: un borrado que no se hizo y no se dice
    /// es la peor variante del fallo mudo — te deja creer que el archivo ya no está.
    @ViewBuilder
    private var avisoDeBorrado: some View {
        if let fallo = store.falloAlBorrar {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.gDangerInk)
                Text(fallo).gMeta().foregroundStyle(Color.gDangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { store.falloAlBorrar = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gDangerInk)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.gDangerTint,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .transition(.gIn)
        }
    }

    private func porOrigen(_ todo: [Entrega]) -> [Entrega] {
        todo.filter { e in
            switch filtro {
            case .todos: true
            case .generados: e.generada
            case .subidos: !e.generada
            }
        }
    }

    // MARK: - La lista

    /// Agrupada por mes («Este mes», «Agosto 2026»), como la galería de WhatsApp.
    @ViewBuilder
    private func lista(_ visibles: [Entrega], pestana: Pestana, hayAlgo: Bool) -> some View {
        if archivos.isEmpty, store.accountFilesEsperando, !DemoData.encendido {
            // Sólo la primera vez, sin nada en disco: con caché la lista sale al instante.
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .transition(.opacity)
        } else if visibles.isEmpty {
            vacio(pestana: pestana)
                .padding(.top, 40)
                .transition(.opacity)
        } else {
            let meses = Self.porMes(visibles)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(meses, id: \.titulo) { mes in
                    Text(mes.titulo)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gInk3)
                        .padding(.horizontal, Theme.Space.screenH)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                    switch pestana {
                    case .multimedia:
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                            ForEach(mes.entregas) { e in cuadro(e) }
                        }
                    case .documentos:
                        ForEach(mes.entregas) { e in
                            filaDeDocumento(e).overlay(alignment: .bottom) { if e.id != mes.entregas.last?.id { divisor } }
                        }
                    case .audio:
                        ForEach(mes.entregas) { e in
                            filaDeAudio(e).overlay(alignment: .bottom) {
                                if e.id != mes.entregas.last?.id {
                                    Rectangle().fill(Color.gHairline).frame(height: 1).padding(.leading, 62)
                                }
                            }
                        }
                    }
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: filtro)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: pestana)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: abierta)
        }
    }

    /// Hairline que empieza donde empieza el texto (72), como WhatsApp.
    private var divisor: some View {
        Rectangle().fill(Color.gHairline).frame(height: 1).padding(.leading, 72)
    }

    static func porMes(_ entregas: [Entrega], ahora: Date = Date()) -> [(titulo: String, entregas: [Entrega])] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "MMMM yyyy"
        var orden: [String] = []
        var grupos: [String: [Entrega]] = [:]
        for e in entregas {
            let t = cal.isDate(e.recibida, equalTo: ahora, toGranularity: .month)
                ? "Este mes" : f.string(from: e.recibida).capitalized(with: Locale(identifier: "es_MX"))
            if grupos[t] == nil { orden.append(t) }
            grupos[t, default: []].append(e)
        }
        return orden.map { ($0, grupos[$0]!) }
    }

    /// Cuadro de la cuadrícula: la foto recortada (abre el visor) o el video con su ▶.
    private func cuadro(_ e: Entrega) -> some View {
        MiniaturaDeEntrega(entrega: e) { img in
            // Foto: el visor sólo si ya cargó (un toque temprano no hace nada). Video: dentro
            // de la app, a pantalla completa.
            if e.categoria == .video { mirandoVideo = e }
            else if let img { visor?.abrir(img, titulo: e.titulo) }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityIdentifier("archivo-\(e.id)")
        .borrarConToqueLargo("¿Borrar «\(e.titulo)»?", consecuencia: Self.consecuencia(e)) {
            Task { await store.deleteAccountFile(e) }
        }
    }

    /// Renglón de documento: insignia de color con la sigla, nombre y «Generado · 84 KB · 12 sep».
    /// Tocar abre su vista previa (la tarjeta de siempre: tocarla lo abre en el visor).
    private func filaDeDocumento(_ e: Entrega) -> some View {
        let abiertaAhora = abierta == e.id
        return VStack(spacing: 0) {
            Button {
                abierta = abiertaAhora ? nil : e.id
            } label: {
                HStack(spacing: 14) {
                    InsigniaDeGaleria(ext: Self.etiqueta(e))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.titulo)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.gInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Self.meta(e))
                            .font(.system(size: 14))
                            .foregroundStyle(Color.gInk3)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, Theme.Space.screenH)
                .contentShape(Rectangle())
            }
            .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gCardPressed))
            .accessibilityIdentifier("archivo-\(e.id)")

            if abiertaAhora {
                EntregaCard(entrega: e)
                    .padding(.horizontal, Theme.Space.screenH)
                    .padding(.bottom, 12)
                    .transition(.gIn)
            }
        }
        .borrarConToqueLargo("¿Borrar «\(e.titulo)»?", consecuencia: Self.consecuencia(e)) {
            Task { await store.deleteAccountFile(e) }
        }
    }

    /// Renglón de audio como una nota de WhatsApp: [micrófono] [▶] [onda] [duración] y
    /// debajo, alineada con el play, «nombre · Generado · tamaño · fecha».
    private func filaDeAudio(_ e: Entrega) -> some View {
        FilaDeAudio(entrega: e, detalle: Self.meta(e))
            .padding(.horizontal, Theme.Space.screenH - 4)
            .padding(.vertical, 8)
            .accessibilityIdentifier("archivo-\(e.id)")
            .borrarConToqueLargo("¿Borrar «\(e.titulo)»?", consecuencia: Self.consecuencia(e)) {
                Task { await store.deleteAccountFile(e) }
            }
    }

    private static func consecuencia(_ e: Entrega) -> String {
        e.remotoID != nil
            ? "Se borra de tu cuenta: deja de verse en el teléfono, la Mac y la web."
            : "Se quita de aquí y de la conversación donde te la entregó. Vive sólo en este teléfono."
    }

    @ViewBuilder
    private func vacio(pestana: Pestana) -> some View {
        switch filtro {
        case .todos:
            EmptyState(icon: pestana == .multimedia ? "photo.on.rectangle" : pestana == .audio ? "waveform" : "doc.text",
                       title: pestana == .multimedia ? "Sin fotos ni videos" : pestana == .audio ? "Sin audios" : "Sin documentos",
                       detail: "Lo que subas o te entregue Ghosty —un PDF, una tabla, una foto— se queda aquí. Desliza hacia abajo para actualizar.")
        case .generados:
            EmptyState(icon: "sparkles", title: "Nada generado aún",
                       detail: "Pídele a Ghosty una cotización, un resumen o una tabla y aparecerá aquí.")
        case .subidos:
            EmptyState(icon: "arrow.up.doc", title: "No has subido nada",
                       detail: "Lo que adjuntes en el chat se guarda aquí.")
        }
    }

    // MARK: - El almacén de EasyBits (cuentas con llave de cuenta)

    /// Lo que vive en EasyBits. Sólo lo ve un agente con llave de cuenta; se conserva con
    /// la misma fila del diseño.
    @ViewBuilder
    private var almacenDeEasyBits: some View {
        switch store.estadoArchivos {
        case .listo where !store.documentos.isEmpty || !store.archivos.isEmpty:
            VStack(alignment: .leading, spacing: 8) {
                Text("En EasyBits").gSectionCaps().padding(.horizontal, 4)
                VStack(spacing: 0) {
                    let docs = store.documentos
                    let files = store.archivos
                    ForEach(Array(docs.enumerated()), id: \.element.id) { i, d in
                        Button {
                            if let t = d.shareUrl ?? d.pdfUrl, let u = URL(string: t) { abrir(u) }
                        } label: {
                            filaSimple(ext: "DOC",
                                       titulo: d.name?.isEmpty == false ? d.name! : "Sin título",
                                       meta: detalleDoc(d))
                        }
                        .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gCardPressed))
                        .ghostySeparator(inset: i == docs.count - 1 && files.isEmpty ? .infinity : 0)
                    }
                    ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                        Button {
                            Task { if let u = await store.ligaDeArchivo(f.id) { abrir(u) } }
                        } label: {
                            filaSimple(ext: Self.etiqueta(mime: f.contentType, nombre: f.name ?? ""),
                                       titulo: f.name ?? f.id, meta: detalleArchivo(f))
                        }
                        .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gCardPressed))
                        // ⚠️ Éste es el borrado que de verdad quita bytes del almacenamiento
                        // de la cuenta. Se dice antes de hacerlo.
                        .borrarConToqueLargo("¿Borrar «\(f.name ?? f.id)»?",
                                             consecuencia: "Se borra del almacenamiento de tu cuenta. Las conversaciones que lo mencionen dejarán de poder abrirlo.") {
                            Task { await store.borrarArchivo(f.id) }
                        }
                        .ghostySeparator(inset: i == files.count - 1 ? .infinity : 0)
                    }
                }
                .background(Color.gCard)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.list, style: .continuous))
            }
        case .fallo(let d):
            HStack(spacing: 8) {
                Text("No pude traer lo de EasyBits: \(d)").gCaption()
                Button("Reintentar") { Task { await store.cargarArchivos() } }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.gPrimary)
            }
        default:
            EmptyView()
        }
    }

    private func filaSimple(ext: String, titulo: String, meta: String) -> some View {
        HStack(spacing: 12) {
            InsigniaDeArchivo(ext: ext)
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gInk).lineLimit(1)
                Text(meta).font(.system(size: 12)).foregroundStyle(Color.gInk3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.gChevron)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    // MARK: - Formato

    /// La insignia: PDF, XLS, IMG o el sufijo del archivo.
    static func etiqueta(_ e: Entrega) -> String {
        etiqueta(ext: e.tipo ?? "")
    }

    static func etiqueta(mime: String?, nombre: String) -> String {
        if let mime, let ext = Entrega.`extension`(porMime: mime) { return etiqueta(ext: ext) }
        if mime?.hasPrefix("image/") == true { return "IMG" }
        let ext = nombre.split(separator: ".").count > 1 ? String(nombre.split(separator: ".").last!) : ""
        return etiqueta(ext: ext)
    }

    static func etiqueta(ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "PDF"
        case "xls", "xlsx", "csv", "numbers": return "XLS"
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "IMG"
        case "": return "ARCH"
        case let otro: return String(otro.prefix(4)).uppercased()
        }
    }

    /// «Generado · hoy, 8:01 · 84 KB», «Subido · ayer · 1.2 MB», «Subido · lun · 340 KB».
    static func meta(_ e: Entrega) -> String {
        var partes = [e.generada ? "Generado" : "Subido"]
        if let peso = e.peso { partes.append(peso) }
        let es = Locale(identifier: "es_MX")
        partes.append(e.recibida.formatted(.dateTime.day().month(.abbreviated).locale(es)).replacingOccurrences(of: ".", with: ""))
        return partes.joined(separator: " · ")
    }

    static func cuando(_ fecha: Date, ahora: Date = Date()) -> String {
        let cal = Calendar.current
        let hora = fecha.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
                                     .locale(Locale(identifier: "es_MX")))
        if cal.isDateInToday(fecha) { return "hoy, \(hora)" }
        if cal.isDateInYesterday(fecha) { return "ayer" }
        let dias = cal.dateComponents([.day], from: cal.startOfDay(for: fecha),
                                      to: cal.startOfDay(for: ahora)).day ?? 99
        let es = Locale(identifier: "es_MX")
        if dias < 7 {
            return fecha.formatted(.dateTime.weekday(.abbreviated).locale(es))
                .replacingOccurrences(of: ".", with: "").lowercased()
        }
        return fecha.formatted(.dateTime.day().month(.abbreviated).locale(es))
            .replacingOccurrences(of: ".", with: "")
    }

    private func detalleDoc(_ d: EasyBitsClient.RemoteDocument) -> String {
        var partes: [String] = []
        if let p = d.pageCount { partes.append(p == 1 ? "1 página" : "\(p) páginas") }
        if let s = d.status { partes.append(s == "DRAFT" ? "borrador" : s.lowercased()) }
        if (d.shareUrl ?? d.pdfUrl) == nil { partes.append("sin publicar") }
        return partes.joined(separator: " · ")
    }

    private func detalleArchivo(_ f: EasyBitsClient.RemoteFile) -> String {
        var partes: [String] = []
        if let s = f.size { partes.append(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)) }
        if f.access == "private" { partes.append("privado") }
        return partes.joined(separator: " · ")
    }
}

/// La insignia de tipo del diseño: 34×40, radio 7, la sigla abajo en mono 700 9.
/// PDF rojo, XLS verde, IMG morado; lo demás neutro.
struct InsigniaDeArchivo: View {
    let ext: String

    private var colores: (fondo: Color, tinta: Color) {
        switch ext {
        case "PDF": (.gDangerTint, .gDanger)
        case "XLS": (.gGreenTint, .gGreen)
        case "IMG": (.gPrimaryTint, .gPrimary)
        default:    (.gFill, .gInk2)
        }
    }

    var body: some View {
        Text(ext)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(colores.tinta)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.bottom, 5)
            .frame(width: 34, height: 40, alignment: .bottom)
            .background(colores.fondo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Estado vacío honesto. Las secciones que no existen se dicen, no se disfrazan.
struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.gInk4)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.gInk2)
            Text(detail).gMeta().multilineTextAlignment(.center)
        }
        .frame(maxWidth: 280)
        .frame(maxWidth: .infinity)
        .gIn()
    }
}

/// La insignia de la galería: 42×50, radio 8, la sigla en blanco. PDF rojo, hojas verde,
/// textos morado; lo demás gris.
struct InsigniaDeGaleria: View {
    let ext: String

    private var color: Color {
        switch ext {
        case "PDF": .gDanger
        case "XLS", "XLSX", "CSV": .gGreen
        case "DOC", "DOCX", "MD", "TXT": .gPrimary
        default: .gInk3
        }
    }

    var body: some View {
        Text(ext)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 42, height: 50)
            .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Un cuadro de la cuadrícula de Multimedia: la foto recortada, o el video con su ▶.
/// Baja los bytes al aparecer y los guarda en `MiniaturasEnMemoria`.
struct MiniaturaDeEntrega: View {
    let entrega: Entrega
    /// Tocar: con la imagen si la hay (abre el visor); `nil` si es un video.
    var alTocar: (UIImage?) -> Void

    @State private var imagen: UIImage?

    private var clave: String { "entrega:" + (entrega.remotoID ?? entrega.id) }

    var body: some View {
        Color.gFill
            .overlay {
                if let imagen {
                    Image(uiImage: imagen).resizable().scaledToFill()
                } else if entrega.categoria == .video {
                    ZStack {
                        Color.gDark
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.2), in: Circle())
                    }
                } else {
                    Image(systemName: "photo").foregroundStyle(Color.gInk4)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { alTocar(imagen) }
            .task(id: entrega.id) { await cargar() }
    }

    private func cargar() async {
        guard entrega.categoria == .imagen else { return }
        if let ya = MiniaturasEnMemoria.imagen(clave) { imagen = ya; return }
        var d = entrega.datos
        if d == nil, let id = entrega.remotoID { d = try? await GhostyAPI.bajar(id) }
        if d == nil, let s = entrega.url, let u = URL(string: s) { d = await Descargas.bytes(u) }
        guard let d, let img = UIImage(data: d) else { return }
        MiniaturasEnMemoria.guardar(img, clave: clave)
        imagen = img
    }
}

/// Un audio de Archivos. La duración no viene en `/me/files`: se lee del archivo UNA vez
/// (AVURLAsset sobre la URL firmada) y se guarda por id; mientras no se sabe, va vacía.
struct FilaDeAudio: View {
    let entrega: Entrega
    let detalle: String
    @State private var segundos: Double = 0

    private var id: String { entrega.remotoID ?? entrega.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BurbujaDeVoz(id: id, lado: .agente, segundos: segundos, onda: entrega.onda ?? [], tiempoAlFinal: true) {
                if let d = entrega.datos { return d }
                var d: Data?
                if let rid = entrega.remotoID { d = try? await GhostyAPI.bajar(rid) }
                if d == nil, let s = entrega.url, let u = URL(string: s) { d = await Descargas.bytes(u) }
                guard let d else { throw GhostyAPI.Fallo.mensaje("Ese audio ya no está.") }
                return d
            }
            Text("\(entrega.titulo) · \(detalle)")
                .font(.system(size: 13))
                .foregroundStyle(Color.gInk3)
                .lineLimit(1)
                .truncationMode(.tail)
                // Alineada con el play: micrófono (46) + espacio (10).
                .padding(.leading, 56)
        }
        .task(id: id) { await cargarDuracion() }
    }

    private func cargarDuracion() async {
        if let s = entrega.segundosDeVoz, s > 0 { segundos = s; return }
        if let s = DuracionesDeAudio.de(id) { segundos = s; return }
        var url: URL?
        if let rid = entrega.remotoID, let s = try? await GhostyAPI.urlDe(rid) { url = URL(string: s) }
        if url == nil, let s = entrega.url { url = URL(string: s) }
        guard let url, let d = try? await AVURLAsset(url: url).load(.duration) else { return }
        let s = CMTimeGetSeconds(d)
        guard s.isFinite, s > 0 else { return }
        DuracionesDeAudio.guardar(id, s)
        segundos = s
    }
}

/// Cuánto dura cada audio de la cuenta, por id: se mide una vez y ya.
enum DuracionesDeAudio {
    private static let clave = "ghosty.duracionesDeAudio"
    static func de(_ id: String) -> Double? {
        UserDefaults.standard.dictionary(forKey: clave)?[id] as? Double
    }
    static func guardar(_ id: String, _ s: Double) {
        var d = UserDefaults.standard.dictionary(forKey: clave) ?? [:]
        d[id] = s
        if d.count > 1000 { d.removeValue(forKey: d.keys.first!) }
        UserDefaults.standard.set(d, forKey: clave)
    }
}

/// Un video de Archivos a pantalla completa: fondo negro, el reproductor del sistema y una
/// X blanca arriba a la izquierda, como Android.
struct VideoAPantallaCompleta: View {
    let entrega: Entrega
    @Environment(\.dismiss) private var cerrar
    @State private var player: AVPlayer?
    @State private var fallo: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
                    .onAppear { player.play() }
            } else if let fallo {
                Text(fallo).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { player?.pause(); cerrar() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.leading, 8)
            .accessibilityLabel("Cerrar")
        }
        .task {
            var url: URL?
            if let rid = entrega.remotoID, let s = try? await GhostyAPI.urlDe(rid) { url = URL(string: s) }
            if url == nil, let s = entrega.url { url = URL(string: s) }
            if let url {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                player = AVPlayer(url: url)
            } else { fallo = "No pude abrir el video." }
        }
    }
}
