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

    var body: some View {
        HStack(spacing: 11) {
            Button(action: alternar) {
                Image(systemName: sonando ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.primaryGradient, in: Circle())
            }
            .buttonStyle(.plain)

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
        }
        .padding(12)
        .onDisappear { parar() }
    }

    private static func reloj(_ s: TimeInterval) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private func alternar() {
        if sonando { parar(); return }
        guard let datos = entrega.datos else { fallo = "No tengo el audio."; return }
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
            fallo = "No pude reproducirlo."
        }
    }

    private func parar() {
        reloj?.cancel(); reloj = nil
        reproductor?.pause()
        sonando = false
    }
}
