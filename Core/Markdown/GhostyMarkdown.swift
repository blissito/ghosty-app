import SwiftUI
import MarkdownUI

/// El markdown lo renderiza **swift-markdown-ui** (gonzalezreal, MIT), que es el
/// estándar de la comunidad para GFM en SwiftUI: trae tablas, bloques de código,
/// listas de tareas y temas. Antes esto era un parser propio de ~340 líneas — y su
/// primera versión colgaba el hilo principal con el trozo `"##"` que llega al
/// inicio de cualquier stream. Reinventarlo salía caro y ya estaba resuelto.
///
/// Aquí sólo vive el TEMA: los tokens de Ghosty aplicados a sus bloques.
struct GhostyMarkdown: View {
    let markdown: String
    /// Respuesta que se está escribiendo (`TextoAlRitmo`): los tramos que están entrando
    /// y el reloj. `nil` = texto quieto, sin fade.
    var fades: FadesDePalabra? = nil
    /// Toque largo → «Copiar». Se apaga mientras la respuesta entra (ver `TextoAlRitmo`).
    var seleccionable = true

    /// Saca cada imagen a su PROPIO párrafo.
    ///
    /// ⚠️ No es cosmético: MarkdownUI tiene dos caminos, y una imagen que va dentro de un
    /// párrafo con texto —«1. **Gatito naranja** ![…](…)», que es justo como las escribe el
    /// agente— se compone dentro de un `Text`. Ahí **no se puede tocar una imagen sola**:
    /// tocarla no hacía nada, y no había forma de arreglarlo sin sacarla del texto. Sola en
    /// su párrafo la pinta una vista de verdad, que sí se puede tocar y abrir.
    static func imagenesAparte(_ texto: String) -> String {
        guard texto.contains("![") else { return texto }
        var salida = ""
        var resto = Substring(texto)
        while let abre = resto.range(of: "![") {
            // El cierre del enlace de la imagen: `](…)`.
            guard let medio = resto.range(of: "](", range: abre.upperBound..<resto.endIndex),
                  let cierra = resto.range(of: ")", range: medio.upperBound..<resto.endIndex)
            else { break }
            let antes = resto[resto.startIndex..<abre.lowerBound]
            let imagen = resto[abre.lowerBound..<cierra.upperBound]
            salida += antes.trimmingCharacters(in: .whitespaces)
            if !antes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { salida += "\n\n" }
            salida += imagen + "\n\n"
            resto = resto[cierra.upperBound...]
        }
        salida += resto
        return salida
    }

