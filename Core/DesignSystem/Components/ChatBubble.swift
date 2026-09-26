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
                Text("añadido a lo que está haciendo")
                    .gMeta().foregroundStyle(Color.gInk3)
                    .padding(.trailing, 4)
            }
        }
        .frame(maxWidth: 268, alignment: .trailing)
    }

    private var burbuja: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !adjuntos.isEmpty { loMandado }
            // Mandar SÓLO una foto es normal: sin esto quedaría un hueco de texto vacío
            // debajo de la miniatura.
            if !text.isEmpty {
                Text(text)
                    .gBody()
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(Color.gBubbleUser)
            .clipShape(.rect(topLeadingRadius: Theme.Radius.bubble,
                             bottomLeadingRadius: Theme.Radius.bubble,
                             bottomTrailingRadius: 8,
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
                NotaDeVoz(adjunto: a, claro: true)
                    // El DESTINO del vuelo: la barra de grabación que acabas de soltar se
                    // convierte en esta burbuja en vez de desaparecer y reaparecer.
                    .matchedGeometryEffect(id: "voz-\(a.id)", in: vuelo, isSource: true)
            }
            ForEach(otros) { a in
                HStack(spacing: 9) {
                    TintedIcon(systemName: a.icono, tint: .gPrimary, background: .gCard, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.nombre)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Color.gInk)
                            .lineLimit(1)
                        Text(a.peso).gCaption()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct AgentBubble: View {
    let text: String
    let tools: ToolRun?
    let trailing: String?
    /// ¿Hay turno vivo? Lo necesita la línea de pasos para no parecer terminada entre una
    /// herramienta y la siguiente.
    var vivo: Bool = false

    private var fuentes: [Fuente] {
        Fuentes.de(texto: [text, trailing ?? ""].joined(separator: "\n"),
                   herramientas: tools?.herramientas ?? [])
    }

    private var fullText: String {
        [text, trailing ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Los pasos van ARRIBA de la respuesta porque es el orden real: primero
            // trabaja, después contesta. Debajo se leían como una nota al pie de algo que
            // ya habías terminado de leer.
            if let tools { PasosDelAgente(run: tools, abierto: tools.corriendo != nil, vivo: vivo) }

            if !text.isEmpty { TextoQueAparece(markdown: text) }

            if let trailing {
                TextoQueAparece(markdown: trailing)
            }

            // Debajo de todo, como en Claude: lo que leyó para contestar.
            BarraDeFuentes(fuentes: fuentes)

            // Copiar la respuesta entera, como en Claude. Sólo cuando ya terminó: copiar
            // media respuesta que sigue creciendo no sirve de nada.
            if !vivo, !fullText.isEmpty { CopyButton(text: fullText) }
        }
        // Sin burbuja y a todo lo ancho, como el chat de Claude: la respuesta del agente
        // es el cuerpo de la conversación —listas, tablas, código—, y meterla en una
        // burbuja de 300 pt la partía en renglones de tres palabras. La burbuja se queda
        // sólo para lo que escribe la persona, que es lo que hay que distinguir.
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Los tres puntos. Se anima con opacidad y no con escala para que no salte la
/// altura de la fila mientras el agente piensa.
struct TypingBubble: View {
    @State private var fase = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.gInk4)
                    .frame(width: 6, height: 6)
                    .opacity(fase == i ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.gBubbleAgent)
        .clipShape(Capsule())
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.easeInOut(duration: 0.28)) { fase = (fase + 1) % 3 }
            }
        }
    }
}
