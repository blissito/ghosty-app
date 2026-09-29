#if DEBUG && os(iOS)
import AVFoundation
import Foundation
import Speech

/// Banco de prueba: `GHOSTY_STT_BENCH=<carpeta>` transcribe cada `.m4a` de esa carpeta en el
/// dispositivo (SpeechTranscriber de iOS 26, o DictationTranscriber donde no existe) y lo deja
/// en el log, para compararlo con el whisper de gs. Es desechable.
enum VoiceBench {
    /// A stderr, sin búfer: con `print` el log no sale por `devicectl --console`.
    private static func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func runIfRequested() {
        guard let folder = Gancho.valor("GHOSTY_STT_BENCH") else { return }
        guard #available(iOS 26, *) else { log("[bench] requiere iOS 26"); return }
        // Relativa = dentro de Documents: en el teléfono no se sabe la ruta del contenedor,
        // y `devicectl device copy to` deja ahí los archivos.
        let url = folder.hasPrefix("/") ? URL(fileURLWithPath: folder)
            : URL.documentsDirectory.appending(path: folder)
        Task.detached { await run(url) }
    }

    @available(iOS 26, *)
    private static func run(_ folder: URL) async {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let speechLocales = await SpeechTranscriber.supportedLocales.map(\.identifier)
        let dictationLocales = await DictationTranscriber.supportedLocales.map(\.identifier)
        log("[bench] SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable) · \(speechLocales.count) idiomas: \(speechLocales.filter { $0.hasPrefix("es") })")
        log("[bench] DictationTranscriber \(dictationLocales.count) idiomas: \(dictationLocales.filter { $0.hasPrefix("es") })")
        // En un iPhone 11 SpeechTranscriber no existe: cae a DictationTranscriber (el motor
        // del dictado del teclado), que sí trae es_MX.
        let useDictation = !SpeechTranscriber.isAvailable
        let requested = Locale(identifier: "es-MX")
        let chosen = useDictation ? await DictationTranscriber.supportedLocale(equivalentTo: requested)
            : await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        guard let locale = chosen else { log("[bench] es-MX no soportado"); return }
        log("[bench] motor \(useDictation ? "DictationTranscriber" : "SpeechTranscriber"), locale \(locale.identifier), \(files.count) archivos")
        do {
            let start = Date()
            let module: any LocaleDependentSpeechModule = useDictation
                ? DictationTranscriber(locale: locale, preset: .longDictation)
                : SpeechTranscriber(locale: locale, preset: .transcription)
            // Sin reservar el idioma, preguntar por el modelo da «not subscribed to transcription.es».
            _ = try await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            log("[bench] modelo listo en \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        } catch {
            log("[bench] no se pudo instalar el modelo: \(error)"); return
        }
        var output: [[String: Any]] = []
        for url in files {
            let start = Date()
            do {
                let text = try await (useDictation ? dictate(url, locale: locale) : transcribe(url, locale: locale))
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                log("[bench] \(url.lastPathComponent) \(ms) ms | \(text)")
                output.append(["file": url.lastPathComponent, "ms": ms, "text": text])
            } catch {
                log("[bench] \(url.lastPathComponent) ERROR \(error)")
                output.append(["file": url.lastPathComponent, "error": "\(error)"])
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted]) {
            try? data.write(to: folder.appending(path: "apple.json"))
        }
        log("[bench] listo")
    }

    @available(iOS 26, *)
    private static func transcribe(_ url: URL, locale: Locale) async throws -> String {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        return try await analyze(url, module: module, results: module.results.map { ($0.isFinal, String($0.text.characters)) })
    }

    @available(iOS 26, *)
    private static func dictate(_ url: URL, locale: Locale) async throws -> String {
        let module = DictationTranscriber(locale: locale, preset: .longDictation)
        return try await analyze(url, module: module, results: module.results.map { ($0.isFinal, String($0.text.characters)) })
    }

    /// Corre el análisis de un archivo y junta los resultados finales.
    @available(iOS 26, *)
    private static func analyze<S: AsyncSequence & Sendable>(
        _ url: URL, module: any SpeechModule, results: S
    ) async throws -> String where S.Element == (Bool, String) {
        let analyzer = SpeechAnalyzer(modules: [module])
        // Los resultados se leen EN PARALELO al análisis: si se esperan después, la
        // secuencia ya terminó de emitir y no hay nada que leer.
        let reader = Task {
            var text = ""
            for try await (isFinal, chunk) in results where isFinal { text += chunk }
            return text
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await reader.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
