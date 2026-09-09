import SwiftUI

/// Un adjunto esperando a que se mande el turno.
///
/// Miniatura de verdad cuando es imagen: reconocer cuál de tres fotos quitaste por su
/// nombre (`foto-2.jpg`) no se puede, y por eso una tira de nombres no sirve aquí.
struct AdjuntoChip: View {
    let adjunto: Adjunto
    var alQuitar: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            miniatura
            VStack(alignment: .leading, spacing: 1) {
                Text(adjunto.nombre)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                Text(adjunto.peso).gCaption()
            }
            Button(action: alQuitar) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.gInk3)
                    .frame(width: 22, height: 22)
                    .background(Color.gFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: 220)
        .background(Color.gCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    @ViewBuilder
    private var miniatura: some View {
        if adjunto.esImagen, let img = UIImage(data: adjunto.datos) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        } else {
            TintedIcon(systemName: adjunto.icono, tint: .gPrimary,
                       background: .gPrimaryTint, size: 34)
        }
    }
}
