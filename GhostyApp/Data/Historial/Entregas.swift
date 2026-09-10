import Foundation
import Observation

/// Algo que el agente ENTREGÓ: un archivo suyo o un artefacto que escribió.
///
/// Llega por la notificación `ghosty/artifact` del relé, en el mismo socket del turno,
/// cuando el agente usa `entregar_archivo` o `crear_artefacto`. Sin eso, lo que escribe
/// se queda en el disco de su máquina y no lo ve nadie — que es exactamente lo que
/// pasaba hasta ahora en el teléfono.
///
/// ⚠️ Se guarda AQUÍ porque la entrega es un empujón, no un estado consultable: el relé
/// la manda una vez, en vivo, y no hay endpoint que la vuelva a dar. Un `session/load`
/// devuelve la llamada a la herramienta, no lo entregado. Si no se persiste en el
/// teléfono, cerrar la app la pierde.
struct Entrega: Identifiable, Codable, Equatable, Sendable {
    /// Qué se recibió. El relé manda `tipo` y, para un artefacto, `subtipo`.
    enum Forma: String, Codable, Sendable {
        case archivo    // un fichero del disco del agente, en base64
        case doc        // prosa en Markdown
        case sheet      // tabla en CSV
        case artifact   // HTML autocontenido
    }

    let id: String
    var agentID: String
    /// En QUÉ conversación se entregó.
    ///
    /// ⚠️ Opcional porque las guardadas antes de esto no lo tienen —y un `Codable` con
    /// campo nuevo obligatorio no lee el archivo viejo—, pero sin él la tarjeta no puede
    /// volver al hilo: al reabrirlo manda el replay, y el replay **no trae entregas**.
    /// El archivo seguía en Artefactos y la foto desaparecía de la conversación.
    var sesionID: String?
    var forma: Forma
    var titulo: String
    var recibida: Date
    /// El texto del artefacto, o `nil` si lo entregado fue un archivo.
    var contenido: String?
    /// El archivo, ya decodificado. `nil` para un artefacto.
    ///
    /// ⚠️ **No viaja en el JSON.** Vivía dentro de `entregas.json` en base64: cada foto
    /// engordaba el índice un tercio de su peso, el archivo entero se leía y se reescribía
    /// en CADA entrega nueva, y por eso el tope tenía que ser ridículo —50— tirando las
    /// viejas sin decirlo. Ahora los bytes van a su propio archivo y aquí queda sólo la
    /// ficha. Ver `bytesEnDisco`.
    var datos: Data?
    /// Dónde vive, si el agente lo anunció por URL en vez de mandarnos los bytes.
    ///
    /// ⚠️ Opcional para que el `entregas.json` viejo siga leyéndose. Una entrega con URL y
    /// sin bytes es válida: se baja cuando hace falta, y de paso no engorda el JSON —que
    /// guarda los bytes en base64— con megas que no hacen falta ahí. Ver `BloqueEbFile`.
    var url: String?
    /// Lo que dijo que pesaba, para poder decirlo sin bajarlo.
    var bytesRemotos: Int?

    /// El de siempre. Se escribe a mano porque `init(from:)` propio quita el que Swift
    /// generaba solo.
    init(id: String, agentID: String, sesionID: String? = nil, forma: Forma, titulo: String,
         recibida: Date, contenido: String? = nil, datos: Data? = nil,
         url: String? = nil, bytesRemotos: Int? = nil) {
        self.id = id; self.agentID = agentID; self.sesionID = sesionID
        self.forma = forma; self.titulo = titulo; self.recibida = recibida
        self.contenido = contenido; self.datos = datos
        self.url = url; self.bytesRemotos = bytesRemotos
    }

    // MARK: - Los bytes, en disco

    /// Dónde viven los bytes de las entregas.
    static var almacen: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appending(path: "entregas")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func bytesEnDisco(_ id: String) -> URL {
        // El id viene de una huella hexadecimal, pero se sanea igual: un id con "/" dentro
        // escribiría fuera de la carpeta.
        almacen.appending(path: id.replacingOccurrences(of: "/", with: "_") + ".bin")
    }

