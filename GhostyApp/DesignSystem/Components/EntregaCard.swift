import QuickLook
import SwiftUI

/// Lo que el agente entregó, dentro del hilo.
///
/// Es una tarjeta y no una burbuja porque no es algo que dijo: es algo que hizo. Se toca
/// para abrirlo con el visor del sistema, que es lo que el teléfono ya sabe hacer bien
/// con un PDF, una hoja o una página.
struct EntregaCard: View {
    let entrega: Entrega
    @State private var compartiendo: URL?

    var body: some View {
        Button {
            compartiendo = Self.aDisco(entrega)
        } label: {
            HStack(spacing: 12) {
                TintedIcon(systemName: entrega.icono, tint: .gPrimary,
                           background: .gPrimaryTint, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entrega.titulo)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                        .lineLimit(1)
                    Text([entrega.etiqueta, entrega.peso].compactMap { $0 }.joined(separator: " · "))
                        .gCaption()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.gInk3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.gCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .quickLookPreview($compartiendo)
    }

    /// Deja la entrega en un archivo temporal para poder enseñarla.
    ///
    /// ⚠️ El nombre lleva la EXTENSIÓN que toca, y no es cosmético: el visor del sistema
    /// elige con qué abrirlo por el sufijo del archivo, así que un HTML llamado
    /// "informe" se enseña como texto plano.
    private static func aDisco(_ e: Entrega) -> URL? {
        let base = FileManager.default.temporaryDirectory
        let limpio = e.titulo.replacingOccurrences(of: "/", with: "-")
        let sufijo: String
        switch e.forma {
        case .doc:      sufijo = "md"
        case .sheet:    sufijo = "csv"
        case .artifact: sufijo = "html"
        case .archivo:  sufijo = ""
        }
        let nombre = sufijo.isEmpty || limpio.hasSuffix(".\(sufijo)")
            ? limpio : "\(limpio).\(sufijo)"
        let url = base.appending(path: nombre)
        do {
            if let datos = e.datos {
                try datos.write(to: url, options: .atomic)
            } else {
                try (e.contenido ?? "").write(to: url, atomically: true, encoding: .utf8)
            }
            return url
        } catch {
            return nil
        }
    }
}
