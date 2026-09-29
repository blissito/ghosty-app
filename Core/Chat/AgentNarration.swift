import Foundation

/// Narración intercalada: lo que el agente dice ANTES de cada herramienta («Reviso tus
/// archivos.», «Armo el calendario.») es avance, no respuesta. Se pinta como pasos encima
/// de la respuesta final, como claude.ai y el chat web.
///
/// Port de `partirNarracion` de gs (`app/lib/narracion.ts`): si cambia allá, cambia aquí.
/// Dos fuentes, mismo resultado:
/// - En vivo: dónde arrancó cada herramienta dentro del texto (`ToolRun.narrationCuts`).
/// - Al recargar: gs guarda esa narración como líneas `- ✓ …` al inicio del mensaje. Sin
///   esto la app las pintaba como una lista con palomitas LITERALES delante de la respuesta
///   (2026-09-28, la conversación de Brenda).
enum AgentNarration {
    /// Un tramo es narración si es corto y de un solo párrafo; si no, es texto normal.
    static func isNarration(_ segment: String) -> Bool {
        let t = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.count <= 300
            && t.range(of: #"\n\s*\n"#, options: .regularExpression) == nil
            && !t.contains("```")
    }

    static func split(_ text: String, cuts: [Int] = []) -> (steps: [String], rest: String) {
        if !cuts.isEmpty {
            let valid = cuts.filter { $0 > 0 && $0 <= text.count }
            guard !valid.isEmpty else { return ([], text) }
            var segments: [String] = []
            var from = 0
            for cut in valid where cut > from {
                let segment = slice(text, from, cut).trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty { segments.append(segment) }
                from = cut
            }
            guard segments.allSatisfy(isNarration) else { return ([], text) }
            let rest = String(slice(text, from, text.count).drop(while: \.isWhitespace))
            return (segments.map(oneLine), rest)
        }
        let lines = text.components(separatedBy: "\n")
        var steps: [String] = []
        for line in lines {
            guard line.hasPrefix("- ✓ ") else { break }
            let step = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard !step.isEmpty else { break }
            steps.append(step)
        }
        guard !steps.isEmpty else { return ([], text) }
        let rest = lines.dropFirst(steps.count).joined(separator: "\n")
        return (steps, String(rest.drop(while: \.isWhitespace)))
    }

    private static func slice(_ text: String, _ from: Int, _ to: Int) -> Substring {
        let a = text.index(text.startIndex, offsetBy: from)
        let b = text.index(text.startIndex, offsetBy: to)
        return text[a..<b]
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
    }
}