    /// ⚠️ Se codifica TODO menos los bytes, y al codificar se dejan escritos en su archivo.
    /// Hacerlo aquí y no en quien guarda es lo que mantiene la regla en UN sitio: la
    /// entrega se guarda desde el almacén de artefactos **y** desde dentro de cada
    /// conversación (`MensajeGuardado.entrega`), y si sólo uno de los dos escribiera los
    /// bytes, la foto volvería a desaparecer al recargar el hilo.
    enum CodingKeys: String, CodingKey {
        case id, agentID, sesionID, forma, titulo, recibida, contenido, url, bytesRemotos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentID = try c.decode(String.self, forKey: .agentID)
        sesionID = try c.decodeIfPresent(String.self, forKey: .sesionID)
        forma = try c.decode(Forma.self, forKey: .forma)
        titulo = try c.decode(String.self, forKey: .titulo)
        recibida = try c.decode(Date.self, forKey: .recibida)
        contenido = try c.decodeIfPresent(String.self, forKey: .contenido)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        bytesRemotos = try c.decodeIfPresent(Int.self, forKey: .bytesRemotos)
        // Los de siempre, más los del formato viejo: un `entregas.json` escrito antes de
        // esto lleva los bytes dentro, y tirarlos sería perder artefactos que ya tenías.
        if let viejos = try? decoder.container(keyedBy: ClaveVieja.self)
            .decodeIfPresent(Data.self, forKey: .datos) {
            datos = viejos
            try? viejos.write(to: Self.bytesEnDisco(id), options: .atomic)
        } else {
            datos = try? Data(contentsOf: Self.bytesEnDisco(id))
        }
    }

    private enum ClaveVieja: String, CodingKey { case datos }

