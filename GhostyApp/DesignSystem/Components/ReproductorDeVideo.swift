import SwiftUI
import AVKit
import Photos

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
    /// Cómo va el guardado en Fotos: bajando, «Guardado en Fotos», o el fallo.
    @State private var guardando = false
    @State private var avisoGuardado: String?
    @State private var intentos = 0

    private var alto: CGFloat { min(360, ancho / aspecto) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if let fallo {
                    Text(fallo).gCaption().foregroundStyle(.white.opacity(0.8))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            intentos += 1; self.fallo = nil
                            Task { await preparar() }
                        }
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
                // ⚠️ GUARDAR EN FOTOS, no «compartir». Antes era un icono de 32 pt que
                // abría una hoja con un ShareLink dentro: al toque no le atinabas y, cuando
                // sí, el video acababa en Archivos, no en la galería, que es donde se
                // quiere para usarlo en otras apps. Ahora se baja y va a Fotos directo.
                Button { Task { await guardarEnFotos() } } label: {
                    ZStack {
                        if guardando { ProgressView().controlSize(.small) }
                        else {
                            Image(systemName: avisoGuardado == "Guardado en Fotos" ? "checkmark" : "arrow.down.to.line")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.gInk)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(Color.gFill, in: Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("guardar-video")
                .accessibilityLabel("Guardar en Fotos")
                // Compartir sigue disponible con toque largo (mandarlo por WhatsApp, etc.).
                .contextMenu {
                    Button { Task { await compartir() } } label: { Label("Compartir…", systemImage: "square.and.arrow.up") }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            if let avisoGuardado {
                Text(avisoGuardado).gCaption()
                    .foregroundStyle(avisoGuardado == "Guardado en Fotos" ? Color.gGreenInk : Color.gDangerInk)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .task(id: entrega.id) { await preparar() }
        .onDisappear { player?.pause() }
        .sheet(item: $archivoParaCompartir) { u in
            ShareLink(item: u) { Label("Compartir", systemImage: "square.and.arrow.up") }
                .presentationDetents([.fraction(0.2)])
        }
    }

    /// Los bytes del video: del archivo de la cuenta (firma fresca) o de la URL anunciada.
    private func bytes() async -> Data? {
        if let d = entrega.datos { return d }
        if let id = entrega.remotoID, let d = try? await GhostyAPI.bajar(id) { return d }
        if let s = entrega.url, let u = URL(string: s) { return await Descargas.bytes(u) }
        return nil
    }

    private func guardarEnFotos() async {
        guard !guardando else { return }
        guardando = true; defer { guardando = false }
        guard let d = await bytes() else { avisoGuardado = "Ese enlace ya no sirve."; return }
        var copia = entrega; copia.datos = d
        guard let archivo = copia.aDisco() else { avisoGuardado = "No pude guardarlo."; return }
        let permiso = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permiso == .authorized || permiso == .limited else {
            avisoGuardado = "Sin permiso para Fotos. Actívalo en Ajustes."; return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: archivo)
            }
            avisoGuardado = "Guardado en Fotos"
        } catch {
            avisoGuardado = "No pude guardarlo en Fotos."
        }
    }

    private func compartir() async {
        guard let d = await bytes() else { avisoGuardado = "Ese enlace ya no sirve."; return }
        var copia = entrega; copia.datos = d
        archivoParaCompartir = copia.aDisco()
    }

    private func preparar() async {
        guard player == nil else { return }
        var url: URL?
        if let id = entrega.remotoID, let firmada = try? await GhostyAPI.urlDe(id) { url = URL(string: firmada) }
        else if let u = entrega.url { url = URL(string: u) }
        guard let url else { fallo = "No encuentro el video."; return }
        let asset = AVURLAsset(url: url)
        // ⚠️ Si el asset no carga (firma caducada, red), NO se monta un reproductor
        // mudo: se dice y se puede reintentar con una URL fresca tocando el cuadro. Era
        // el «a veces reproduce y a veces no».
        if (try? await asset.load(.isPlayable)) != true {
            fallo = intentos == 0 ? "No cargó. Toca para reintentar." : "Ese enlace ya no sirve."
            return
        }
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
