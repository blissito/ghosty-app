import PDFKit
import QuickLook
import SwiftUI

/// Lo que el agente entregó, dentro del hilo.
///
/// Es una tarjeta y no una burbuja porque no es algo que dijo: es algo que hizo. Se toca
/// para abrirlo con el visor del sistema, que es lo que el teléfono ya sabe hacer bien
/// con un PDF, una hoja o una página.
///
/// **Vista previa arriba, fila compacta debajo.** Es el patrón que usa Muse (mirado en sus
/// capturas del App Store, no de memoria) y la razón es buena: una fila con nombre y peso
/// no dice si lo entregado sirve. Con la miniatura se sabe de un vistazo, sin abrir nada.
struct EntregaCard: View {
    let entrega: Entrega
    @State private var compartiendo: URL?
    @State private var mirando: UIImage?
    /// Lo bajado, cuando la entrega vino sólo con URL. Ver `BloqueEbFile`.
    @State private var bajados: Data?
    @State private var bajando = false
    @State private var falloAlBajar: String?

    /// Los bytes, vengan de donde vengan.
    private var datos: Data? { entrega.datos ?? bajados }

    /// La imagen entregada, si lo que llegó es una.
    ///
    /// ⚠️ Incluye la PRIMERA PÁGINA de un PDF, renderizada. Un PDF entregado sin vista
    /// previa es una fila con un nombre: no dice si el documento salió bien, que es
    /// justamente lo que uno quiere saber de un entregable. PDFKit lo hace nativo y ya
    /// tenemos los bytes en la mano.
    ///
    /// Decodificada UNA vez y guardada en `MiniaturasEnMemoria`: volver a la tarjeta la pinta
    /// en el mismo fotograma, y el cuerpo ya no renderiza la portada en cada pasada.
    private var imagen: UIImage? {
        guard entrega.forma == .archivo else { return nil }
        let clave = "entrega:" + (entrega.remotoID ?? entrega.id)
        if let ya = MiniaturasEnMemoria.imagen(clave) { return ya }
        guard let d = datos else { return nil }
        let img = entrega.tipo == "pdf" ? Self.portada(d) : UIImage(data: d)
        if let img { MiniaturasEnMemoria.guardar(img, clave: clave) }
        return img
    }

    /// La primera página de un PDF como imagen.
    ///
    /// Se dibuja al ANCHO de la tarjeta y no al tamaño de la página: una carta a 72 dpi son
    /// 612 pt de ancho y se vería borrosa al estirarla.
    private static func portada(_ datos: Data) -> UIImage? {
        guard let doc = PDFDocument(data: datos), let pagina = doc.page(at: 0) else { return nil }
        let caja = pagina.bounds(for: .mediaBox)
        guard caja.width > 0 else { return nil }
        let ancho: CGFloat = 600
        let escala = ancho / caja.width
        return pagina.thumbnail(of: CGSize(width: ancho, height: caja.height * escala), for: .mediaBox)
    }

    /// La entrega con los bytes que se hayan bajado, para lo que necesite un archivo.
    private func conBytes() -> Entrega? {
        guard var e = Optional(entrega) else { return nil }
        if e.datos == nil { e.datos = bajados }
        return e
    }

    private func bajar(yAbrir: Bool) async {
        guard !bajando, entrega.url != nil || entrega.remotoID != nil else { return }
        bajando = true
        defer { bajando = false }
        do {
            // De los archivos de la cuenta, con firma fresca; o de la URL que anunció el
            // agente, que puede haber caducado.
            let d: Data?
            if let id = entrega.remotoID { d = try? await GhostyAPI.bajar(id) }
            else if let s = entrega.url, let u = URL(string: s) { d = await Descargas.bytes(u) }
            else { d = nil }
            guard let d else {
                // ⚠️ Una URL firmada CADUCA. Decirlo es la diferencia entre «esto ya no
                // está» y una tarjeta que no hace nada al tocarla.
                falloAlBajar = "Ese enlace ya no sirve."
                return
            }
            bajados = d
            falloAlBajar = nil
            if yAbrir {
                if entrega.tipo != "pdf", let img = UIImage(data: d), entrega.esAudio == false { mirando = img }
                else { compartiendo = conBytes()?.aDisco() }
            }
        }
    }

