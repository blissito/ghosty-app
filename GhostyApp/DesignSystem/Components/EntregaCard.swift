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
    private var imagen: UIImage? {
        guard entrega.forma == .archivo, let d = datos else { return nil }
        if entrega.tipo == "pdf" { return Self.portada(d) }
        return UIImage(data: d)
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
        guard let s = entrega.url, let u = URL(string: s), !bajando else { return }
        bajando = true
        defer { bajando = false }
        do {
            guard let d = await Descargas.bytes(u) else {
                // ⚠️ Una URL firmada CADUCA. Decirlo es la diferencia entre «esto ya no
                // está» y una tarjeta que no hace nada al tocarla.
                falloAlBajar = "Ese enlace ya no sirve."
                return
            }
            bajados = d
            falloAlBajar = nil
            if yAbrir {
                if let img = UIImage(data: d), entrega.esAudio == false { mirando = img }
                else { compartiendo = conBytes()?.aDisco() }
            }
        }
    }

    var body: some View {
        Button {
            // Una imagen la enseñamos nosotros; lo demás va al visor del sistema. Ver
            // `VisorDeImagen`: QuickLook abre un PDF y se queda en negro con un PNG.
            // Una imagen la enseñamos nosotros y un audio se reproduce en la propia
            // tarjeta; lo demás va al visor del sistema.
            if let img = imagen { mirando = img }
            else if entrega.esAudio { return }
            // Sin bytes todavía: se bajan al TOCAR y no al pintar la fila. Bajar un PDF de
            // 20 MB sólo para enseñar un nombre sería peor que no enseñarlo.
            else if datos == nil, entrega.url != nil { Task { await bajar(yAbrir: true) } }
            else { compartiendo = conBytes()?.aDisco() }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                vistaPrevia
                // Un audio se oye aquí; no hay «fila» que abrir nada.
                if entrega.esAudio {
                    ReproductorDeEntrega(entrega: entrega)
                } else {
                    fila
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
            .background(Color.gCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .quickLookPreview($compartiendo)
        // ⚠️ Sólo las IMÁGENES se bajan al aparecer: la miniatura es lo que hace útil la
        // tarjeta. Lo demás espera al toque — ver el aviso de arriba.
        .task(id: entrega.id) {
            guard entrega.hayQueBajar, bajados == nil else { return }
            let ext = entrega.tipo ?? ""
            // ⚠️ El PDF también: su vista previa es la primera página, y sin bajarlo la
            // tarjeta es una fila con un nombre. Se acota por peso —lo que dijo el
            // anuncio— para no traerse un documento enorme sólo por la miniatura.
            let conVistaPrevia = ["png", "jpg", "jpeg", "heic", "gif", "webp", "pdf"]
            guard conVistaPrevia.contains(ext) else { return }
            if let peso = entrega.bytesRemotos, peso > 8 * 1024 * 1024 { return }
            await bajar(yAbrir: false)
        }
        .fullScreenCover(item: $mirando) { img in
            VisorDeImagen(imagen: img, titulo: entrega.titulo, archivo: conBytes()?.aDisco())
        }
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
        } else if let texto = Self.asomo(entrega) {
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

    private var fila: some View {
        HStack(spacing: 12) {
            TintedIcon(systemName: entrega.icono, tint: tinte.fg,
                       background: tinte.bg, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(entrega.titulo)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                if let falloAlBajar {
                    Text(falloAlBajar).gCaption().foregroundStyle(Color.gDangerInk)
                } else {
                    Text([entrega.etiqueta, entrega.peso].compactMap { $0 }.joined(separator: " · "))
                        .gCaption()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if bajando { ProgressView().controlSize(.small) }
            Image(systemName: "arrow.up.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.gInk3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Color por tipo. Un PDF rojo se reconoce sin leer el nombre; todo morado, no.
    private var tinte: (fg: Color, bg: Color) {
        switch entrega.forma {
        case .sheet:    return (.gGreenInk, .gGreenTint)
        case .artifact: return (.gPrimary, .gPrimaryTint)
        case .doc:      return (.gPrimary, .gPrimaryTint)
        case .archivo:
            switch entrega.tipo {
            case "pdf": return (.gDangerInk, .gDangerTint)
            case "csv", "xlsx", "numbers": return (.gGreenInk, .gGreenTint)
            default: return (.gInk2, .gFill)
            }
        }
    }

    /// Las primeras líneas de lo entregado, para la vista previa.
    ///
    /// ⚠️ Sólo si es texto DE VERDAD: un binario decodificado como UTF-8 da o basura o
    /// `nil`, y enseñar basura es peor que no enseñar nada.
    private static func asomo(_ e: Entrega) -> String? {
        let crudo: String?
        if let c = e.contenido { crudo = c }
        // ⚠️ `esTexto`, no "decodifica como UTF-8": la cabecera de un PDF decodifica
        // perfectamente y se pintó `%PDF-1.7 %µ¶ % Written by MuPDF` en la tarjeta.
        else if e.esTexto, let d = e.datos, d.count < 200_000 { crudo = String(data: d, encoding: .utf8) }
        else { crudo = nil }
        guard let crudo, !crudo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return crudo.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(6)
            .joined(separator: "\n")
    }


}
