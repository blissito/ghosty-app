import SwiftUI
import AVKit

/// Un video que el agente entregó, reproducible dentro de la tarjeta.
///
/// Se reproduce por STREAMING con la URL firmada (`api/v2/me/files/:id` → {url}), no se
/// baja entero a memoria: un mp4 de 30 MB no cabe en `entrega.datos` sin pagarlo. Sin
/// autoplay. El cuadro se RESERVA antes de saber nada (16:9) y se ajusta al aspecto real
/// cuando el asset lo dice: así el hilo no crece tarde y el scroll no se queda a medias.
struct ReproductorDeVideo: View {
    let entrega: Entrega
    /// Ancho de la tarjeta; el alto sale del aspecto.
    var ancho: CGFloat = 300

    @State private var player: AVPlayer?
    @State private var aspecto: CGFloat = 16.0 / 9.0
    @State private var fallo: String?
    @State private var archivoParaCompartir: URL?

    private var alto: CGFloat { min(360, ancho / aspecto) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if let fallo {
                    Text(fallo).gCaption().foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: ancho, height: alto)
            .clipped()

            HStack(spacing: 10) {
                TintedIcon(systemName: "film", tint: .gPrimary, background: .gPrimaryTint, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entrega.titulo)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gInk).lineLimit(1)
                    Text([entrega.etiqueta, entrega.peso].compactMap { $0 }.joined(separator: " · ")).gCaption()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Guardar/compartir: se baja al tocar, no antes.
                Button {
                    Task {
                        guard let id = entrega.remotoID, let d = try? await GhostyAPI.bajar(id) else { return }
                        var copia = entrega; copia.datos = d
                        archivoParaCompartir = copia.aDisco()
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gInk2)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Guardar")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .task(id: entrega.id) { await preparar() }
        .onDisappear { player?.pause() }
        .sheet(item: $archivoParaCompartir) { u in
            ShareLink(item: u) { Label("Compartir", systemImage: "square.and.arrow.up") }
                .presentationDetents([.fraction(0.2)])
        }
    }

    private func preparar() async {
        guard player == nil else { return }
        var url: URL?
        if let id = entrega.remotoID, let firmada = try? await GhostyAPI.urlDe(id) { url = URL(string: firmada) }
        else if let u = entrega.url { url = URL(string: u) }
        guard let url else { fallo = "No encuentro el video."; return }
        let asset = AVURLAsset(url: url)
        // El aspecto real, si el asset lo cuenta; si no, se queda el 16:9 reservado.
        if let pista = try? await asset.loadTracks(withMediaType: .video).first,
           let (tam, tr) = try? await pista.load(.naturalSize, .preferredTransform) {
            let real = tam.applying(tr)
            let w = abs(real.width), h = abs(real.height)
            if w > 0, h > 0, abs(w / h - aspecto) > 0.01 {
                aspecto = w / h
                // El cuadro cambió de alto DESPUÉS del primer pintado: que el hilo vuelva a
                // anclarse abajo si estaba siguiendo el final.
                NotificationCenter.default.post(name: .hiloCrecio, object: nil)
            }
        }
        // ⚠️ `.playback`: si la sesión quedó en modo grabación (nota de voz), el video sale
        // por el auricular a volumen mínimo y parece mudo.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

extension Notification.Name {
    /// Algo del hilo creció tarde (video medido, imagen cargada): re-anclar abajo.
    static let hiloCrecio = Notification.Name("gs.hiloCrecio")
}
