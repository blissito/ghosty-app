import Foundation
import Observation
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// El estado de la hoja «Enviar a Ghosty» y los dos caminos: mandar ya o abrir la app.
///
/// ⚠️ Mandar reutiliza EXACTAMENTE el camino de la app —`ClienteGS.nuevaSesion`,
/// `GhostyAPI.subir` a `/me/files` y el mismo POST de `encargar`— para que el agente
/// reciba el mensaje con el mismo formato (bloques de adjuntos incluidos) que si lo
/// hubieras mandado desde el compositor.
@Observable
@MainActor
final class ModeloDeEnvio {

    enum Estado: Equatable {
        case cargando
        case sinSesion
        case sinConsentimiento
        case sinAgentes
        case listo
        case enviando(String)
        case enviado(agente: String, sesion: String)
        case fallo(String)
    }

    /// Lo que se va a mandar, ya leído.
    struct Pieza: Identifiable {
        let id = UUID()
        var adjunto: Adjunto
        var miniatura: UIImage?
    }

    var estado: Estado = .cargando
    var piezas: [Pieza] = []
    /// Texto y enlaces compartidos (no archivos): van en el cuerpo del mensaje.
    var compartidoComoTexto: [String] = []
    var instruccion = ""
    var agentes: [AgentAccount] = []
    var agenteID: String?
    /// Lo que no se pudo leer o se pasó del tope, para decirlo.
    var avisos: [String] = []

    var cerrar: () -> Void = {}
    var abrirApp: (URL) -> Void = { _ in }

    static let maxArchivos = 8
    static let maxBytes = 15 * 1024 * 1024
    static let atajos = ["Resúmelo", "Tradúcelo", "Sácale los datos"]

    var agente: AgentAccount? { agentes.first { $0.id == agenteID } }

    func tono(de id: String) -> AgentTone {
        let tonos: [AgentTone] = [.lila, .azul, .durazno]
        let i = agentes.firstIndex { $0.id == id } ?? 0
        return tonos[i % tonos.count]
    }

    var hayAlgo: Bool { !piezas.isEmpty || !compartidoComoTexto.isEmpty }

    // MARK: - Arranque

    func cargar(_ items: [NSExtensionItem]) async {
        await LectorDeCompartido.leer(items, en: self)
        guard Session.haySesion else { estado = .sinSesion; return }
        agentes = Credentials.accounts
        agenteID = Credentials.activeID
        guard !agentes.isEmpty else { estado = .sinAgentes; return }
        estado = GrupoDeApp.hayConsentimiento ? .listo : .sinConsentimiento
    }

    func agregar(_ a: Adjunto, miniatura: UIImage?) {
        guard piezas.count < Self.maxArchivos else {
            avisos.append("Sólo van \(Self.maxArchivos) archivos: «\(a.nombre)» se quedó fuera.")
            return
        }
        guard a.datos.count <= Self.maxBytes else {
            avisos.append("«\(a.nombre)» pesa más de 15 MB.")
            return
        }
        piezas.append(Pieza(adjunto: a, miniatura: miniatura))
    }

    func quitar(_ p: Pieza) { piezas.removeAll { $0.id == p.id } }

    // MARK: - Mandar

    /// El texto del turno: lo que pides y, debajo, el texto o los enlaces compartidos.
    private var texto: String {
        let pedido = instruccion.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = compartidoComoTexto.joined(separator: "\n\n")
        return [pedido, extra].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func enviar() {
        guard let agente, hayAlgo || !instruccion.isEmpty else { return }
        let adjuntos = piezas.map(\.adjunto)
        let texto = self.texto
        estado = .enviando("Abriendo la conversación…")
        Task {
            do {
                let cliente = ClienteGS(agentID: agente.id)
                let sid = try await cliente.nuevaSesion(cwd: "/data/work").id
                // Igual que `LiveAgentStore.subidos`: todo va a la cuenta, y uno que no
                // sube NO tumba el turno (el servidor le dice al agente que falta).
                var subidos: [Adjunto] = []
                for (i, var a) in adjuntos.enumerated() {
                    estado = .enviando("Subiendo \(i + 1) de \(adjuntos.count)…")
                    do { a.remoto = try await GhostyAPI.subir(a, sesion: sid) }
                    catch { avisos.append(error.localizedDescription) }
                    subidos.append(a)
                }
                estado = .enviando("Mandando…")
                _ = try await cliente.encargarSinEscuchar(sessionID: sid, texto: texto, adjuntos: subidos)
                estado = .enviado(agente: agente.id, sesion: sid)
            } catch Session.Fallo.sinSesion, Session.Fallo.caducada {
                estado = .sinSesion
            } catch {
                estado = .fallo(error.localizedDescription)
            }
        }
    }

    /// «Abrir en Ghosty» sin mandar: los archivos al contenedor del grupo y la app los
    /// pone en el compositor de una conversación nueva.
    func abrirSinMandar() {
        do {
            let id = try BuzonCompartido.guardar(agente: agenteID, texto: texto,
                                                 adjuntos: piezas.map(\.adjunto))
            abrirApp(EnlaceDeGhosty.compartido(id: id).url)
        } catch {
            estado = .fallo("No pude pasarle los archivos a la app: \(error.localizedDescription)")
        }
    }

    func abrirConversacion() {
        guard case .enviado(let a, let s) = estado else { return }
        abrirApp(EnlaceDeGhosty.conversacion(agente: a, sesion: s).url)
    }

    /// Para iniciar sesión o dar el consentimiento: la app, sin más.
    func abrirLaApp() {
        abrirApp(URL(string: "\(Session.redirectScheme)://")!)
    }
}

/// Convierte lo que llega de la hoja de compartir en `Adjunto`s y texto.
enum LectorDeCompartido {

