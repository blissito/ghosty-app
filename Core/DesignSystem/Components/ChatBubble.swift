import SwiftUI

struct UserBubble: View {
    let text: String
    /// Lo que se mandó con el mensaje.
    ///
    /// ⚠️ Van los ADJUNTOS, no sus nombres. Enseñar «foto-1.jpg» no dice qué mandaste —de
    /// tres fotos del carrete no distingues cuál—, y la burbuja es `Text` plano, así que
    /// cualquier maquillaje del nombre (backticks, un 📎) sale literal o como un cuadro con
    /// interrogación. Ya pasaron las dos cosas.
    var adjuntos: [Adjunto] = []
    /// El espacio donde vuela una nota de voz recién soltada. Ver `ConversationView`.
    var vuelo: Namespace.ID
    /// Se mandó con el turno ya corriendo y ENTRÓ en él. Se dice, porque no abrió un turno
    /// nuevo: corrigió el que había, y si no se dijera parecería que se ignoró.
    var steer = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            burbuja
            if steer {
                Label("Añadido a lo que está haciendo", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.gInk3)
                    .padding(.trailing, 4)
            }
        }
        // `max-width: 78%` del hilo.
        .containerRelativeFrame(.horizontal, alignment: .trailing) { ancho, _ in ancho * 0.78 }
    }

    /// `#5B4BD6`, blanco `400 15px/1.4`, padding 10/14 y radios 20/20/6/20: la esquina
    /// de abajo a la derecha apunta a quien habló.
    private var burbuja: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !adjuntos.isEmpty { loMandado }
            // Mandar SÓLO una foto es normal: sin esto quedaría un hueco de texto vacío
            // debajo de la miniatura.
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .textSelection(.enabled)
            }
        }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.gPrimary)
            .clipShape(.rect(topLeadingRadius: Theme.Radius.bubble,
                             bottomLeadingRadius: Theme.Radius.bubble,
                             bottomTrailingRadius: 6,
                             topTrailingRadius: Theme.Radius.bubble,
                             style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// El agente renderiza **markdown**, no texto plano: lo que la caja
/// manda trae encabezados, listas, tablas y bloques de código, y verlo con los
/// asteriscos crudos es exactamente la queja que originó este trabajo.
extension UserBubble {
    /// Las imágenes en rejilla y lo demás en fila. Una sola imagen manda a lo ancho; varias
    /// van en dos columnas para que no crezca la burbuja sin control.
    @ViewBuilder
    fileprivate var loMandado: some View {
        let imagenes = adjuntos.filter(\.esImagen)
        let voces = adjuntos.filter(\.esVoz)
        let otros = adjuntos.filter { !$0.esImagen && !$0.esVoz }

        VStack(alignment: .leading, spacing: 6) {
            if imagenes.count == 1 {
                ImagenDeAdjunto(adjunto: imagenes[0], alto: 140) { img in
                    Image(uiImage: img)
                        .resizable().scaledToFit()
                        // ⚠️ Se acota tanto por arriba COMO por el tamaño real: `resizable` a
                        // secas agranda lo que sea hasta llenar el ancho, y una imagen chica
                        // acababa como un bloque gigante y pixelado. Que se vea pequeña si es
                        // pequeña es la verdad.
                        .frame(maxWidth: min(238, img.size.width),
                               maxHeight: min(180, img.size.height))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                }
            } else if imagenes.count > 1 {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                    GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(imagenes) { a in
                        ImagenDeAdjunto(adjunto: a, alto: 86) { img in
                            Image(uiImage: img)
                                .resizable().scaledToFill()
                                .frame(height: 86)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                        }
                    }
                }
            }
            ForEach(voces) { a in
                NotaDeVoz(adjunto: a, sobreMorado: true)
                    // El DESTINO del vuelo: la barra de grabación que acabas de soltar se
                    // convierte en esta burbuja en vez de desaparecer y reaparecer.
                    .matchedGeometryEffect(id: "voz-\(a.id)", in: vuelo, isSource: true)
            }
            ForEach(otros) { a in
                // Sobre el morado: icono en blanco con tinta morada y el texto en blanco.
                HStack(spacing: 9) {
                    TintedIcon(systemName: a.icono, tint: .gPrimary, background: .white, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.nombre)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(a.peso)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

/// La respuesta del agente: columna con su avatar de 28 y, a la derecha, lo que hizo
/// (tarjeta de pasos) y lo que dijo (markdown a lo ancho, `400 15px/1.5`).
struct AgentBubble: View {
    let text: String
    let tools: ToolRun?
    let trailing: String?
    /// ¿Hay turno vivo? Lo necesita la tarjeta de pasos para no parecer terminada entre
    /// una herramienta y la siguiente.
    var vivo: Bool = false
    /// El botón de copiar va sólo en la ÚLTIMA respuesta, como en claude.ai: uno bajo
    /// cada mensaje se volvía una columna de iconos. Las demás se copian por párrafo con
    /// toque largo.
    var showCopy: Bool = true
    /// El avatar de la columna. `nil` = sin avatar (la columna queda, para alinear).
    var tone: AgentTone? = .lila

    private var fuentes: [Fuente] {
        Fuentes.de(texto: [text, trailing ?? ""].joined(separator: "\n"),
                   herramientas: tools?.herramientas ?? [])
    }

    private var fullText: String {
        [text, trailing ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ColumnaDelAgente(tone: tone)
            VStack(alignment: .leading, spacing: 10) {
                // Los pasos van ARRIBA de la respuesta porque es el orden real: primero
                // trabaja, después contesta.
                if let tools, tools.count > 0 {
                    PasosDelAgente(run: tools, abierto: tools.corriendo != nil, vivo: vivo)
                }

                if !text.isEmpty { TextoQueAparece(markdown: text) }

                if let trailing {
                    TextoQueAparece(markdown: trailing)
                }

                // Debajo de todo, como en Claude: lo que leyó para contestar.
                BarraDeFuentes(fuentes: fuentes)

                // Copiar la respuesta entera. Sólo cuando ya terminó: copiar media
                // respuesta que sigue creciendo no sirve de nada.
                if showCopy, !vivo, !fullText.isEmpty { CopyButton(text: fullText) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// La columna del agente: su avatar de 28, o el hueco si no toca pintarlo.
struct ColumnaDelAgente: View {
    var tone: AgentTone?
    var body: some View {
        Group {
            if let tone { AgentAvatar(tone: tone, size: 28) } else { Color.clear }
        }
        .frame(width: 28, height: 28)
    }
}

/// Copia el markdown de la respuesta y confirma con una palomita un momento.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy(duration: 0.2)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.snappy(duration: 0.2)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(copied ? Color.gPrimary : Color.gInk3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("copy-response")
        .accessibilityLabel(copied ? "Copiado" : "Copiar respuesta")
        .padding(.leading, -6)
        .padding(.top, -6)
    }
}

/// «Pensando»: la columna del agente con los tres puntos morados (`gdot`) y, si la hay,
/// una línea con lo que hace. Es el indicador del turno vivo al pie del hilo.
struct TypingBubble: View {
    var tone: AgentTone? = .lila
    var texto: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ColumnaDelAgente(tone: tone)
            GhostyDots()
            if let texto {
                Text(texto)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.gInk3)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: texto)
            }
            Spacer(minLength: 0)
        }
    }
}