    var body: some View {
        // ⚠️ Un audio o un video NO van dentro de un `Button`: sus controles (play,
        // guardar) son botones propios, y anidados dentro del de la tarjeta el toque se
        // lo quedaba el de fuera —que para audio/video no hacía nada—. Era el «play no
        // reproduce» y el «el botón de descarga no recibe el clic».
        // ⚠️ Y la que sí se abre va con `onTapGesture`, no con `Button`: un `Button` que
        // presenta un `fullScreenCover` desde su acción se queda «pulsado», y el SIGUIENTE
        // toque en cualquier sitio del hilo lo suelta y vuelve a abrir el visor —medido:
        // cerrar la imagen y dar play a la nota de voz de al lado reabría la imagen—.
        Group {
            if let filas = filasDeTabla {
                // Una tabla entregada (CSV) se LEE en el hilo, con su Excel y su copiar:
                // abrirla en el visor del sistema para ver cuatro filas era un paso de más.
                TablaCard(filas: filas, nombre: Self.sinExtension(entrega.titulo),
                          titulo: entrega.titulo)
                    .frame(maxWidth: 360, alignment: .leading)
            } else if entrega.esAudio || entrega.esVideo {
                tarjeta
            } else {
                tarjeta.contentShape(Rectangle()).onTapGesture(perform: abrir)
            }
        }
        .quickLookPreview($compartiendo)
        // ⚠️ Sólo las IMÁGENES se bajan al aparecer: la miniatura es lo que hace útil la
        // tarjeta. Lo demás espera al toque — ver el aviso de arriba.
        .task(id: entrega.id) {
            guard entrega.hayQueBajar, bajados == nil else { return }
            let ext = entrega.tipo ?? ""
            // ⚠️ El PDF también: su vista previa es la primera página, y sin bajarlo la
            // tarjeta es una fila con un nombre. Se acota por peso —lo que dijo el
            // anuncio— para no traerse un documento enorme sólo por la miniatura.
            // Ya pintada desde memoria: no hace falta ni el disco.
            if MiniaturasEnMemoria.imagen("entrega:" + (entrega.remotoID ?? entrega.id)) != nil { return }
            let conVistaPrevia = ["png", "jpg", "jpeg", "heic", "gif", "webp", "pdf", "csv"]
            // El texto chico también: su asomo es la vista previa. Uno grande espera al toque.
            let textoChico = entrega.esTexto && (entrega.bytesRemotos ?? .max) < 200_000
            guard conVistaPrevia.contains(ext) || textoChico else { return }
            if let peso = entrega.bytesRemotos, peso > 8 * 1024 * 1024 { return }
            // Lo que está en el disco sale sin spinner; sólo la red enseña el cargando.
            if let id = entrega.remotoID, ArchivosEnDisco.hay(id), let d = await ArchivosEnDisco.leer(id) {
                bajados = d
                return
            }
            await bajar(yAbrir: false)
        }
        .fullScreenCover(item: $mirando) { img in
            VisorDeImagen(imagen: img, titulo: entrega.titulo, archivo: conBytes()?.aDisco(),
                          onCerrar: { mirando = nil })
        }
    }

    /// Tocar la tarjeta: una imagen la enseñamos nosotros; lo demás va al visor del
    /// sistema. Ver `VisorDeImagen`: QuickLook abre un PDF y se queda en negro con un PNG.
    /// ⚠️ Un PDF NO se abre como imagen: `imagen` es sólo su portada para la tarjeta, y
    /// en el visor de fotos «un PDF de dos páginas» se veía de una.
    private func abrir() {
        if entrega.tipo == "pdf" {
            if datos == nil { Task { await bajar(yAbrir: true) } }
            else { compartiendo = conBytes()?.aDisco() }
        }
        else if let img = imagen { mirando = img }
        // Sin bytes todavía: se bajan al TOCAR y no al pintar la fila. Bajar un PDF de
        // 20 MB sólo para enseñar un nombre sería peor que no enseñarlo.
        else if datos == nil, entrega.url != nil || entrega.remotoID != nil { Task { await bajar(yAbrir: true) } }
        else { compartiendo = conBytes()?.aDisco() }
    }

    /// La tarjeta del diseño: blanca, borde fino, r16. Arriba la vista previa (imagen,
    /// portada del PDF, asomo de texto) o el reproductor; abajo la fila compacta.
    private var tarjeta: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Un video se ve aquí, con su cuadro reservado; un audio se oye aquí.
            if entrega.esVideo {
                ReproductorDeVideo(entrega: entrega)
            } else {
                vistaPrevia
                if entrega.esAudio {
                    ReproductorDeEntrega(entrega: entrega)
                } else {
                    fila
                        .overlay(alignment: .top) {
                            if tieneVistaPrevia { Rectangle().fill(Color.gHairline).frame(height: 1) }
                        }
                }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .ghostyCard(radius: Theme.Radius.threadCard)
    }

    /// Las filas, si lo entregado es una tabla que ya tenemos en la mano.
    private var filasDeTabla: [[String]]? {
        guard entrega.forma == .sheet || entrega.tipo == "csv" else { return nil }
        let texto = entrega.contenido ?? datos.flatMap { $0.count < 400_000 ? String(data: $0, encoding: .utf8) : nil }
        guard let texto else { return nil }
        let filas = Tabular.deCSV(texto)
        return filas.count > 1 && (filas.first?.count ?? 0) > 1 ? filas : nil
    }

    private var tieneVistaPrevia: Bool { imagen != nil || Self.asomo(entrega, datos: datos) != nil }

    static func sinExtension(_ titulo: String) -> String {
        guard let punto = titulo.lastIndex(of: "."), punto != titulo.startIndex else { return titulo }
        return String(titulo[..<punto])
    }

    // MARK: - Piezas