    /// Imágenes que el modelo ve tal cual; lo demás (HEIC, TIFF…) se pasa a JPEG.
    private static let imagenesQueVe: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]
    private static let ladoMaximo: CGFloat = 2048

    @MainActor
    static func leer(_ items: [NSExtensionItem], en modelo: ModeloDeEnvio) async {
        for item in items {
            for p in item.attachments ?? [] {
                await leer(p, en: modelo)
            }
        }
    }

    @MainActor
    private static func leer(_ p: NSItemProvider, en modelo: ModeloDeEnvio) async {
        let tipos = p.registeredTypeIdentifiers.compactMap(UTType.init)

        // Un enlace web (no un archivo): va como texto.
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           !tipos.contains(where: { $0.conforms(to: .image) || $0.conforms(to: .pdf) }),
           let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
            if !url.isFileURL {
                modelo.compartidoComoTexto.append(url.absoluteString)
                return
            }
        }

        // Texto suelto (una selección, una nota): también al cuerpo.
        if tipos.allSatisfy({ $0.conforms(to: .text) && !$0.conforms(to: .fileURL) }),
           tipos.contains(where: { $0.conforms(to: .plainText) }),
           let t = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            let limpio = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !limpio.isEmpty { modelo.compartidoComoTexto.append(limpio) }
            return
        }

        // Un archivo: el tipo más concreto que traiga datos.
        guard let tipo = tipos.first(where: { $0.conforms(to: .data) || $0.conforms(to: .content) })
                ?? tipos.first else { return }
        guard let (datos, nombre) = await cargarArchivo(p, tipo: tipo) else {
            modelo.avisos.append("No pude leer uno de los archivos.")
            return
        }
        let real = UTType(filenameExtension: (nombre as NSString).pathExtension) ?? tipo
        var mime = real.preferredMIMEType ?? tipo.preferredMIMEType ?? "application/octet-stream"
        var bytes = datos
        var nombreFinal = nombre
        var miniatura: UIImage?

        if real.conforms(to: .image), let img = UIImage(data: datos) {
            let grande = max(img.size.width * img.scale, img.size.height * img.scale) > ladoMaximo
            if grande || !imagenesQueVe.contains(mime), let jpeg = aJPEG(img) {
                bytes = jpeg
                mime = "image/jpeg"
                nombreFinal = ((nombre as NSString).deletingPathExtension) + ".jpg"
            }
            miniatura = img.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? img
        } else if real.conforms(to: .pdf), let doc = PDFDocument(data: datos), let pag = doc.page(at: 0) {
            miniatura = pag.thumbnail(of: CGSize(width: 160, height: 200), for: .mediaBox)
        }
        modelo.agregar(Adjunto(nombre: nombreFinal, mime: mime, datos: bytes), miniatura: miniatura)
    }

    /// Los bytes y un nombre. Primero como archivo (conserva el nombre real), luego como
    /// datos en memoria.
    private static func cargarArchivo(_ p: NSItemProvider, tipo: UTType) async -> (Data, String)? {
        let sugerido = p.suggestedName
        let porArchivo: (Data, String)? = await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: tipo.identifier) { url, _ in
                guard let url, let d = try? Data(contentsOf: url) else { cont.resume(returning: nil); return }
                cont.resume(returning: (d, url.lastPathComponent))
            }
        }
        if let porArchivo { return porArchivo }
        guard let item = try? await p.loadItem(forTypeIdentifier: tipo.identifier) else { return nil }
        let ext = tipo.preferredFilenameExtension.map { ".\($0)" } ?? ""
        let nombre = (sugerido ?? "archivo") + ((sugerido?.contains(".") == true) ? "" : ext)
        switch item {
        case let d as Data:
            return (d, nombre)
        case let u as URL:
            let abierto = u.startAccessingSecurityScopedResource()
            defer { if abierto { u.stopAccessingSecurityScopedResource() } }
            return (try? Data(contentsOf: u)).map { ($0, u.lastPathComponent) }
        case let img as UIImage:
            return img.jpegData(compressionQuality: 0.85).map { ($0, (sugerido ?? "imagen") + ".jpg") }
        default:
            return nil
        }
    }

    private static func aJPEG(_ img: UIImage) -> Data? {
        let lado = max(img.size.width, img.size.height)
        let escala = min(1, ladoMaximo / max(lado * img.scale, 1))
        let tam = CGSize(width: img.size.width * img.scale * escala, height: img.size.height * img.scale * escala)
        let formato = UIGraphicsImageRendererFormat()
        formato.scale = 1
        let r = UIGraphicsImageRenderer(size: tam, format: formato)
        return r.jpegData(withCompressionQuality: 0.85) { _ in img.draw(in: CGRect(origin: .zero, size: tam)) }
    }
}
