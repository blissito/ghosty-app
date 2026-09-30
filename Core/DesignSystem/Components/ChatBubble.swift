import SwiftUI

/// La burbuja de la persona, medida en claude.ai: SF 16/22, padding 12×16, radio 12, gris
/// sutil, ancho al contenido (tope 75 % del hilo), a la derecha. La respuesta del agente va
/// sin burbuja y sin avatar, en serif.
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
        // `max-width: 75%` del hilo.
        .containerRelativeFrame(.horizontal, alignment: .trailing) { ancho, _ in ancho * 0.75 }
    }

    /// El gris de la burbuja: un punto más oscuro que el fondo del hilo (`gBg`), como el
    /// `#F0EEE6` sobre el `#FAF9F5` de claude.ai.
    static let fondo = Color(light: 0xE8E7EE, dark: 0x2A2931)

    private var burbuja: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !adjuntos.isEmpty { loMandado }
            // Mandar SÓLO una foto es normal: sin esto quedaría un hueco de texto vacío
            // debajo de la miniatura.
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 16))
                    // 22 de línea sobre 16: SF trae ~19.
                    .lineSpacing(3)
                    .foregroundStyle(Color.gInk)
                    .textSelection(.enabled)
            }
        }
            .padding(.horizontal, soloVoz ? 0 : 16)
            .padding(.vertical, soloVoz ? 0 : 12)
            // Mismo aire arriba y abajo (el renglón del tiempo siempre está).
            .padding(EdgeInsets(top: soloVoz ? 8 : 0, leading: soloVoz ? 10 : 0,
                                bottom: soloVoz ? 8 : 0, trailing: soloVoz ? 8 : 0))
            .frame(minWidth: soloVoz ? 260 : nil, maxWidth: soloVoz ? 320 : nil)
            .background {
                if soloVoz {
                    // Tu nota como WhatsApp: lime, radios 18 y 4 abajo a la derecha.
                    UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                           bottomTrailingRadius: 4, topTrailingRadius: 18, style: .continuous)
                        .fill(BurbujaDeVoz.limeBurbuja)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Self.fondo)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Sólo una nota de voz, sin texto: va en la burbuja lime.
    private var soloVoz: Bool { text.isEmpty && !adjuntos.isEmpty && adjuntos.allSatisfy(\.esVoz) }
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
                NotaDeVoz(adjunto: a)
                    // El DESTINO del vuelo: la barra de grabación que acabas de soltar se
                    // convierte en esta burbuja en vez de desaparecer y reaparecer.
                    .matchedGeometryEffect(id: "voz-\(a.id)", in: vuelo, isSource: true)
            }
            ForEach(otros) { a in
                // Sobre el gris: icono morado en tarjeta y el texto en tinta.
                HStack(spacing: 9) {
                    TintedIcon(systemName: a.icono, tint: .gPrimary, background: .gCard, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.nombre)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.gInk)
                            .lineLimit(1)
                        Text(a.peso)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.gInk3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Color.gCard.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

/// La respuesta del agente, como claude.ai: sin burbuja ni avatar, lo que hizo (tarjeta de
/// pasos) y lo que dijo (markdown serif a lo ancho, 16.5/24).
struct AgentBubble: View {
    /// El id del mensaje: `TextoAlRitmo` recuerda con él lo ya revelado.
    var id: String = ""
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
    /// Ya no se pinta (claude.ai no pone avatar por respuesta); se conserva la firma.
    var tone: AgentTone? = .lila
    /// La imagen que este turno está creando (o ya entregó): la caja va AQUÍ, en la fila de
    /// la respuesta, y la entrega se revela dentro. `nil` = el turno no hace imágenes.
    var imagen: ImagenDelTurno? = nil
    /// «Editar» de la imagen: el adjunto va al compositor.
    var alEditarImagen: ((Adjunto?) -> Void)? = nil

    private var fuentes: [Fuente] {
        Fuentes.de(texto: [text, trailing ?? ""].joined(separator: "\n"),
                   herramientas: tools?.herramientas ?? [])
    }

    /// La respuesta separada de su narración. Ver `AgentNarration`.
    private var narrated: (steps: [String], rest: String) {
        AgentNarration.split(text, cuts: tools?.narrationCuts ?? [])
    }

    /// Lo que se copia es la respuesta, no los pasos.
    private var fullText: String {
        [narrated.rest, trailing ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                // Los pasos van ARRIBA de la respuesta porque es el orden real: primero
                // trabaja, después contesta.
                // En vivo son renglones sueltos; al terminar, la misma vista se vuelve
                // tarjeta. «Pensando el siguiente paso…» sólo sin herramienta corriendo, sin
                // texto aún y sin la caja de imagen (que ya dice qué pasa).
                // La narración entre herramientas se pinta como pasos, no como respuesta
                // (en vivo por los cortes; al recargar, por las líneas `- ✓` de gs).
                if (tools?.count ?? 0) > 0 || !narrated.steps.isEmpty {
                    let run = tools ?? ToolRun(herramientas: [])
                    PasosDelAgente(run: run, vivo: vivo,
                                   pensando: vivo && narrated.rest.isEmpty && run.corriendo == nil && imagen == nil,
                                   narration: narrated.steps)
                }

                if let imagen { TarjetaCreandoImagen(estado: imagen, alEditar: alEditarImagen) }

                // El texto se suelta a ritmo constante y cada tramo entra con su fade.
                if !narrated.rest.isEmpty { TextoAlRitmo(id: id, texto: narrated.rest, vivo: vivo) }

                if let trailing {
                    GhostyMarkdown(markdown: trailing)
                }

                // Debajo de todo, como en Claude: lo que leyó para contestar.
                BarraDeFuentes(fuentes: fuentes)

                // Copiar la respuesta entera. Sólo cuando ya terminó: copiar media
                // respuesta que sigue creciendo no sirve de nada.
                // ⚠️ Su sitio se RESERVA mientras escribe (invisible): si apareciera al
                // terminar, la respuesta crecería justo al final y el hilo daría un brinco.
                if showCopy, !fullText.isEmpty {
                    CopyButton(text: fullText)
                        .opacity(vivo ? 0 : 1)
                        .allowsHitTesting(!vivo)
                        .accessibilityHidden(vivo)
                }
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
            // Sin avatar, como la respuesta: los puntos van en el margen de la prosa.
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
        // Alto FIJO: al cerrar el turno su hueco lo ocupa uno igual (`ConversationView`).
        .frame(height: TypingBubble.alto)
    }

    static let alto: CGFloat = 28
}
