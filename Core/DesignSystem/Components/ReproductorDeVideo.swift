import UniformTypeIdentifiers
import SwiftUI
import AVKit
import Photos
import Network

/// Un video que el agente entregó, reproducible dentro de la tarjeta.
///
/// **Volver al hilo pinta al instante.** Antes cada visita montaba un `AVPlayer` nuevo con
/// firma nueva y el cuadro se quedaba en spinner hasta que el asset contestaba. Ahora:
/// - La PORTADA (primer cuadro), duración y aspecto se guardan por id en memoria y disco
///   (`PortadasDeVideo`): la tarjeta sale con su foto, su play y su alto real, sin red.
/// - El `AVPlayer` se monta al TOCAR play y se queda en `ReproductoresDeVideo` por id: el
///   mismo objeto al volver, con su posición, aunque SwiftUI recree la vista.
/// - La firma sale de `FirmasEnMemoria` (≈45 min); si falla se pide otra una vez.
/// - Tras el primer play (o de entrada en Wi-Fi si pesa ≤150 MB) se baja a
///   `ArchivosEnDisco` en segundo plano; la siguiente vez se reproduce del disco.
///
/// Sin autoplay. El cuadro se RESERVA (16:9 o el aspecto guardado): el hilo no crece tarde.
struct ReproductorDeVideo: View {
    let entrega: Entrega
    /// Ancho de la tarjeta; el alto sale del aspecto.
    var ancho: CGFloat = 300

    @State private var player: AVPlayer?
    @State private var aspecto: CGFloat?
    @State private var portada: UIImage?
    @State private var segundos: Double?
    @State private var preparando = false
    @State private var fallo: String?
    @State private var archivoParaCompartir: URL?
    /// Cómo va el guardado en Fotos: bajando, «Guardado en Fotos», o el fallo.
    @State private var guardando = false
    @State private var avisoGuardado: String?
    @State private var intentos = 0

    /// La llave de todo lo cacheado: el id de la cuenta, o un hash de la URL anunciada.
    private var clave: String { ReproductoresDeVideo.clave(entrega) }

