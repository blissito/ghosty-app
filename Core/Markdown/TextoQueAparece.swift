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

    var body: some View {
        let bloques = parrafos
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(bloques.enumerated()), id: \.offset) { i, bloque in
                GhostyMarkdown(markdown: bloque)
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
