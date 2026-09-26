import AVFoundation
import SwiftUI

/// Un audio entregado, para oírlo aquí.
///
/// ⚠️ Un audio NO puede ir al visor del sistema. QuickLook con un archivo sin extensión
/// correcta lo enseña como texto —salía un muro de `ID3nTLEN0.96COMM…`— y aunque la
/// extensión esté bien, abrir una hoja del sistema para oír cuatro segundos es más viaje
/// del que hace falta. Es el mismo motivo por el que las imágenes tienen su propio visor.
///
/// Reproduce con `AVAudioPlayer`, igual que `NotaDeVoz`, que es el otro sitio de la app
/// donde suena algo.
struct ReproductorDeEntrega: View {
    let entrega: Entrega

    @State private var reproductor: AVAudioPlayer?
    @State private var sonando = false
    @State private var avance: Double = 0
    @State private var reloj: Task<Void, Never>?
    @State private var fallo: String?
    /// Lo bajado, si la entrega vino sólo con URL (`eb-file`, `eb-audio`).
    @State private var bajados: Data?
    @State private var bajando = false
    private var datos: Data? { entrega.datos ?? bajados }

    var body: some View {
        HStack(spacing: 11) {
            Button { Task { await alternar() } } label: {
                ZStack {
                    if bajando { ProgressView().tint(.white).controlSize(.small) }
                    else {
                        Image(systemName: sonando ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 40, height: 40)
                .background(Theme.primaryGradient, in: Circle())
                .padding(2)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reproducir-audio")
            .accessibilityLabel(sonando ? "Pausar" : "Reproducir")

            VStack(alignment: .leading, spacing: 5) {
                Text(entrega.titulo)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                // Una barra y no una onda: de un archivo entregado no tenemos la onda, y
                // dibujar una inventada sería mentir sobre lo que suena.
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gInk4.opacity(0.3)).frame(height: 3)
                    GeometryReader { g in
                        Capsule().fill(Color.gPrimary)
                            .frame(width: g.size.width * avance, height: 3)
                    }
                    .frame(height: 3)
                }
                if let fallo {
                    Text(fallo).gCaption().foregroundStyle(Color.gDangerInk)
                } else if let d = reproductor?.duration, d > 0 {
                    Text(Self.reloj(sonando ? (reproductor?.currentTime ?? 0) : d)).gCaption()
                } else if let peso = entrega.peso {
                    Text(peso).gCaption()
                }
            }

            // ⚠️ Compartir, que faltaba: un audio se podía oír y no sacar de la app. El
            // archivo sale con su extensión de verdad (ver `Entrega.aDisco`), que es lo
            // que hace que el sistema lo ofrezca como audio y no como texto.
            if let archivo = conBytes()?.aDisco() {
                ShareLink(item: archivo) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.gInk2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .onDisappear { parar() }
    }

    private static func reloj(_ s: TimeInterval) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    /// La entrega con los bytes que haya, para compartirla con su extensión.
    private func conBytes() -> Entrega? {
        guard datos != nil else { return nil }
        var e = entrega; if e.datos == nil { e.datos = bajados }; return e
    }

    /// Los bytes: de la entrega, o bajados de la URL / del archivo de la cuenta.
    ///
    /// ⚠️ Decía «No tengo el audio» en cuanto la entrega venía sólo con URL, que es
    /// justo como llegan la nota de voz (`eb-audio`) y un mp3 anunciado con `eb-file`.
    /// El audio se baja al tocar play, igual que un PDF al tocar la tarjeta.
    private func bytes() async -> Data? {
        if let d = datos { return d }
        bajando = true; defer { bajando = false }
        var d: Data?
        if let id = entrega.remotoID { d = try? await GhostyAPI.bajar(id) }
        if d == nil, let s = entrega.url, let u = URL(string: s) { d = await Descargas.bytes(u) }
        bajados = d
        return d
    }

    private func alternar() async {
        if sonando { parar(); return }
        guard let datos = await bytes() else { fallo = "Ese enlace ya no sirve."; return }
        do {
            // ⚠️ `.playback` explícito: si la sesión se quedó en modo grabación, sale por
            // el auricular de arriba a volumen mínimo y parece que no suena. Lo mismo que
            // ya avisa `NotaDeVoz`.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try reproductor ?? AVAudioPlayer(data: datos)
            reproductor = p
            p.play()
            sonando = true
            fallo = nil
            reloj = Task {
                while !Task.isCancelled, p.isPlaying {
                    try? await Task.sleep(for: .milliseconds(50))
                    avance = p.duration > 0 ? p.currentTime / p.duration : 0
                }
                if !Task.isCancelled { sonando = false; avance = 0 }
            }
        } catch {
            // Un ogg/opus en un iOS que no lo decodifica (18.x): que se sepa por qué.
            fallo = entrega.tipo == "ogg" ? "Este iPhone no reproduce ogg. Pídele el mp3." : "No pude reproducirlo."
        }
    }

    private func parar() {
        reloj?.cancel(); reloj = nil
        reproductor?.pause()
        sonando = false
    }
}