    /// Parte el markdown en BLOQUES de primer nivel para poder revelar de a uno y poner el
    /// aire de claude.ai (20 pt) entre ellos.
    ///
    /// ⚠️ No es partir por `\n\n` a secas: dentro de un bloque de código las líneas en
    /// blanco son parte del código, y una lista con aire entre sus puntos son UNA lista —
    /// partirla renumeraba cada punto desde 1. Un cerco (```) abierto mantiene todo junto
    /// hasta que cierra; los puntos de lista consecutivos se vuelven a pegar.
    static func bloques(_ texto: String) -> [String] {
        var salida: [String] = []
        var actual: [String] = []
        var enCerco = false

        func cerrar() {
            let b = actual.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { salida.append(b) }
            actual = []
        }
        func esPunto(_ t: String) -> Bool {
            let l = t.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") { return true }
            return l.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
        }

        for linea in texto.components(separatedBy: "\n") {
            if linea.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                enCerco.toggle()
                actual.append(linea)
                if !enCerco { cerrar() }
                continue
            }
            if enCerco { actual.append(linea); continue }
            if linea.trimmingCharacters(in: .whitespaces).isEmpty { cerrar(); continue }
            // Un punto de lista tras otro bloque de lista: se pega al anterior.
            if actual.isEmpty, esPunto(linea), let ultimo = salida.last, esPunto(ultimo) {
                actual = [salida.removeLast(), ""]
            }
            actual.append(linea)
        }
        if enCerco { actual.append("```") }   // cerco a medias: llega el token que falta
        cerrar()
        return salida
    }

    /// Un bloque con su id ESTABLE: su posición y su clase. Con `\.offset` a secas un
    /// reagrupado (dos listas que se vuelven una) cambiaba la identidad de lo de abajo; así
    /// un bloque sólo es «otro» si cambia de sitio o de clase.
    private struct Pieza: Identifiable {
        let i: Int
        let texto: String
        let clase: Character
        /// Letra (del texto transformado) donde empieza y donde acaba este bloque.
        let inicio: Int
        let fin: Int
        var id: String { "\(i)-\(clase)" }
    }

    static func clase(_ b: String) -> Character {
        let l = b.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("```") { return "c" }
        if l.hasPrefix("|") { return "t" }
        if l.hasPrefix(">") { return "q" }
        if l.hasPrefix("#") { return "h" }
        if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") { return "l" }
        if l.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil { return "n" }
        if l.hasPrefix("![") { return "i" }
        return "p"
    }

    private func piezas() -> [Pieza] {
        let t = Self.imagenesAparte(markdown)
        var desde = t.startIndex
        var ultimo = 0
        return Self.bloques(t).enumerated().map { i, b in
            var ini = ultimo, fin = ultimo + b.count
            if let r = t.range(of: b, range: desde..<t.endIndex) {
                ini = t.distance(from: t.startIndex, to: r.lowerBound)
                fin = t.distance(from: t.startIndex, to: r.upperBound)
                desde = r.upperBound
            }
            ultimo = fin
            return Pieza(i: i, texto: b, clase: Self.clase(b), inicio: ini, fin: fin)
        }
    }

    var body: some View {
        // Entre bloques, el `gap-5` (20 px) de claude.ai.
        VStack(alignment: .leading, spacing: 20) {
            ForEach(piezas()) { p in
                if let fades, p.clase == "p" || p.clase == "h" {
                    // Prosa que se escribe: fade por tramo. Sólo recibe los tramos que caen
                    // en él (y el que venía de antes y lo cruza); un bloque ya firme recibe
                    // siempre lo mismo (vacío) y no se repinta cada cuadro.
                    let antes = fades.recientes.last(where: { $0.inicio < p.inicio })
                    let suyas = (antes.map { [$0] } ?? [])
                        + fades.recientes.filter { $0.inicio >= p.inicio && $0.inicio < p.fin }
                    if #available(iOS 18.0, *) {
                        pintar(p.texto)
                            .textRenderer(SweepRenderer(fin: p.fin, recientes: suyas,
                                                        ahora: suyas.isEmpty ? 0 : fades.ahora))
                    } else {
                        pintar(p.texto)
                    }
                } else {
                    pintar(p.texto)
                        .modifier(EntradaSuave(activa: fades != nil))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pintar(_ pieza: String) -> some View {
        let md = Markdown(pieza)
            .markdownTheme(MarkdownUI.Theme.ghosty)
            // El cuerpo de claude.ai, medido en su página y ajustado por bliss: serif (New
            // York, la del sistema) 16.5 pt / 24 de interlineado, peso 400. La respuesta es
            // prosa para leer, no interfaz: tu burbuja, el compositor y el chrome siguen en SF.
            .markdownTextStyle {
                FontFamily(.system(.serif))
                FontSize(Self.cuerpo)
                ForegroundColor(.gInk)
            }
            // ⚠️ Las imágenes del markdown salían **a tamaño real**: una foto de 1200 px
            // se pintaba a 1200 px y desbordaba la burbuja y la pantalla. Se acotan al
            // ancho disponible y a un alto razonable, y con las esquinas del resto.
            .markdownImageProvider(.acotada)
            // ⚠️ Y el INLINE, que es el que faltaba. MarkdownUI tiene DOS proveedores: el
            // de bloque, para una imagen sola en su párrafo, y éste, para una imagen
            // dentro de texto o de una lista —que es justo como las escribe el agente
            // cuando te devuelve resultados de búsqueda—. Con sólo el de bloque, las
            // imágenes de una lista seguían saliendo a tamaño real y desbordando.
            .markdownInlineImageProvider(.acotada)
        // Toque largo → «Copiar» del párrafo. La respuesta entera la copia el botón
        // de `AgentBubble`.
        if seleccionable { md.textSelection(.enabled) } else { md.textSelection(.disabled) }
    }

    /// Tamaño del cuerpo de la respuesta. El resto del tema va en `.em` relativo a él.
    static let cuerpo: CGFloat = 16.5
}

extension MarkdownUI.Theme {
    /// Tema de Ghosty para MarkdownUI. Los tamaños y colores son los mismos que usan
    /// las vistas nativas, así que una burbuja con markdown y una sin él se leen igual.
    ///
    /// Se construye por pasos y no encadenado: encadenar los doce bloques hace que el
    /// verificador de tipos de Swift se rinda («unable to type-check in reasonable time»).
    static var ghosty: MarkdownUI.Theme {
        var t = MarkdownUI.Theme()
        t = inline(t)
        t = encabezados(t)
        t = bloques(t)
        t = tabla(t)
        return t
    }

    private static func inline(_ t: MarkdownUI.Theme) -> MarkdownUI.Theme {
        t
            .text {
                // El tamaño base lo pone la vista (`GhostyMarkdown.cuerpo`); aquí sólo color.
                ForegroundColor(.gInk)
            }
            .code {
                FontFamily(.system(.monospaced))
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.87))
                BackgroundColor(Color.gFillStrong.opacity(0.55))
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(.gPrimary) }
    }

    private static func encabezados(_ t: MarkdownUI.Theme) -> MarkdownUI.Theme {
        t
            .heading1 { config in
                config.label
                    .markdownMargin(top: 6, bottom: 4)
                    .markdownTextStyle { FontSize(.em(1.33)); FontWeight(.semibold) }
            }
            .heading2 { config in
                config.label
                    .markdownMargin(top: 6, bottom: 4)
                    .markdownTextStyle { FontSize(.em(1.2)); FontWeight(.semibold) }
            }
            .heading3 { config in
                config.label
                    .markdownMargin(top: 4, bottom: 2)
                    .markdownTextStyle { FontSize(.em(1.07)); FontWeight(.semibold) }
            }
    }

    private static func bloques(_ t: MarkdownUI.Theme) -> MarkdownUI.Theme {
        t
            .paragraph { config in
                config.label
                    // 24 de línea sobre 16.5 (1.45): la serif ya trae ~1.2; esto pone el
                    // resto. El aire entre párrafos (20) lo pone el `VStack` de bloques.
                    .relativeLineSpacing(.em(0.25))
                    .markdownMargin(top: 0, bottom: 0)
            }
            // Listas de claude.ai: mismo cuerpo y tinta que la prosa, viñeta de tinta.
            .listItem { config in
                config.label
                    .relativeLineSpacing(.em(0.25))
                    .markdownMargin(top: 6)
            }
            .bulletedListMarker { _ in
                Circle()
                    .fill(Color.gInk)
                    .frame(width: 5, height: 5)
                    .relativeFrame(minWidth: .em(1.1), alignment: .leading)
            }
            .blockquote { config in
                HStack(alignment: .top, spacing: 11) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gPrimary.opacity(0.5))
                        .frame(width: 3)
                    config.label
                        .markdownTextStyle {
                            FontStyle(.italic)
                            ForegroundColor(.gInk2)
                        }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .codeBlock { config in
                bloqueDeCodigo(config)
            }
            .thematicBreak {
                Divider().overlay(Color.gSeparator).markdownMargin(top: 8, bottom: 8)
            }
    }

    @ViewBuilder
    private static func bloqueDeCodigo(_ config: CodeBlockConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lenguaje = config.language {
                Text(lenguaje)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.gInk3)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            // Scroll horizontal propio: una línea larga de código no debe ensanchar
            // la burbuja ni partirse a la mitad.
            ScrollView(.horizontal, showsIndicators: false) {
                config.label
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            // Mono del sistema a 0.87 em (no la serif del cuerpo).
            .markdownTextStyle {
                FontFamily(.system(.monospaced))
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.87))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .markdownMargin(top: 6, bottom: 10)
    }

    private static func tabla(_ t: MarkdownUI.Theme) -> MarkdownUI.Theme {
        t
            .table { config in
                // La tarjeta de tabla del diseño, con «Exportar a Excel» y «Copiar». Se
                // arma de las FILAS (no de la vista de MarkdownUI) porque el Excel y el
                // copiar necesitan los datos, y así la tarjeta y el archivo dicen lo mismo.
                let filas = Tabular.deMarkdown(config.content.renderMarkdown())
                if filas.count > 1 {
                    TablaCard(filas: filas)
                        .markdownMargin(top: 4, bottom: 10)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        config.label
                            .fixedSize(horizontal: true, vertical: false)
                            .markdownTableBorderStyle(
                                .init(color: .gSeparator, strokeStyle: .init(lineWidth: 1))
                            )
                    }
                    .markdownMargin(top: 4, bottom: 10)
                }
            }
            .tableCell { config in
                config.label
                    .markdownTextStyle {
                        FontSize(13)
                        if config.row == 0 { FontWeight(.semibold) }
                        ForegroundColor(config.row == 0 ? .gInk3 : .gInk)
                    }
                    .frame(minWidth: 92, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
    }
}


/// Las imágenes de una respuesta, a un tamaño que quepa.
///
/// ⚠️ El proveedor por defecto de MarkdownUI pinta la imagen a su tamaño natural. Con una
/// foto de verdad —las que devuelve una búsqueda— eso es un bloque que se sale de la
/// burbuja y empuja el hilo a lo ancho.
struct ImagenAcotada: ImageProvider {
    func makeImage(url: URL?) -> some View { ImagenDeRespuesta(url: url) }
}

/// Una imagen de una respuesta: acotada y **que se puede tocar**.
///
/// ⚠️ Se carga con `CargadorDeImagen` y no con `AsyncImage` porque el visor necesita el
/// `UIImage`, y `AsyncImage` sólo da un `Image` de SwiftUI que ya no se puede reabrir.
/// Tocar una imagen y que no pase nada es de las cosas que más se sienten rotas: en un
/// teléfono, una imagen que se ve pequeña SIEMPRE se puede abrir.
private struct ImagenDeRespuesta: View {
    let url: URL?
    @Environment(Visor.self) private var visor: Visor?

    @State private var imagen: UIImage?
    @State private var fallo = false

    var body: some View {
        Group {
            // La de memoria se pinta YA: volver al hilo no enseña el hueco con spinner.
            if let imagen = imagen ?? url.flatMap(CargadorDeImagen.enMemoria) {
                ImagenAnimable(imagen, modo: .fit)
                    .frame(maxWidth: 250, maxHeight: 250)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { visor?.abrir(imagen) }
            } else if fallo {
                // No se calla: una imagen que no cargó y no se dice parece un hueco del
                // diseño. Ver la regla de la casa sobre fallos mudos.
                HStack(spacing: 6) {
                    Image(systemName: "photo").font(.system(size: 13))
                    Text("No pude cargar la imagen").gCaption()
                }
                .foregroundStyle(Color.gInk4)
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Color.gFill)
                    .frame(height: 140)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: url) {
            guard let url, imagen == nil else { return }
            if let ya = CargadorDeImagen.enMemoria(url) { imagen = ya; return }
            let i = await CargadorDeImagen.imagen(url)
            imagen = i
            // Cambió de alto (placeholder 140 → imagen real): re-anclar el hilo abajo.
            NotificationCenter.default.post(name: .hiloCrecio, object: nil)
            fallo = i == nil
        }
    }
}

extension ImageProvider where Self == ImagenAcotada {
    static var acotada: ImagenAcotada { ImagenAcotada() }
}


/// Las imágenes que van DENTRO de un texto o de una lista.
///
/// ⚠️ Aquí no se puede envolver en una vista, porque el resultado se compone dentro de un
/// `Text`: el tamaño hay que arreglarlo en los PÍXELES. Se baja la imagen y se redibuja a
/// un ancho máximo, que es lo que la vuelve a meter dentro de la burbuja.
struct ImagenInlineAcotada: InlineImageProvider {
    /// ⚠️ En PUNTOS y del tamaño de la burbuja, no el doble. Con 620 la imagen seguía
    /// saliéndose: una inline se compone dentro del texto con el tamaño que traiga, y si
    /// ese tamaño es mayor que la burbuja, lo que se desborda es la burbuja. También se
    /// acota el ALTO, o una foto vertical ocupa la pantalla entera.
    private static let lado: CGFloat = 250

    func image(with url: URL, label: String) async throws -> Image {
        let (datos, _) = try await URLSession.shared.data(from: url)
        guard let original = UIImage(data: datos) else { throw URLError(.cannotDecodeContentData) }
        let escala = min(Self.lado / original.size.width, Self.lado / original.size.height, 1)
        guard escala < 1 else { return Image(uiImage: original) }

        let destino = CGSize(width: original.size.width * escala,
                             height: original.size.height * escala)
        let render = UIGraphicsImageRenderer(size: destino, format: {
            let f = UIGraphicsImageRendererFormat.default()
            // Escala 1: el tamaño en PUNTOS es el que manda para el ancho de la burbuja.
            f.scale = 1
            return f
        }())
        let chica = render.image { _ in original.draw(in: CGRect(origin: .zero, size: destino)) }
        return Image(uiImage: chica)
    }
}

extension InlineImageProvider where Self == ImagenInlineAcotada {
    static var acotada: ImagenInlineAcotada { ImagenInlineAcotada() }
}