    @ViewBuilder
    private var vistaPrevia: some View {
        if let img = imagen {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                // Un documento se recorta por ABAJO, no por el centro: lo que identifica una
                // página es su encabezado. Una foto sí se centra.
                .frame(maxWidth: .infinity, maxHeight: 180,
                       alignment: entrega.tipo == "pdf" ? .top : .center)
                .clipped()
        } else if let texto = Self.asomo(entrega, datos: datos) {
            Text(texto)
                .gMono(size: 11.5)
                .foregroundStyle(Color.gInk2)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
                // Se desvanece abajo en vez de cortarse en seco: el corte limpio parece un
                // documento que acaba ahí, y el degradado dice "sigue".
                .mask(LinearGradient(colors: [.black, .black, .clear],
                                     startPoint: .top, endPoint: .bottom))
                .frame(maxHeight: 108, alignment: .top)
                .clipped()
        }
    }

    /// La fila compacta del diseño: insignia del tipo (40×48, r8), nombre `600 14`,
    /// meta `400 12` y «Compartir» morado.
    private var fila: some View {
        HStack(spacing: 12) {
            InsigniaDeTipo(ext: entrega.tipo)
            VStack(alignment: .leading, spacing: 2) {
                Text(entrega.titulo)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let falloAlBajar {
                    Text(falloAlBajar).font(.system(size: 12)).foregroundStyle(Color.gDangerInk)
                } else {
                    Text([entrega.etiqueta, entrega.peso].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.gInk3)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if bajando {
                ProgressView().controlSize(.small)
            } else {
                ShareLink(item: EntregaCompartible(entrega: conBytes() ?? entrega),
                          preview: SharePreview(entrega.titulo)) {
                    Text("Compartir")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.gPrimary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.gPressPill)
                .accessibilityIdentifier("compartir-entrega")
            }
        }
        .padding(12)
    }

    /// Las primeras líneas de lo entregado, para la vista previa.
    ///
    /// ⚠️ Sólo si es texto DE VERDAD: un binario decodificado como UTF-8 da o basura o
    /// `nil`, y enseñar basura es peor que no enseñar nada.
    private static func asomo(_ e: Entrega, datos: Data?) -> String? {
        let crudo: String?
        if let c = e.contenido { crudo = c }
        // ⚠️ `esTexto`, no "decodifica como UTF-8": la cabecera de un PDF decodifica
        // perfectamente y se pintó `%PDF-1.7 %µ¶ % Written by MuPDF` en la tarjeta.
        else if e.esTexto, let d = datos, d.count < 200_000 { crudo = String(data: d, encoding: .utf8) }
        else { crudo = nil }
        guard let crudo, !crudo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return crudo.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(6)
            .joined(separator: "\n")
    }


}

/// La insignia del tipo de archivo del diseño: 40×48, r8, las letras abajo en mono 700 10.
/// Rojo para PDF, verde para hojas, morado para imágenes; el resto en gris.
struct InsigniaDeTipo: View {
    let ext: String?
    var ancho: CGFloat = 40
    var alto: CGFloat = 48

    static func rotulo(_ ext: String?) -> String {
        switch ext?.lowercased() {
        case "pdf"?: return "PDF"
        case "xlsx"?, "xls"?, "csv"?, "numbers"?: return "XLS"
        case "png"?, "jpg"?, "jpeg"?, "heic"?, "gif"?, "webp"?: return "IMG"
        case "doc"?, "docx"?: return "DOC"
        case "mp3"?, "m4a"?, "wav"?, "aac"?, "ogg"?: return "AUD"
        case "mp4"?, "mov"?, "m4v"?, "webm"?: return "VID"
        case let e?: return String(e.prefix(4)).uppercased()
        case nil: return "FILE"
        }
    }

    static func tinte(_ ext: String?) -> (fondo: Color, tinta: Color) {
        switch rotulo(ext) {
        case "PDF": return (.gDangerTint, .gDanger)
        case "XLS": return (.gGreenTint, .gGreen)
        case "IMG": return (.gPrimaryTint, .gPrimary)
        default:    return (.gFill, .gInk2)
        }
    }

    var body: some View {
        let t = Self.tinte(ext)
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(t.fondo)
            .frame(width: ancho, height: alto)
            .overlay(alignment: .bottom) {
                Text(Self.rotulo(ext))
                    .font(.system(size: ancho >= 40 ? 10 : 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(t.tinta)
                    .padding(.bottom, ancho >= 40 ? 6 : 5)
            }
            .accessibilityHidden(true)
    }
}

/// Lo entregado como archivo para la hoja de compartir. Se baja AL COMPARTIR si hace
/// falta: bajar cada PDF del hilo sólo por si alguien le da a «Compartir» sería caro.
struct EntregaCompartible: Transferable {
    let entrega: Entrega

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { c in
            var e = c.entrega
            if e.hayQueBajar {
                if let id = e.remotoID { e.datos = try await GhostyAPI.bajar(id) }
                else if let s = e.url, let u = URL(string: s) { e.datos = await Descargas.bytes(u) }
            }
            guard let url = e.aDisco() else { throw CocoaError(.fileWriteUnknown) }
            return SentTransferredFile(url)
        }
    }
}
