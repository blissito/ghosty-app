import SwiftUI

// El texto del agente entrando como en claude.ai, con los números MEDIDOS en su página
// (DOM + `getAnimations`, 2026-09-27): el cliente trocea el stream en TRAMOS de ~16–21
// letras cortados en límite de palabra y suelta uno cada ~130 ms (≈ 130 letras/s), parejo
// aunque la red llegue a ráfagas. Cada tramo entra con opacidad 0→1 LINEAL de 400 ms, sin
// delay, y se queda en 1: nada de desenfoque, desplazamiento ni máscara. Los tramos se
// solapan (varios fundiendo a la vez): de ahí la ola. Lo ya revelado no se re-anima, y al
// terminar el stream el resto aparece de una.
//
// Es el mismo que el de la Mac (`ghosty-notch/GhostyNotch/Chat/TextoQueAparece.swift`).
// Sustituye al barrido por glifos y al fade por párrafo con desenfoque que había aquí.

/// Un tramo ya soltado que todavía está entrando: dónde empieza (en letras del texto
/// fuente) y cuándo se soltó.
struct PalabraQueEntra: Equatable, Sendable {
    let inicio: Int
    let t: Double
}

/// Lo que el markdown necesita para pintar los fades por tramo.
struct FadesDePalabra: Equatable {
    var recientes: [PalabraQueEntra]
    var ahora: Double
    /// 400 ms lineal, como `_animating` de claude.ai.
    static let duracion = 0.4
}

/// La respuesta que se está escribiendo, al ritmo de claude.ai.
///
/// ⚠️ Desacopla la RED del PINTADO: lo llegado se guarda y se suelta en tramos de ~20
/// letras (cortados en límite de palabra) cada ~130 ms; si el atraso pasa de ~300 letras,
/// el intervalo se acorta en proporción. Cada tramo lleva su hora y su fade de 400 ms
/// (`SweepRenderer`). Al cerrar el turno lo que falte entra de una, como UN tramo con su
/// fade. Una respuesta que ya estaba al abrir el hilo se pinta entera, sin fade.
struct TextoAlRitmo: View {
    /// El id del mensaje: con él se recuerda lo ya soltado si la vista se rehace a media
    /// respuesta (volver de otra pestaña construye el hilo de cero).
    let id: String
    let texto: String
    let vivo: Bool

    /// Letras del texto ya soltadas. `nil` = no se anima (la respuesta ya estaba).
    @State private var soltado: Int?
    @State private var recientes: [PalabraQueEntra] = []
    @State private var ahora: Double = 0
    /// Cuándo se soltó el último tramo.
    @State private var ultimoTramo: Double = 0

    private struct Llave: Equatable { let largo: Int; let vivo: Bool }

    static let letrasPorTramo = 20
    static let intervalo = 0.13

    var body: some View {
        Group {
            if let soltado {
                GhostyMarkdown(markdown: String(texto.prefix(soltado)),
                               fades: FadesDePalabra(recientes: recientes, ahora: ahora),
                               // Mientras entra no se selecciona: la capa de selección puede
                               // pintar el `Text` por su camino y saltarse el renderer.
                               seleccionable: !(vivo || soltado < texto.count || !recientes.isEmpty))
            } else {
                GhostyMarkdown(markdown: texto)
            }
        }
        .onAppear {
            guard soltado == nil, vivo else { return }
            // ⚠️ Lo que ya se soltó antes de que la vista se rehiciera NO se vuelve a revelar.
            soltado = min(texto.count, Memoria.soltado[id] ?? 0)
        }
        .task(id: Llave(largo: texto.count, vivo: vivo)) { await avanzar() }
    }

    /// El final del siguiente tramo desde `desde`: ~20 letras cortadas en el primer límite
    /// de palabra después (con el espacio que sigue). `nil` si mientras el turno vive no hay
    /// una palabra COMPLETA que soltar (la última puede estar a medias).
    private static func finDeTramo(_ c: [Character], desde: Int, completa: Bool) -> Int? {
        guard desde < c.count else { return nil }
        var i = desde
        var ultimoLimite: Int?
        while i < c.count {
            // Avanza una palabra: blancos, letras y los blancos que la siguen (sin pasar de
            // un salto de línea, que abre bloque).
            while i < c.count, c[i].isWhitespace { i += 1 }
            while i < c.count, !c[i].isWhitespace { i += 1 }
            if i >= c.count { break }
            while i < c.count, c[i].isWhitespace, c[i] != "\n" { i += 1 }
            ultimoLimite = i
            if i - desde >= letrasPorTramo { return i }
        }
        // Llegó al final del texto: la última palabra puede estar a medias.
        return completa ? ultimoLimite : c.count
    }

