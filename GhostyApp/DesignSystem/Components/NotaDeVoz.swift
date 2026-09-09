import AVFoundation
import SwiftUI

/// Una nota de voz, con su onda y su duración.
///
/// Gemelo del `VoiceNote` de Teams. La onda no es decoración: es lo que distingue una nota
/// de un archivo adjunto y lo que deja ver de un vistazo si se grabó algo o si el
/// micrófono no captó nada.
struct NotaDeVoz: View {
    let adjunto: Adjunto
    var claro = false

    @State private var reproductor: AVAudioPlayer?
    @State private var sonando = false
    @State private var avance: Double = 0
    @State private var reloj: Task<Void, Never>?

    private var tinta: Color { claro ? .gInk : .gInk }
    private var barras: [Float] { adjunto.onda ?? [] }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: alternar) {
                Image(systemName: sonando ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Theme.primaryGradient, in: Circle())
            }
            .buttonStyle(.plain)

            onda
                .frame(height: 24)
                .frame(maxWidth: .infinity)

            Text(Self.reloj(adjunto.segundos ?? 0))
                .gMono(size: 12)
                .foregroundStyle(Color.gInk2)
                .monospacedDigit()
        }
        .frame(minWidth: 190)
        .onDisappear { parar() }
    }

    /// Las barras. Las ya reproducidas van con el color fuerte.
    private var onda: some View {
        GeometryReader { g in
            let n = max(barras.count, 1)
            let ancho = max(1.5, (g.size.width - CGFloat(n - 1) * 2) / CGFloat(n))
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(barras.enumerated()), id: \.offset) { i, v in
                    let pasada = Double(i) / Double(n) <= avance
                    Capsule()
                        .fill(pasada ? Color.gPrimary : Color.gInk4.opacity(0.5))
                        // Un mínimo visible: una barra de altura 0 parece un hueco, y el
                        // silencio entre palabras es normal.
                        .frame(width: ancho, height: max(3, CGFloat(v) * g.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func alternar() {
        if sonando { parar(); return }
        do {
            // ⚠️ `.playback` explícito: si la sesión se quedó en modo grabación, el audio
            // sale por el auricular de arriba a volumen mínimo y parece que no suena.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p: AVAudioPlayer
            if let ya = reproductor { p = ya } else { p = try AVAudioPlayer(data: adjunto.datos) }
            reproductor = p
            p.play()
            sonando = true
            reloj = Task {
                while !Task.isCancelled, p.isPlaying {
                    try? await Task.sleep(for: .milliseconds(50))
                    avance = p.duration > 0 ? p.currentTime / p.duration : 0
                }
                if !Task.isCancelled { sonando = false; avance = 0 }
            }
        } catch {
            print("[voz] no pude reproducir: \(error.localizedDescription)")
        }
    }

    private func parar() {
        reproductor?.pause()
        reloj?.cancel(); reloj = nil
        sonando = false
    }

    static func reloj(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
