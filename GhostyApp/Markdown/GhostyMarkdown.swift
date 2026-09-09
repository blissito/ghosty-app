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

    var body: some View {
        Markdown(markdown)
            .markdownTheme(MarkdownUI.Theme.ghosty)
            .markdownTextStyle {
                FontSize(16)
                ForegroundColor(.gInk)
            }
    }
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
                FontSize(16)
                ForegroundColor(.gInk)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                BackgroundColor(.gFill)
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(.gPrimary) }
    }

    private static func encabezados(_ t: MarkdownUI.Theme) -> MarkdownUI.Theme {
        t
            .heading1 { config in
                config.label
                    .markdownMargin(top: 6, bottom: 4)
                    .markdownTextStyle { FontSize(21); FontWeight(.semibold) }
            }
            .heading2 { config in
                config.label
                    .markdownMargin(top: 6, bottom: 4)
                    .markdownTextStyle { FontSize(19); FontWeight(.semibold) }
            }
            .heading3 { config in
                config.label
                    .markdownMargin(top: 4, bottom: 2)
                    .markdownTextStyle { FontSize(17); FontWeight(.semibold) }
            }
    }

    private static func bloques(_ t: MarkdownUI.Theme) -> MarkdownUI.Theme {
        t
            .paragraph { config in
                config.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: 0, bottom: 10)
            }
            .listItem { config in
                config.label.markdownMargin(top: 4)
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
            .markdownTextStyle {
                FontFamilyVariant(.monospaced)
                FontSize(13.5)
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
                // La tabla es el bloque que más se rompe en un teléfono: sin scroll,
                // tres columnas ya desbordan y el texto se apila.
                ScrollView(.horizontal, showsIndicators: false) {
                    config.label
                        .fixedSize(horizontal: true, vertical: false)
                        .markdownTableBorderStyle(
                            .init(color: .gSeparator, strokeStyle: .init(lineWidth: 1))
                        )
                }
                .markdownMargin(top: 4, bottom: 10)
            }
            .tableCell { config in
                config.label
                    .markdownTextStyle {
                        FontSize(14)
                        if config.row == 0 { FontWeight(.semibold) }
                        ForegroundColor(config.row == 0 ? .gInk : .gInk2)
                    }
                    .frame(minWidth: 92, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
    }
}
