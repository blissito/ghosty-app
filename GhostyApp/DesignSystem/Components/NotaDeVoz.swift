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
    /// Los bytes, cuando hubo que bajarlos de la cuenta.
    @State private var bajados: Data?
    @State private var bajando = false
    @State private var fallo: String?

    private var tinta: Color { claro ? .gInk : .gInk }

    /// Cuántas barras se pintan, pase lo que pase.
    ///
    /// ⚠️ Fijo a propósito. Antes se pintaba UNA barra por muestra, y como el grabador
    /// muestrea cada 60 ms, una nota de seis segundos traía cien: a 1.5 pt cada una, la
    /// onda se veía como una línea de puntos. Es lo que hacen WhatsApp y Telegram —
    /// remuestrear a un número fijo—, y de paso una nota de 3 s y otra de 30 s se ven
    /// igual de sólidas en vez de degradarse con la duración.
    static let numeroDeBarras = 34

    private var barras: [Float] { Self.remuestrear(adjunto.onda ?? [], a: Self.numeroDeBarras) }

    /// Remuestrea a `n` barras quedándose con el PICO de cada tramo, y lo normaliza contra
    /// el pico de la nota.
    ///
    /// El pico, no el promedio: promediar aplana justo lo que se quiere ver —una nota es
    /// picos de voz separados por silencios— y devuelve una tira uniforme.
    ///
    /// ⚠️ La normalización tiene suelo, y esto importa: escalar contra el pico haría que
    /// una grabación MUDA se dibujara como una onda perfectamente normal, porque su
    /// ruidito de fondo pasaría a valer 1. Justo lo contrario de para qué está la onda —
    /// ver de un vistazo si el micrófono captó algo. Por debajo de ese suelo se deja
    /// plana, que es la verdad.
    static func remuestrear(_ crudo: [Float], a n: Int) -> [Float] {
        guard !crudo.isEmpty, n > 0 else { return [] }
        var fuera: [Float] = []
        fuera.reserveCapacity(n)
        for i in 0..<n {
            let desde = i * crudo.count / n
            let hasta = max(desde + 1, (i + 1) * crudo.count / n)
            fuera.append(crudo[desde..<min(hasta, crudo.count)].max() ?? 0)
        }
        let pico = fuera.max() ?? 0
        guard pico > 0.12 else { return fuera }
        return fuera.map { min(1, $0 / pico) }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: alternar) {
                ZStack {
                    Circle().fill(Theme.primaryGradient).frame(width: 32, height: 32)
                    if bajando {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: sonando ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(bajando)

            onda
                .frame(height: 24)
                .frame(maxWidth: .infinity)

            // Si algo falló, se dice AHÍ: un play que no hace nada se lee como una app
            // rota, y la causa real (el archivo ya no está) es información útil.
            if let fallo {
                Text(fallo).gCaption().foregroundStyle(Color.gDangerInk)
            } else {
                Text(Self.reloj(adjunto.segundos ?? 0))
                    .gMono(size: 12)
                    .foregroundStyle(Color.gInk2)
                    .monospacedDigit()
            }
        }
        .frame(minWidth: 190)
        .onDisappear { parar() }
    }

    /// Las barras. Las ya reproducidas van con el color fuerte.
    private var onda: some View {
        GeometryReader { g in
            let n = max(barras.count, 1)
            // Barra y hueco en proporción fija (3:2), como una onda de verdad. El ancho
            // sale del hueco disponible en vez de un valor a mano, así que la onda ocupa
            // la burbuja completa en lugar de dejar una franja muerta a la derecha.
            let paso = g.size.width / CGFloat(n)
            let ancho = max(2, paso * 0.62)
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(barras.enumerated()), id: \.offset) { i, v in
                    let pasada = Double(i) / Double(n) <= avance
                    Capsule()
                        .fill(pasada ? Color.gPrimary : Color.gInk4.opacity(0.55))
                        // Un mínimo visible: una barra de altura 0 parece un hueco, y el
                        // silencio entre palabras es normal. Sube a 4 para que a esta
                        // anchura se lea como barra y no como punto.
                        .frame(width: ancho, height: max(4, CGFloat(v) * g.size.height))
                        .frame(width: paso)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    /// Los bytes con los que sonar: los que ya tenemos, o los que se bajaron.
    private var audio: Data? {
        if !adjunto.datos.isEmpty { return adjunto.datos }
        return bajados
    }

    private func alternar() {
        if sonando { parar(); return }
        // Un hilo recargado trae la nota SIN bytes: sólo su id en la cuenta. Se bajan al
        // primer play y se quedan mientras la burbuja viva; bajarlas al pintar la lista
        // costaría una descarga por cada nota que pasa por pantalla.
        guard audio != nil else {
            guard let id = adjunto.remoto?.id else {
                fallo = "No tengo el audio."
                return
            }
            bajando = true; fallo = nil
            Task {
                do { bajados = try await GhostyAPI.bajar(id); bajando = false; sonar() }
                catch {
                    bajando = false
                    fallo = (error as? GhostyAPI.Fallo)?.errorDescription ?? "No pude bajarlo."
                }
            }
            return
        }
        sonar()
    }

    private func sonar() {
        guard let datos = audio else { return }
        do {
            // ⚠️ `.playback` explícito: si la sesión se quedó en modo grabación, el audio
            // sale por el auricular de arriba a volumen mínimo y parece que no suena.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p: AVAudioPlayer
            if let ya = reproductor { p = ya } else { p = try AVAudioPlayer(data: datos) }
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
            fallo = "No pude reproducirlo."
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
