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

    @State private var filtro: Filtro = .todos
    /// La fila abierta: enseña su vista previa o su reproductor (`EntregaCard`).
    @State private var abierta: String?
    @Namespace private var pildora
    @Environment(\.openURL) private var abrir

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Archivos").gScreenTitle()
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)
                Text("Lo que subiste y lo que Ghosty generó.")
                    .gScreenSubtitle()
                    .padding(.horizontal, 2)
                    .padding(.bottom, 18)

                filtros.padding(.bottom, 14)

                avisoDeBorrado

                lista

                if filtro == .todos, store.puedeVerArchivos {
                    almacenDeEasyBits.padding(.top, 22)
                }
            }
            .padding(.horizontal, Theme.Space.screenH)
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
    }

    // MARK: - Filtros

    private var filtros: some View {
        HStack(spacing: 6) {
            ForEach(Filtro.allCases) { f in
                let activo = filtro == f
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        filtro = f
                        abierta = nil
                    }
                } label: {
                    Text(f.nombre)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(activo ? Color.white : Color.gInk2)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 13)
                        .background {
                            if activo {
                                Capsule().fill(Color.gDark)
                                    .matchedGeometryEffect(id: "filtro", in: pildora)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.gPressPill)
                .accessibilityAddTraits(activo ? .isSelected : [])
                .accessibilityIdentifier(f.identificador)
            }
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
            .padding(.bottom, 14)
            .transition(.gIn)
        }
    }

    // MARK: - La lista

    /// Lo entregado y lo subido a la CUENTA (gs `/me/files`) más lo que llegó en vivo a
    /// este teléfono y gs todavía no tiene, sin repetir.
    @ViewBuilder
    private var lista: some View {
        let todo = store.artifactsList(for: store.selectedAgentID)
        let visibles = todo.filter { e in
            switch filtro {
            case .todos: true
            case .generados: e.generada
            case .subidos: !e.generada
            }
        }
        if visibles.isEmpty {
            vacio(hayAlgo: !todo.isEmpty)
                .padding(.top, 40)
                .transition(.opacity)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(visibles.enumerated()), id: \.element.id) { i, e in
                    fila(e, ultima: i == visibles.count - 1)
                        .gIn(delay: min(Double(i), 8) * 0.03)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
            .background(Color.gCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.list, style: .continuous))
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: filtro)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: abierta)
        }
    }

    private func fila(_ e: Entrega, ultima: Bool) -> some View {
        let abiertaAhora = abierta == e.id
        return VStack(spacing: 0) {
            Button {
                abierta = abiertaAhora ? nil : e.id
            } label: {
                HStack(spacing: 12) {
                    InsigniaDeArchivo(ext: Self.etiqueta(e))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.titulo)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.gInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Self.meta(e))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.gInk3)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gChevron)
                        .rotationEffect(.degrees(abiertaAhora ? 180 : 0))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(GhostyPressStyle(scale: 1, pressedBackground: .gCardPressed))
            .accessibilityIdentifier("archivo-\(e.id)")

            if abiertaAhora {
                // La vista previa, el reproductor o la portada del PDF: lo de siempre.
                EntregaCard(entrega: e)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                    .transition(.gIn)
            }
        }
        .ghostySeparator(inset: ultima ? .infinity : 0)
        .borrarConToqueLargo("¿Borrar «\(e.titulo)»?",
                             consecuencia: e.remotoID != nil
                                ? "Se borra de tu cuenta: deja de verse en el teléfono, la Mac y la web."
                                : "Se quita de aquí y de la conversación donde te la entregó. Vive sólo en este teléfono.") {
            Task { await store.deleteAccountFile(e) }
        }
    }

    @ViewBuilder
    private func vacio(hayAlgo: Bool) -> some View {
        switch filtro {
        case .todos:
            EmptyState(icon: "tray", title: "Todavía nada",
                       detail: "Lo que subas o te entregue Ghosty —un PDF, una tabla, una foto— se queda aquí.")
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
        var partes = [e.generada ? "Generado" : "Subido", cuando(e.recibida)]
        if let peso = e.peso { partes.append(peso) }
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