    private func avanzar() async {
        guard soltado != nil else { return }
        let letras = Array(texto)
        // Turno cerrado: el resto aparece de una, como claude.ai — como UN tramo con su
        // fade de 400 ms, para que un párrafo entero no brote seco.
        if !vivo, let s = soltado, s < letras.count {
            let t = Date().timeIntervalSinceReferenceDate
            recientes = recientes.filter { t - $0.t < FadesDePalabra.duracion } + [PalabraQueEntra(inicio: s, t: t)]
            soltado = letras.count
            ultimoTramo = t
        }
        while !Task.isCancelled {
            guard var s = soltado else { return }
            let t = Date().timeIntervalSinceReferenceDate
            let atraso = letras.count - s
            // Muy atrasado (> ~300 letras): tramos más seguidos, en proporción.
            let cada = atraso > 300 ? max(0.03, Self.intervalo * 300 / Double(atraso)) : Self.intervalo
            var nuevas: [PalabraQueEntra] = []
            if t - ultimoTramo >= cada, let fin = Self.finDeTramo(letras, desde: s, completa: vivo), fin > s {
                nuevas.append(PalabraQueEntra(inicio: s, t: t))
                s = fin
                ultimoTramo = t
            }
            let vigentes = recientes.filter { t - $0.t < FadesDePalabra.duracion } + nuevas
            if s != soltado { soltado = s }
            if vigentes != recientes { recientes = vigentes }
            ahora = t
            if vivo { Memoria.soltado[id] = s } else { Memoria.soltado[id] = nil }
            // Nada que soltar ni fade en curso: se duerme hasta que llegue más texto (la
            // tarea se rehace al cambiar el largo o `vivo`).
            let quedan = Self.finDeTramo(letras, desde: s, completa: vivo) != nil
            if !quedan, vigentes.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}

/// Lo soltado de cada respuesta viva, por id: sobrevive a que la vista se rehaga.
@MainActor
private enum Memoria {
    static var soltado: [String: Int] = [:]
}

/// Entrada de un bloque que no es prosa (lista, código, tabla) en una respuesta que se
/// escribe: sólo opacidad, 400 ms lineal. Sin desenfoque ni desplazamiento: no mueve el
/// layout.
struct EntradaSuave: ViewModifier {
    let activa: Bool
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(!activa || visible ? 1 : 0)
            .onAppear {
                guard activa, !visible else { return }
                withAnimation(.linear(duration: FadesDePalabra.duracion)) { visible = true }
            }
    }
}

/// El fade por tramo: a cada glifo le toca el tramo en el que cae (por su posición en el
/// texto fuente, contada desde el final del bloque) y su opacidad es
/// `(ahora − cuándo se soltó ese tramo) / 400 ms`, lineal.
///
/// ⚠️ El renderer numera GLIFOS y no letras del markdown: la sintaxis (`**`, `` ` ``)
/// no se pinta. Contando desde el FINAL del bloque la diferencia sólo afecta a lo que va
/// antes de una marca, y como mucho corre el fade una o dos letras: nunca esconde texto.
@available(iOS 18.0, *)
struct SweepRenderer: TextRenderer {
    /// Letra (en el texto fuente) donde acaba este bloque.
    var fin: Int
    /// Los tramos que están entrando, ordenados por `inicio`.
    var recientes: [PalabraQueEntra]
    var ahora: Double

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        guard !recientes.isEmpty else {
            for line in layout { for run in line { for glyph in run { ctx.draw(glyph) } } }
            return
        }
        var total = 0
        for line in layout { for run in line { total += run.count } }
        var i = 0
        for line in layout {
            for run in line {
                for glyph in run {
                    let o = fin - (total - i)
                    var alpha = 1.0
                    if let p = recientes.last(where: { $0.inicio <= o }) {
                        // Lineal, como claude.ai.
                        alpha = min(1, max(0, (ahora - p.t) / FadesDePalabra.duracion))
                    }
                    if alpha >= 0.999 {
                        ctx.draw(glyph)
                    } else if alpha > 0.001 {
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
