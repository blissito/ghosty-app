import AVFoundation
import Foundation
import Observation

/// Graba una nota de voz.
///
/// ⚠️ **m4a/AAC**, no ogg/opus. Teams graba en opus porque es lo que soportan los
/// navegadores; aquí no hay esa restricción y AAC es lo que iOS hace nativo y lo que
/// whisper lee sin convertir. Un formato que hay que transcodificar en medio es una pieza
/// más que se puede caer.
///
/// 16 kHz mono: es lo que usa el reconocimiento de voz y pesa una fracción de un estéreo a
/// 44.1 — una nota de un minuto cabe de sobra bajo cualquier tope.
@Observable
@MainActor
final class GrabadorDeVoz {
    private(set) var grabando = false
    private(set) var segundos: Double = 0
    /// Amplitudes 0…1 de lo que va entrando, para pintar la onda EN VIVO.
    ///
    /// ⚠️ Se muestrea del medidor mientras se graba y no del archivo al terminar: leer la
    /// forma de onda de un AAC ya escrito exige decodificarlo entero.
    private(set) var onda: [Float] = []

    private var recorder: AVAudioRecorder?
    private var reloj: Task<Void, Never>?
    private var archivo: URL?

    /// El clip terminado.
    struct Clip {
        var datos: Data
        var segundos: Double
        var onda: [Float]
    }

    func empezar() {
        guard !grabando else { return }
        let sesion = AVAudioSession.sharedInstance()
        do {
            // `.playAndRecord` y no `.record`: al terminar se reproduce en el mismo hilo, y
            // cambiar de categoría entre una cosa y otra corta el audio a media frase.
            try sesion.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try sesion.setActive(true)
        } catch {
            print("[voz] no pude abrir la sesión de audio: \(error.localizedDescription)")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appending(path: "nota-\(Int(Date().timeIntervalSince1970)).m4a")
        let ajustes: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: ajustes)
            r.isMeteringEnabled = true          // sin esto `averagePower` devuelve siempre 0
            r.record()
            recorder = r
            archivo = url
        } catch {
            print("[voz] no pude grabar: \(error.localizedDescription)")
            return
        }

        grabando = true
        segundos = 0
        onda = []
        reloj = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                self.segundos = r.currentTime
                // El medidor viene en dBFS (-160…0). La escala lineal directa deja todo
                // pegado al suelo: -50 dB ya es voz normal, así que se recorta ahí.
                let db = max(-50, Double(r.averagePower(forChannel: 0)))
                self.onda.append(Float((db + 50) / 50))
                if self.onda.count > 64 { self.onda.removeFirst() }
            }
        }
    }

    /// Cierra la grabación y devuelve el clip. `nil` si no hay nada que mandar.
    ///
    /// ⚠️ La duración se lee ANTES de `stop()`: después, `currentTime` vuelve a 0 y la nota
    /// saldría marcada como de cero segundos.
    func terminar() -> Clip? {
        guard let r = recorder else { return nil }
        let dur = r.currentTime
        r.stop()
        reloj?.cancel(); reloj = nil
        recorder = nil
        grabando = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        defer { archivo = nil; segundos = 0 }
        guard let url = archivo, let datos = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        // Menos de medio segundo es un toque sin querer, no una nota.
        guard dur >= 0.5, !datos.isEmpty else { return nil }
        return Clip(datos: datos, segundos: dur, onda: onda)
    }

    /// Tira lo grabado. Es el gesto de arrastrar para cancelar.
    func cancelar() {
        recorder?.stop()
        reloj?.cancel(); reloj = nil
        recorder = nil
        grabando = false
        if let url = archivo { try? FileManager.default.removeItem(at: url) }
        archivo = nil
        segundos = 0
        onda = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
