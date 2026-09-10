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
    var datos: Data?

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
        guard let d = datos, d.count >= 12 else { return nil }
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
        let n = datos?.count ?? contenido?.utf8.count
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
    /// ⚠️ Más bajo que el de los turnos a propósito: aquí cada fila lleva el CONTENIDO,
    /// no un puñado de contadores. Cincuenta artefactos de medio mega se leen enteros en
    /// cada arranque.
    private let tope = 50

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
        if entregas.count > tope { entregas = Array(entregas.prefix(tope)) }
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
        guardar()
    }

    func limpiar() {
        entregas = []
        try? FileManager.default.removeItem(at: archivo)
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
