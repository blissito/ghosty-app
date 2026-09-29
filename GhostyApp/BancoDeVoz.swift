#if DEBUG && os(iOS)
import AVFoundation
import Foundation
import Speech

/// Banco de prueba: `GHOSTY_STT_BANCO=<carpeta>` transcribe cada `.m4a` de esa carpeta con el
/// SpeechTranscriber de iOS 26 (en el dispositivo) y lo deja en el log, para compararlo con el
/// whisper de gs. Es desechable: se borra cuando se decida el motor.
enum BancoDeVoz {
    /// A stderr, sin búfer: con `print` el log no sale por `devicectl --console`.
    private static func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func correrSiToca() {
        guard let carpeta = Gancho.valor("GHOSTY_STT_BANCO") else { return }
        guard #available(iOS 26, *) else { log("[banco] requiere iOS 26"); return }
        // Relativa = dentro de Documents: en el teléfono no se sabe la ruta del contenedor,
        // y `devicectl device copy to` deja ahí los archivos.
        let url = carpeta.hasPrefix("/") ? URL(fileURLWithPath: carpeta)
            : URL.documentsDirectory.appending(path: carpeta)
        Task.detached { await correr(url) }
    }

    @available(iOS 26, *)
    private static func correr(_ carpeta: URL) async {
        let archivos = ((try? FileManager.default.contentsOfDirectory(at: carpeta, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let soportados = await SpeechTranscriber.supportedLocales.map(\.identifier)
        let dictado = await DictationTranscriber.supportedLocales.map(\.identifier)
        log("[banco] SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable) · \(soportados.count) idiomas: \(soportados.filter { $0.hasPrefix("es") })")
        log("[banco] DictationTranscriber \(dictado.count) idiomas: \(dictado.filter { $0.hasPrefix("es") })")
        // En un iPhone 11 SpeechTranscriber no existe: cae a DictationTranscriber (el motor
        // del dictado del teclado), que sí trae es_MX.
        let usarDictado = !SpeechTranscriber.isAvailable
        let pedido = Locale(identifier: "es-MX")
        let elegido = usarDictado ? await DictationTranscriber.supportedLocale(equivalentTo: pedido)
            : await SpeechTranscriber.supportedLocale(equivalentTo: pedido)
        guard let locale = elegido else { log("[banco] es-MX no soportado"); return }
        log("[banco] motor \(usarDictado ? "DictationTranscriber" : "SpeechTranscriber")")
        log("[banco] locale \(locale.identifier), \(archivos.count) archivos")
        do {
            let t0 = Date()
            let modulo: any LocaleDependentSpeechModule = usarDictado
                ? DictationTranscriber(locale: locale, preset: .shortDictation)
                : SpeechTranscriber(locale: locale, preset: .transcription)
            // Sin reservar el idioma, preguntar por el modelo da «not subscribed to transcription.es».
            _ = try await AssetInventory.reserve(locale: locale)
            if let pedido = try await AssetInventory.assetInstallationRequest(supporting: [modulo]) {
                try await pedido.downloadAndInstall()
            }
            log("[banco] modelo listo en \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        } catch {
            log("[banco] no se pudo instalar el modelo: \(error)"); return
        }
        var salida: [[String: Any]] = []
        for url in archivos {
            let t0 = Date()
            do {
                let texto = try await (usarDictado ? dictar(url, locale: locale) : transcribir(url, locale: locale))
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                log("[banco] \(url.lastPathComponent) \(ms) ms | \(texto)")
                salida.append(["archivo": url.lastPathComponent, "ms": ms, "texto": texto])
            } catch {
                log("[banco] \(url.lastPathComponent) ERROR \(error)")
                salida.append(["archivo": url.lastPathComponent, "error": "\(error)"])
            }
        }
        if let datos = try? JSONSerialization.data(withJSONObject: salida, options: [.prettyPrinted]) {
            try? datos.write(to: carpeta.appending(path: "apple.json"))
        }
        log("[banco] listo")
    }

    @available(iOS 26, *)
    private static func transcribir(_ url: URL, locale: Locale) async throws -> String {
        let modulo = SpeechTranscriber(locale: locale, preset: .transcription)
        let analizador = SpeechAnalyzer(modules: [modulo])
        // Los resultados se leen EN PARALELO al análisis: si se esperan después, la
        // secuencia ya terminó de emitir y no hay nada que leer.
        let lector = Task {
            var texto = ""
            for try await r in modulo.results where r.isFinal { texto += String(r.text.characters) }
            return texto
        }
        let archivo = try AVAudioFile(forReading: url)
        if let ultimo = try await analizador.analyzeSequence(from: archivo) {
            try await analizador.finalizeAndFinish(through: ultimo)
        } else {
            await analizador.cancelAndFinishNow()
        }
        return try await lector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Igual que `transcribir`, con el motor del dictado.
    @available(iOS 26, *)
    private static func dictar(_ url: URL, locale: Locale) async throws -> String {
        let modulo = DictationTranscriber(locale: locale, preset: .longDictation)
        let analizador = SpeechAnalyzer(modules: [modulo])
        let lector = Task {
            var texto = ""
            var n = 0
            for try await r in modulo.results {
                n += 1
                if r.isFinal { texto += String(r.text.characters) }
            }
            log("[banco]   \(n) resultados")
            return texto
        }
        let archivo = try AVAudioFile(forReading: url)
        log("[banco]   formato \(archivo.processingFormat) · \(archivo.length) frames")
        if let ultimo = try await analizador.analyzeSequence(from: archivo) {
            try await analizador.finalizeAndFinish(through: ultimo)
        } else {
            log("[banco]   analyzeSequence no devolvió tiempo")
            await analizador.cancelAndFinishNow()
        }
        return try await lector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
