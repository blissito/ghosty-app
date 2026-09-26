import SwiftUI

/// El markdown del agente, con los párrafos NUEVOS entrando como en Claude: opacidad de
/// 0 a 1, un desenfoque corto que se disuelve y un empujón de 4 pt hacia arriba.
///
/// ⚠️ Se anima por PÁRRAFO y no por palabra a propósito. El markdown lo pinta MarkdownUI
/// y se recompone entero en cada trozo del stream: animar el bloque completo haría
/// parpadear toda la respuesta veinte veces por segundo, y trocear el texto en palabras
/// obligaría a renderizar el markdown a mano otra vez (las 340 líneas que ya se tiraron
/// una vez, ver `GhostyMarkdown`).
///
/// ⚠️ Y sólo entran animados los párrafos que LLEGAN con la vista ya en pantalla. Al
/// abrir una conversación vieja los que ya estaban se pintan de una: si no, cada vez que
/// entras al hilo la respuesta entera se te aparece encima, que no es bonito, es un
/// anuncio.
struct TextoQueAparece: View {
    let markdown: String

    /// Cuántos párrafos había cuando esta vista nació. Los de más allá son nuevos.
    @State private var yaEstaban: Int?

    /// Los bloques que se animan por separado.
    ///
    /// ⚠️ No vale partir por `\n\n` a secas: un bloque de código con una línea en blanco
    /// dentro se partiría en dos recuadros, y una lista cuyos elementos van separados por
    /// aire se convertiría en varias listas de un elemento —con su propia viñeta y su
    /// propio margen—. Se respetan las vallas ``` y los elementos de lista se quedan
    /// juntos.
    private var parrafos: [String] {
        var bloques: [String] = []
        var actual: [String] = []
        var enCodigo = false

        func cerrar() {
            let t = actual.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.isEmpty { bloques.append(t) }
            actual = []
        }

        let lineas = markdown.components(separatedBy: "\n")
        for (i, linea) in lineas.enumerated() {
            let limpia = linea.trimmingCharacters(in: .whitespaces)
            if limpia.hasPrefix("```") {
                enCodigo.toggle()
                actual.append(linea)
                if !enCodigo { cerrar() }
                continue
            }
            if !enCodigo, limpia.isEmpty {
                // Aire entre dos elementos de lista: es la MISMA lista.
                let siguiente = lineas[(i + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if esDeLista(actual.last), esDeLista(siguiente) {
                    actual.append(linea)
                } else {
                    cerrar()
                }
                continue
            }
            actual.append(linea)
        }
        cerrar()
        return bloques
    }

    private func esDeLista(_ linea: String?) -> Bool {
        guard let l = linea?.trimmingCharacters(in: .whitespaces), !l.isEmpty else { return false }
        if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") { return true }
        // «1. », «12) »
        let cabeza = l.prefix { $0.isNumber }
        return !cabeza.isEmpty && (l.dropFirst(cabeza.count).hasPrefix(". ")
                                   || l.dropFirst(cabeza.count).hasPrefix(") "))
    }

    /// Sólo la prosa se revela palabra por palabra. En una lista cada renglón es un `Text`
    /// aparte que cuenta sus letras desde cero, y el barrido se desfasaría entre renglones;
    /// código y tablas se leen mejor enteros. Ésos siguen entrando por bloque.
    private func esProsa(_ bloque: String) -> Bool {
        let l = bloque.trimmingCharacters(in: .whitespaces)
        return !(l.hasPrefix("```") || l.hasPrefix("|") || l.hasPrefix(">") || esDeLista(l))
    }

    var body: some View {
        let bloques = parrafos
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(bloques.enumerated()), id: \.offset) { i, bloque in
                GrowingBlock(markdown: bloque, sweeps: esProsa(bloque),
                             animated: i >= (yaEstaban ?? 0))
                    .transition(.modifier(active: Aparicion(entrando: true),
                                          identity: Aparicion(entrando: false)))
                    .id(i)
                    // El párrafo que ya estaba no tiene por qué animarse otra vez.
                    .animation(i >= (yaEstaban ?? 0) ? .easeOut(duration: 0.32) : nil,
                               value: bloques.count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if yaEstaban == nil { yaEstaban = bloques.count } }
    }
}

/// El estado "todavía no está aquí": transparente, desenfocado y un poco más abajo.
private struct Aparicion: ViewModifier {
    let entrando: Bool

    func body(content: Content) -> some View {
        content
            .opacity(entrando ? 0 : 1)
            .blur(radius: entrando ? 3 : 0)
            .offset(y: entrando ? 4 : 0)
    }
}

/// Un bloque que, mientras crece, revela sus letras nuevas con un barrido suave: las ya
/// dichas quedan firmes y las que llegan suben de transparentes a opacas en una ventana de
/// ~12 letras. Es el efecto de claude.ai.
///
/// ⚠️ Cuenta letras del texto YA pintado (sin la sintaxis de markdown), porque el renderer
/// numera glifos, no caracteres de la fuente. `AttributedString(markdown:)` quita lo mismo
/// que MarkdownUI en una línea de prosa; una diferencia de un par de letras sólo corre el
/// borde del barrido, nunca esconde texto: al terminar la animación `shown` es el total.
private struct GrowingBlock: View {
    let markdown: String
    let sweeps: Bool
    /// Falso = el bloque ya estaba al abrir la conversación: se pinta completo, sin barrido.
    let animated: Bool

    @State private var shown: Double?

    private var total: Double {
        let plano = (try? AttributedString(markdown: markdown,
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? markdown
        // + la ventana: el barrido tiene que pasarse del final, o las últimas letras se
        // quedarían a medio aparecer para siempre.
        return Double(plano.count) + SweepWindow.letters
    }

    var body: some View {
        if #available(iOS 18.0, *), sweeps {
            GhostyMarkdown(markdown: markdown)
                .textRenderer(SweepRenderer(shown: shown ?? total))
                .onAppear {
                    guard shown == nil else { return }
                    if animated {
                        shown = 0
                        reveal(to: total)
                    } else {
                        shown = total
                    }
                }
                .onChange(of: markdown) { reveal(to: total) }
        } else {
            GhostyMarkdown(markdown: markdown)
        }
    }

    /// Más letras nuevas = un poco más de tiempo, con techo: un trozo grande del stream no
    /// puede tardar en aparecer más de lo que tardó en llegar el siguiente.
    private func reveal(to target: Double) {
        let delta = max(0, target - (shown ?? 0))
        withAnimation(.easeOut(duration: min(0.9, 0.25 + delta / 160))) { shown = target }
    }
}

/// Letras que ocupa el degradado del borde del barrido.
private enum SweepWindow { static let letters = 12.0 }

@available(iOS 18.0, *)
private struct SweepRenderer: TextRenderer {
    var shown: Double

    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var i = 0.0
        for line in layout {
            for run in line {
                for glyph in run {
                    let alpha = min(1, max(0, (shown - i) / SweepWindow.letters))
                    if alpha >= 1 {
                        ctx.draw(glyph)
                    } else if alpha > 0 {
                        var c = ctx
                        c.opacity = alpha
                        c.draw(glyph)
                    }
                    i += 1
                }
            }
        }
    }
}