    /// Lo de memoria se lee EN el cuerpo: el primer fotograma ya sale con portada y alto.
    private var memo: (UIImage?, MiniaturasEnMemoria.DatosDeVideo?) { PortadasDeVideo.enMemoria(clave) }
    private var aspectoActual: CGFloat {
        if let aspecto { return aspecto }
        if let a = memo.1?.aspecto, a > 0 { return CGFloat(a) }
        return 16.0 / 9.0
    }
    private var alto: CGFloat { min(360, ancho / aspectoActual) }
    private var jugador: AVPlayer? { player ?? ReproductoresDeVideo.existente(clave) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black
                if let jugador {
                    VideoPlayer(player: jugador)
                } else {
                    cartel
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
        .task(id: entrega.id) { await prepararPortada() }
        .onDisappear { jugador?.pause() }
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

    /// La portada con su play encima. Nunca un spinner a pantalla: si aún no hay portada
    /// se ve el negro con el play, y la foto entra cuando llega.
    private var cartel: some View {
        ZStack {
            if let img = portada ?? memo.0 {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: ancho, height: alto).clipped()
                    .transition(.opacity)
            }
            if let fallo {
                Text(fallo).gCaption().foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
            } else {
                ZStack {
                    Circle().fill(.black.opacity(0.5)).frame(width: 56, height: 56)
                    if preparando { ProgressView().tint(.white) }
                    else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                            .offset(x: 2)
                    }
                }
            }
            if let s = segundos ?? memo.1?.segundos, s > 0 {
                Text(Self.reloj(s))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !preparando else { return }
            if fallo != nil { intentos += 1; fallo = nil }
            Task { await reproducir() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Reproducir video")
    }

    private static func reloj(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Al aparecer: portada de memoria → disco → generada del asset. Nada de esto monta un
    /// reproductor ni bloquea el hilo principal.
    private func prepararPortada() async {
        let k = clave
        let (enMem, datosMem) = PortadasDeVideo.enMemoria(k)
        if enMem == nil || datosMem == nil {
            let (img, datos) = await PortadasDeVideo.delDisco(k)
            if let img { portada = img }
            if let datos { aplicar(datos) }
            if img == nil || datos == nil { await generarPortada() }
        }
        // En Wi-Fi y de peso conocido ≤150 MB: se baja ya, para que el play sea del disco.
        if let id = entrega.remotoID, let peso = entrega.bytesRemotos,
           peso <= ArchivosEnDisco.maximoPorVideo, RedLibre.esWiFi {
            ReproductoresDeVideo.bajarEnSegundoPlano(id)
        }
    }

    private func aplicar(_ d: MiniaturasEnMemoria.DatosDeVideo) {
        segundos = d.segundos
        if let a = d.aspecto, a > 0, abs(CGFloat(a) - aspectoActual) > 0.01 {
            aspecto = CGFloat(a)
            NotificationCenter.default.post(name: .hiloCrecio, object: nil)
        }
    }

    private func generarPortada() async {
        guard let asset = await asset(fresca: false) else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        var img: UIImage?
        if let (cg, _) = try? await gen.image(at: .zero) { img = UIImage(cgImage: cg) }
        var datos = MiniaturasEnMemoria.DatosDeVideo()
        if let d = try? await asset.load(.duration), d.isNumeric { datos.segundos = d.seconds }
        if let pista = try? await asset.loadTracks(withMediaType: .video).first,
           let (tam, tr) = try? await pista.load(.naturalSize, .preferredTransform) {
            let real = tam.applying(tr)
            if real.width != 0, real.height != 0 { datos.aspecto = abs(real.width / real.height) }
        }
        guard img != nil || datos.segundos != nil else {
            // Una firma guardada que ya no sirve: se olvida para que el play pida otra.
            if let id = entrega.remotoID { FirmasEnMemoria.olvidar(id) }
            return
        }
        PortadasDeVideo.guardar(img, datos: datos, clave: clave)
        withAnimation(.easeOut(duration: 0.2)) { portada = img ?? portada }
        aplicar(datos)
    }

    /// El asset del video: del disco si ya está; si no, por streaming con la firma
    /// guardada (o una fresca).
    private func asset(fresca: Bool) async -> AVURLAsset? {
        if let id = entrega.remotoID, ArchivosEnDisco.hay(id) {
            let u = ArchivosEnDisco.url(id)
            ArchivosEnDisco.tocar(u)
            // Sin extensión en el nombre, AVFoundation necesita que le digan qué es.
            let mime = entrega.mime ?? entrega.tipo.flatMap { UTType(filenameExtension: $0)?.preferredMIMEType } ?? "video/mp4"
            return AVURLAsset(url: u, options: [AVURLAssetOverrideMIMETypeKey: mime])
        }
        if let id = entrega.remotoID, let f = try? await FirmasEnMemoria.firma(id, fresca: fresca), let u = URL(string: f) {
            return AVURLAsset(url: u)
        }
        if let s = entrega.url, let u = URL(string: s) { return AVURLAsset(url: u) }
        return nil
    }

    /// Al tocar play: el reproductor de este id si ya existe; si no, uno nuevo que se
    /// queda guardado. Después, el video se baja al disco para la próxima.
    private func reproducir() async {
        if let ya = jugador { player = ya; ya.play(); return }
        preparando = true; defer { preparando = false }
        var asset = await asset(fresca: false)
        // ⚠️ Si el asset no carga (firma caducada/403, red), NO se monta un reproductor
        // mudo: se reintenta UNA vez con firma fresca y, si tampoco, se dice.
        if let a = asset, (try? await a.load(.isPlayable)) != true {
            if let id = entrega.remotoID { FirmasEnMemoria.olvidar(id) }
            asset = await self.asset(fresca: true)
            if let b = asset, (try? await b.load(.isPlayable)) != true { asset = nil }
        }
        guard let asset else {
            fallo = intentos == 0 ? "No cargó. Toca para reintentar." : "Ese enlace ya no sirve."
            return
        }
        // ⚠️ `.playback`: si la sesión quedó en modo grabación (nota de voz), el video sale
        // por el auricular a volumen mínimo y parece mudo.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let nuevo = ReproductoresDeVideo.registrar(AVPlayer(playerItem: AVPlayerItem(asset: asset)), clave: clave)
        player = nuevo
        nuevo.play()
        if portada == nil && memo.0 == nil { Task { await generarPortada() } }
        if let id = entrega.remotoID, (entrega.bytesRemotos ?? 0) <= ArchivosEnDisco.maximoPorVideo {
            ReproductoresDeVideo.bajarEnSegundoPlano(id)
        }
    }
}

/// Los `AVPlayer` vivos, por video. Identidad estable: volver al hilo reusa el MISMO
/// reproductor (y su posición) en vez de montar otro con cada pasada de SwiftUI. Pocos,
/// porque cada uno retiene su búfer.
@MainActor
enum ReproductoresDeVideo {
    private static var vivos: [(clave: String, player: AVPlayer)] = []
    private static let tope = 3
    private static var bajando: Set<String> = []

    nonisolated static func clave(_ e: Entrega) -> String {
        if let id = e.remotoID { return id }
        let texto = e.url ?? e.id
        var h: UInt64 = 0xcbf29ce484222325
        for b in texto.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return "u" + String(h, radix: 36)
    }

    static func existente(_ clave: String) -> AVPlayer? {
        vivos.first(where: { $0.clave == clave })?.player
    }

    static func registrar(_ p: AVPlayer, clave: String) -> AVPlayer {
        if let ya = existente(clave) { return ya }
        vivos.append((clave, p))
        while vivos.count > tope {
            let viejo = vivos.removeFirst()
            viejo.player.pause()
            viejo.player.replaceCurrentItem(with: nil)
        }
        return p
    }

    static func borrarTodo() {
        vivos.forEach { $0.player.pause(); $0.player.replaceCurrentItem(with: nil) }
        vivos.removeAll()
    }

    /// Baja el video a `ArchivosEnDisco` como ARCHIVO (nunca a memoria), una vez por id.
    static func bajarEnSegundoPlano(_ id: String) {
        guard !ArchivosEnDisco.hay(id), !bajando.contains(id) else { return }
        bajando.insert(id)
        Task.detached(priority: .background) {
            defer { Task { @MainActor in bajando.remove(id) } }
            for fresca in [false, true] {
                guard let f = try? await FirmasEnMemoria.firma(id, fresca: fresca), let u = URL(string: f) else { continue }
                var req = URLRequest(url: u)
                req.assumesHTTP3Capable = false
                guard let (tmp, resp) = try? await URLSession.shared.download(for: req) else { continue }
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: tmp)
                    FirmasEnMemoria.olvidar(id)
                    continue
                }
                ArchivosEnDisco.guardarArchivo(tmp, id: id)
                return
            }
        }
    }
}

/// ¿La red de ahora es Wi-Fi (ni cara ni restringida)? Para decidir si se baja un video
/// sin que nadie lo pida.
enum RedLibre {
    private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor()
        m.start(queue: DispatchQueue(label: "ghosty.red-libre", qos: .utility))
        return m
    }()

    static var esWiFi: Bool {
        let p = monitor.currentPath
        return p.status == .satisfied && !p.isExpensive && !p.isConstrained && p.usesInterfaceType(.wifi)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

extension Notification.Name {
    /// Algo del hilo creció tarde (video medido, imagen cargada): re-anclar abajo.
    static let hiloCrecio = Notification.Name("gs.hiloCrecio")
}