    func encode(to encoder: Encoder) throws {
        if let datos, !datos.isEmpty {
            try? datos.write(to: Self.bytesEnDisco(id), options: .atomic)
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(agentID, forKey: .agentID)
        try c.encodeIfPresent(sesionID, forKey: .sesionID)
        try c.encode(forma, forKey: .forma)
        try c.encode(titulo, forKey: .titulo)
        try c.encode(recibida, forKey: .recibida)
        try c.encodeIfPresent(contenido, forKey: .contenido)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(bytesRemotos, forKey: .bytesRemotos)
    }

    var etiqueta: String {
        switch forma {
        case .archivo:  "Archivo"
        case .doc:      "Documento"
        case .sheet:    "Tabla"
        case .artifact: "Página"
        }
    }

    /// De qué es este archivo, DE VERDAD.
    ///
    /// Del sufijo del título si lo trae y, si no, de los primeros bytes. Un agente puede
    /// entregar un PDF titulado «Reporte» a secas, y sin esto el visor del sistema no sabe
    /// con qué abrirlo, el icono sale genérico y la vista previa intenta leerlo como texto
    /// —enseñando `%PDF-1.7 %µ¶` en la tarjeta—. Es UN solo sitio a propósito: cuando esto
    /// vivía repartido, cada consumidor acertaba o fallaba por su cuenta.
    var tipo: String? {
        if let punto = titulo.lastIndex(of: "."), punto != titulo.startIndex {
            let ext = String(titulo[titulo.index(after: punto)...]).lowercased()
            if !ext.isEmpty, ext.count <= 5 { return ext }
        }
        switch forma {
        case .doc: return "md"
        case .sheet: return "csv"
        case .artifact: return "html"
        case .archivo: break
        }
        // Sin bytes, del sufijo de la URL: es la misma regla que con el título, con otra
        // fuente. Un archivo anunciado por URL casi siempre la trae.
        guard let d = datos, d.count >= 12 else {
            if let url, let ext = URL(string: url)?.pathExtension.lowercased(),
               !ext.isEmpty, ext.count <= 5 { return ext }
            return nil
        }
        let b = [UInt8](d.prefix(12))
        if b[0] == 0x25, b[1] == 0x50, b[2] == 0x44, b[3] == 0x46 { return "pdf" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        // ⚠️ El AUDIO iba ANTES de aquí y no estaba. Un MP3 empieza por `ID3`, que
        // decodifica como UTF-8, así que caía en el último recurso y se guardaba con
        // extensión `.txt`: el visor del sistema hacía lo correcto con lo que le dimos
        // —enseñarlo como texto— y salía un muro de `ID3nTLEN0.96COMM…`. La firma va
        // SIEMPRE antes del recurso de texto, porque el recurso de texto acierta con
        // cualquier cosa que empiece por letras.
        if b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return "mp3" }          // ID3
        if b[0] == 0xFF, b[1] & 0xE0 == 0xE0 { return "mp3" }                // frame MPEG
        if b[0] == 0x4F, b[1] == 0x67, b[2] == 0x67, b[3] == 0x53 { return "ogg" }
        if b[0] == 0x66, b[1] == 0x4C, b[2] == 0x61, b[3] == 0x43 { return "flac" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 {          // RIFF
            return b[8] == 0x57 && b[9] == 0x41 ? "wav" : "avi"               // WAVE
        }
        // Contenedor ISO: el `ftyp` va en el offset 4 y su marca dice si es audio o vídeo.
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let marca = String(decoding: d[8..<12], as: UTF8.self)
            return marca.hasPrefix("M4A") ? "m4a" : "mp4"
        }
        if b[0] == 0x50, b[1] == 0x4B, b[2] == 0x03, b[3] == 0x04 { return "zip" }
        // ⚠️ Y el último recurso, más estricto: que decodifique NO basta —medio binario
        // decodifica—. Se exige que lo que se lea sea de verdad texto imprimible.
        if let t = String(data: d.prefix(512), encoding: .utf8),
           t.unicodeScalars.allSatisfy({ $0 == "\n" || $0 == "\r" || $0 == "\t" || ($0.value >= 32 && $0.value != 127) }) {
            return "txt"
        }
        return nil
    }

    /// Deja la entrega en un archivo temporal, con su nombre y su extensión.
    ///
    /// ⚠️ La EXTENSIÓN no es cosmética: es con lo que el sistema decide cómo abrirlo y
    /// cómo compartirlo. Un MP3 sin ella se ofrecía como texto. Vive en el modelo porque
    /// lo necesitan la tarjeta, el visor de imagen y el reproductor — cuando cada uno se
    /// lo montaba por su cuenta, acertaba o fallaba por su cuenta.
    /// ¿Hay que bajarlo antes de poder hacer nada con él?
    var hayQueBajar: Bool { datos == nil && contenido == nil && url != nil }

    func aDisco() -> URL? {
        let base = FileManager.default.temporaryDirectory
        let limpio = titulo.replacingOccurrences(of: "/", with: "-")
        let ext = tipo ?? ""
        let nombre = ext.isEmpty || limpio.lowercased().hasSuffix(".\(ext)")
            ? limpio : "\(limpio).\(ext)"
        let url = base.appending(path: nombre)
        do {
            if let datos { try datos.write(to: url, options: .atomic) }
            else { try (contenido ?? "").write(to: url, atomically: true, encoding: .utf8) }
            return url
        } catch {
            return nil
        }
    }

    /// En qué cajón cae, para poder filtrar.
    ///
    /// ⚠️ Sale del TIPO real —que ya se deduce de los bytes cuando el título no ayuda— y
    /// no del nombre: un agente entrega «SFX cómic 08» sin extensión y eso no dice nada.
    enum Categoria: String, CaseIterable, Identifiable {
        case imagen, audio, documento, otro
        var id: String { rawValue }
        var nombre: String {
            switch self {
            case .imagen:    return "Imágenes"
            case .audio:     return "Audio"
            case .documento: return "Documentos"
            case .otro:      return "Otros"
            }
        }
        var icono: String {
            switch self {
            case .imagen:    return "photo"
            case .audio:     return "waveform"
            case .documento: return "doc.text"
            case .otro:      return "paperclip"
            }
        }
    }

    var categoria: Categoria {
        if esAudio { return .audio }
        switch tipo {
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return .imagen
        case "pdf", "md", "csv", "html", "txt", "json", "doc", "docx", "xlsx": return .documento
        default: return forma == .archivo ? .otro : .documento
        }
    }

    /// ¿Suena? Entonces no se abre con el visor del sistema: se reproduce aquí.
    var esAudio: Bool {
        guard let t = tipo else { return false }
        return ["mp3", "m4a", "wav", "aac", "ogg", "flac", "caf", "aiff"].contains(t)
    }

    /// ¿Se puede enseñar su contenido como texto en la tarjeta?
    ///
    /// ⚠️ NO basta con que decodifique como UTF-8: la cabecera de un PDF decodifica
    /// perfectamente y acabó pintada en la tarjeta. Se pregunta por el TIPO.
    var esTexto: Bool {
        guard let t = tipo else { return false }
        return ["md", "csv", "html", "txt", "json", "yaml", "yml", "log", "xml"].contains(t)
    }

    var icono: String {
        switch forma {
        case .doc:      return "doc.text"
        case .sheet:    return "tablecells"
        case .artifact: return "safari"
        case .archivo:
            // Un archivo puede ser cualquier cosa, así que el icono sale de su tipo real:
            // el clip genérico no distingue una foto de un contrato.
            switch tipo {
            case "pdf": return "doc.richtext"
            case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
            case "csv", "xlsx", "numbers": return "tablecells"
            case "zip", "tar", "gz": return "shippingbox"
            case "txt", "md", "json", "log": return "doc.plaintext"
            case "mp3", "m4a", "wav", "aac", "ogg", "flac": return "waveform"
            default: return "paperclip"
            }
        }
    }

    /// Lo que ocupa, para poder decirlo sin abrirlo.
    var peso: String? {
        // ⚠️ Si no hay bytes se usa lo que dijo el anuncio, y si tampoco lo dijo NO se
        // inventa: un peso falso es peor que no decir ninguno.
        let n = datos?.count ?? contenido?.utf8.count ?? bytesRemotos
        guard let n, n > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

/// Guarda las entregas en disco, igual que la bitácora de turnos y por la misma razón:
/// no son secreto, y así sobreviven a que alguien borre la credencial.
@Observable
@MainActor
final class EntregasStore {
    private(set) var entregas: [Entrega] = []
    /// ⚠️ Era 50 porque cada fila llevaba los bytes dentro del JSON. Ahora los bytes
    /// viven en su propio archivo y el índice pesa lo que pesa una ficha, así que caben
    /// muchos más — pero sigue habiendo tope: lo que se sale se BORRA, y borrar en
    /// silencio lo que alguien creía guardado es de las peores cosas que puede hacer una
    /// app. Por eso también se limpian sus bytes.
    private let tope = 300

    private var archivo: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "entregas.json")
    }

    init() { cargar() }

    func registrar(_ e: Entrega) {
        // ⚠️ La entrega del relé no dice a qué hilo pertenece, así que con varios turnos
        // vivos llega por todos a la vez. Su id es determinista (ver `entregaDesde`), y
        // aquí es donde eso sirve: la misma entrega registrada N veces es UNA fila.
        guard !entregas.contains(where: { $0.id == e.id }) else { return }
        entregas.insert(e, at: 0)
        if entregas.count > tope {
            for sobrante in entregas.dropFirst(tope) {
                try? FileManager.default.removeItem(at: Entrega.bytesEnDisco(sobrante.id))
            }
            entregas = Array(entregas.prefix(tope))
        }
        guardar()
    }

    func de(_ agentID: String?) -> [Entrega] {
        guard let agentID else { return entregas }
        return entregas.filter { $0.agentID == agentID }
    }

    /// Lo entregado EN una conversación, en el orden en que llegó. Es lo que devuelve las
    /// tarjetas al hilo cuando se recarga desde la caja.
    func deSesion(_ sesionID: String) -> [Entrega] {
        entregas.filter { $0.sesionID == sesionID }.sorted { $0.recibida < $1.recibida }
    }

    /// Borra UNA. Vive sólo en el teléfono, así que esto no puede dejar nada huérfano en
    /// ningún sitio — es el único borrado que hoy se puede hacer sin preguntarle a nadie.
    func olvidar(_ id: String) {
        entregas.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Entrega.bytesEnDisco(id))
        guardar()
    }

    func limpiar() {
        entregas = []
        try? FileManager.default.removeItem(at: archivo)
        try? FileManager.default.removeItem(at: Entrega.almacen)
    }

    // MARK: - Disco

    private func cargar() {
        guard let d = try? Data(contentsOf: archivo),
              let l = try? JSONDecoder().decode([Entrega].self, from: d) else { return }
        entregas = l
    }

    private func guardar() {
        guard let d = try? JSONEncoder().encode(entregas) else { return }
        try? d.write(to: archivo, options: .atomic)
    }
}
