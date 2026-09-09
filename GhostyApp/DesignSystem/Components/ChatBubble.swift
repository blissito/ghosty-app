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

    var body: some View {
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
            .frame(maxWidth: 268, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// La burbuja del agente renderiza **markdown**, no texto plano: lo que la caja
/// manda trae encabezados, listas, tablas y bloques de código, y verlo con los
/// asteriscos crudos es exactamente la queja que originó este trabajo.
extension UserBubble {
    /// Las imágenes en rejilla y lo demás en fila. Una sola imagen manda a lo ancho; varias
    /// van en dos columnas para que no crezca la burbuja sin control.
    @ViewBuilder
    fileprivate var loMandado: some View {
        let imagenes = adjuntos.compactMap { a -> (Adjunto, UIImage)? in
            guard a.esImagen, let i = UIImage(data: a.datos) else { return nil }
            return (a, i)
        }
        let voces = adjuntos.filter(\.esVoz)
        let otros = adjuntos.filter { !$0.esImagen && !$0.esVoz }

        VStack(alignment: .leading, spacing: 6) {
            if imagenes.count == 1 {
                let img = imagenes[0].1
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    // ⚠️ Se acota tanto por arriba COMO por el tamaño real: `resizable` a
                    // secas agranda lo que sea hasta llenar el ancho, y una imagen chica
                    // acababa como un bloque gigante y pixelado. Que se vea pequeña si es
                    // pequeña es la verdad.
                    .frame(maxWidth: min(238, img.size.width),
                           maxHeight: min(180, img.size.height))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            } else if imagenes.count > 1 {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                    GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(imagenes, id: \.0.id) { _, img in
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(height: 86)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                    }
                }
            }
            ForEach(voces) { a in
                NotaDeVoz(adjunto: a, claro: true)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GhostyMarkdown(markdown: text)

            if let tools {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.gGreen)
                        .frame(width: 18, height: 18)
                        .overlay {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    Text("Corrió \(tools.count) herramientas").gMeta()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gInk4)
                }
            }

            if let trailing {
                GhostyMarkdown(markdown: trailing)
            }
        }
        .padding(15)
        .background(Color.gBubbleAgent)
        .clipShape(.rect(topLeadingRadius: Theme.Radius.bubble,
                         bottomLeadingRadius: 8,
                         bottomTrailingRadius: Theme.Radius.bubble,
                         topTrailingRadius: Theme.Radius.bubble,
                         style: .continuous))
        .frame(maxWidth: 300, alignment: .leading)
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
