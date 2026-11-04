import SwiftUI
import UIKit

/// «Seleccionar texto»: la respuesta en un `UITextView` para seleccionar un PEDACITO con la
/// selección del sistema (manijas, lupa, Copiar/Buscar/Traducir/Compartir), como en
/// ChatGPT y Claude.
///
/// ⚠️ No se hizo dentro del hilo porque el `Text` de SwiftUI, aun con
/// `.textSelection(.enabled)`, en iOS sólo ofrece «Copiar» del bloque entero, sin manijas.
/// Pedido de Brendi, 4-nov.
struct SelectTextSheet: View {
    let markdown: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(attributed: SelectableText.render(markdown))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Seleccionar texto")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Listo") { dismiss() }
                            .accessibilityIdentifier("select-text-done")
                    }
                }
        }
        .presentationBackground(Color.gBg)
        .accessibilityIdentifier("select-text-sheet")
    }
}

/// `UITextView` de sólo lectura: se selecciona, no se edita.
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        v.textContainer.lineFragmentPadding = 0
        v.dataDetectorTypes = []
        v.linkTextAttributes = [.foregroundColor: UIColor(Color.gPrimary)]
        v.accessibilityIdentifier = "select-text-view"
        // Abre con TODO seleccionado y las manijas a la vista: se arrastran hasta el pedazo
        // que se quiere. Sin esto hacía falta un segundo toque largo que nadie adivina.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            v.becomeFirstResponder()
            v.selectAll(nil)
        }
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.attributedText != attributed { v.attributedText = attributed }
    }

    /// El markdown a texto con estilo: negritas, itálicas, código y ligas, en el mismo serif
    /// 16.5 / 24 del hilo. Los renglones se respetan tal cual (listas y encabezados quedan
    /// como texto), que es lo que importa al seleccionar.
    static func render(_ markdown: String) -> NSAttributedString {
        let size = GhostyMarkdown.cuerpo
        let serif = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            ?? UIFont.systemFont(ofSize: size).fontDescriptor
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = 24
        para.maximumLineHeight = 24
        para.paragraphSpacing = 8

        // Sin los `#` de los encabezados ni el `>` de las citas: al seleccionar un título no
        // se quiere el gato.
        let limpio = markdown
            .components(separatedBy: "\n")
            .map { renglon in
                renglon
                    .replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression)
                    // Viñeta de verdad en vez del guion del markdown (respeta la sangría).
                    .replacingOccurrences(of: #"^(\s*)[-*+]\s+"#, with: "$1• ", options: .regularExpression)
            }
            .joined(separator: "\n")
        let parsed = (try? AttributedString(
            markdown: limpio,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(limpio)

        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let texto = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            let font: UIFont
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
            } else {
                let d = serif.withSymbolicTraits(traits) ?? serif
                font = UIFont(descriptor: d, size: size)
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor(Color.gInk),
                .paragraphStyle: para,
            ]
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: texto, attributes: attrs))
        }
        return out
    }
}

/// Las respuestas del agente ya no usan el «Copiar» del bloque al dejar presionado: ese toque
/// largo abre `SelectTextSheet`. Ver `AgentBubble`.
private struct MarkdownSelectableKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var markdownSelectable: Bool {
        get { self[MarkdownSelectableKey.self] }
        set { self[MarkdownSelectableKey.self] = newValue }
    }
}
