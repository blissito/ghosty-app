import AVFoundation
import SwiftUI

/// Tu nota de voz, dentro de tu burbuja. Es la `BurbujaDeVoz` con el micrófono a la derecha.
///
/// Gemelo del `VoiceNote` de Teams. La onda no es decoración: es lo que distingue una nota
/// de un archivo adjunto y lo que deja ver de un vistazo si se grabó algo o si el
/// micrófono no captó nada.
struct NotaDeVoz: View {
    let adjunto: Adjunto

    var body: some View {
        BurbujaDeVoz(id: adjunto.remoto?.id ?? adjunto.id,
                     lado: .mia,
                     segundos: adjunto.segundos ?? 0,
                     onda: adjunto.onda ?? []) {
            // Un hilo recargado trae la nota SIN bytes: sólo su id en la cuenta. Se bajan
            // al primer play; bajarlas al pintar la lista costaría una descarga por nota.
            if !adjunto.datos.isEmpty { return adjunto.datos }
            guard let id = adjunto.remoto?.id else { throw GhostyAPI.Fallo.mensaje("No tengo el audio.") }
            return try await GhostyAPI.bajar(id)
        }
    }

    /// Cuántas barras se pintan, pase lo que pase.
    ///
    /// ⚠️ Fijo a propósito. Antes se pintaba UNA barra por muestra, y como el grabador
    /// muestrea cada 60 ms, una nota de seis segundos traía cien: a 1.5 pt cada una, la
    /// onda se veía como una línea de puntos. Es lo que hacen WhatsApp y Telegram —
    /// remuestrear a un número fijo—, y de paso una nota de 3 s y otra de 30 s se ven
    /// igual de sólidas en vez de degradarse con la duración.
    static let numeroDeBarras = 34

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

    static func reloj(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Las notas de voz que ya se oyeron: su micrófono se pinta azul, como en WhatsApp.
enum NotasEscuchadas {
    private static let clave = "ghosty.notasEscuchadas"
    /// Un recuerdo, no un archivo: con más de estas se olvidan las más viejas.
    private static let tope = 500

    static func contiene(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: clave) ?? []).contains(id)
    }

    static func marcar(_ id: String) {
        var l = UserDefaults.standard.stringArray(forKey: clave) ?? []
        guard !l.contains(id) else { return }
        l.append(id)
        UserDefaults.standard.set(Array(l.suffix(tope)), forKey: clave)
    }
}

/// Una nota de voz como las de WhatsApp.
///
/// - Play/pausa, y la onda ES la barra de avance: lo oído va en color, con un cursor
///   redondo que se toca o se arrastra para saltar.
/// - Abajo a la izquierda, la duración; mientras suena, la posición.
/// - Un micrófono en círculo que se pone azul (`#53BDEB`) cuando ya la oíste. Mientras
///   suena lo sustituye la pastilla de velocidad: 1× → 1.5× → 2×.
/// - En tu nota el micrófono va a la derecha; en la del agente, a la izquierda.
///
/// ⚠️ Suena UNA a la vez: al arrancar una, las demás se pausan (`ReproduccionDeVoz`).
struct BurbujaDeVoz: View {
    enum Lado { case mia, agente }

    /// Para recordar que ya se oyó. El id de la cuenta si lo hay: sobrevive a recargar.
    let id: String
    let lado: Lado
    let segundos: Double
    let onda: [Float]
    /// La duración va al final de la fila (Archivos → Audio) en vez de debajo de la onda.
    var tiempoAlFinal = false
    /// De dónde salen los bytes. Se llama al primer play (o al primer salto).
    let cargar: () async throws -> Data

    @State private var reproductor: AVAudioPlayer?
    @State private var sonando = false
    @State private var avance: Double = 0
    /// Mientras el dedo arrastra el cursor: la posición que se enseña, sin mover el audio.
    @State private var arrastrando: Double?
    @State private var reloj: Task<Void, Never>?
    @State private var bajando = false
    @State private var fallo: String?
    @State private var escuchada = false
    @State private var velocidad: Float = 1

    static let azulEscuchada = Color(hex: 0x53BDEB)

    private var barras: [Float] {
        let r = NotaDeVoz.remuestrear(onda, a: NotaDeVoz.numeroDeBarras)
        // Sin onda propia: una pseudo-onda FIJA por id (misma semilla, misma forma en cada
        // visita), como Android.
        return r.isEmpty ? Self.pseudoOnda(id, n: NotaDeVoz.numeroDeBarras) : r
    }

    /// Onda determinista a partir del id: ruido con semilla bajo una envolvente senoidal.
    static func pseudoOnda(_ id: String, n: Int) -> [Float] {
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return (0..<n).map { i in
            h = h &* 6364136223846793005 &+ 1442695040888963407
            let ruido = Float((h >> 33) % 1000) / 1000
            let envolvente = Float(0.45 + 0.55 * sin(Double(i) / Double(max(1, n - 1)) * .pi))
            return max(0.12, min(1, (0.25 + 0.75 * ruido) * envolvente))
        }
    }

    /// El texto del reloj: vacío si todavía no se sabe cuánto dura (nunca «0:00»).
    private var textoDelReloj: String {
        let t = sonando || arrastrando != nil || avance > 0 ? posicion : duracion
        return duracion > 0 ? NotaDeVoz.reloj(t) : ""
    }

    private var duracion: Double {
        if let d = reproductor?.duration, d > 0 { return d }
        return segundos
    }

    private var posicion: Double { (arrastrando ?? avance) * duracion }

    var body: some View {
        HStack(spacing: 10) {
            if lado == .agente { lateral }
            botonDePlay
            VStack(alignment: .leading, spacing: 3) {
                ondaConCursor
                    .frame(height: 26)
                if let fallo {
                    Text(fallo).gCaption().foregroundStyle(Color.gDangerInk).lineLimit(1)
                } else if !tiempoAlFinal {
                    Text(textoDelReloj)
                        .gMono(size: 11)
                        .monospacedDigit()
                        .foregroundStyle(Color.gInk3)
                }
            }
            .frame(maxWidth: .infinity)
            if tiempoAlFinal {
                Text(textoDelReloj)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.gInk3)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            if lado == .mia { lateral }
        }
        .frame(minWidth: 220, maxWidth: tiempoAlFinal ? .infinity : 270)
        .onAppear { escuchada = NotasEscuchadas.contiene(id) }
        .onDisappear { parar() }
        .onReceive(NotificationCenter.default.publisher(for: ReproduccionDeVoz.suena)) { n in
            // Otra nota empezó a sonar: ésta se calla, como en WhatsApp.
            if (n.object as? String) != id, sonando { parar() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nota de voz de \(NotaDeVoz.reloj(duracion))")
    }

    // MARK: - Piezas

    private var botonDePlay: some View {
        Button { Task { await alternar() } } label: {
            ZStack {
                if bajando {
                    ProgressView().controlSize(.small).tint(Color.gPrimary)
                } else {
                    Image(systemName: sonando ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 34, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(bajando)
        .accessibilityLabel(sonando ? "Pausar" : "Reproducir")
        .accessibilityIdentifier("voz-play")
    }

    /// El micrófono en su círculo, o la pastilla de velocidad en cuanto empezó a sonar.
    @ViewBuilder
    private var lateral: some View {
        ZStack {
            if reproductor != nil {
                Button(action: cambiarVelocidad) {
                    Text(etiquetaDeVelocidad)
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.gInk)
                        .frame(width: 44, height: 26)
                        .background(Color.gFillStrong, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                .accessibilityLabel("Velocidad \(etiquetaDeVelocidad)")
                .accessibilityIdentifier("voz-velocidad")
            } else {
                Circle()
                    .fill(Color.gPrimaryTint)
                    .frame(width: 40, height: 40)
                    .overlay {
                        // Sin escuchar: morado; escuchada: azul, como WhatsApp.
                        Image(systemName: "mic.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(escuchada ? Self.azulEscuchada : Color.gPrimary)
                    }
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 46, height: 46)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: reproductor != nil)
    }

    private var etiquetaDeVelocidad: String {
        switch velocidad {
        case 1.5: "1.5×"
        case 2: "2×"
        default: "1×"
        }
    }

    /// Las barras: lo oído en color, lo que falta en gris, y el cursor redondo encima.
    /// Tocar o arrastrar salta ahí.
    private var ondaConCursor: some View {
        GeometryReader { g in
            let n = max(barras.count, 1)
            let paso = g.size.width / CGFloat(n)
            // Delgadas, como Android: 34 % del paso con tope de 2.5.
            let ancho = min(2.5, max(1.5, paso * 0.34))
            let frac = CGFloat(arrastrando ?? avance)
            let colorFuerte = Color.gPrimary
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(barras.enumerated()), id: \.offset) { i, v in
                        let pasada = (CGFloat(i) + 0.5) / CGFloat(n) <= frac
                        Capsule()
                            .fill(pasada ? colorFuerte : Color.gInk4.opacity(0.5))
                            // Un mínimo visible: el silencio entre palabras es normal y una
                            // barra de altura 0 se lee como un hueco.
                            .frame(width: ancho, height: max(4, CGFloat(v) * g.size.height))
                            .frame(width: paso)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                Circle()
                    .fill(colorFuerte)
                    .frame(width: 13, height: 13)
                    .offset(x: min(max(0, frac * g.size.width - 6.5), g.size.width - 13))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in arrastrando = min(1, max(0, v.location.x / max(1, g.size.width))) }
                    .onEnded { v in
                        let destino = min(1, max(0, v.location.x / max(1, g.size.width)))
                        arrastrando = nil
                        Task { await saltar(a: destino) }
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Avance")
        .accessibilityValue("\(Int(posicion)) de \(Int(duracion)) segundos")
        .accessibilityAdjustableAction { dir in
            let paso = duracion > 0 ? 5 / duracion : 0.1
            Task { await saltar(a: min(1, max(0, avance + (dir == .increment ? paso : -paso)))) }
        }
    }

    // MARK: - Sonar

    /// El reproductor listo, bajando los bytes si hace falta.
    private func preparado() async -> AVAudioPlayer? {
        if let reproductor { return reproductor }
        bajando = true; fallo = nil
        defer { bajando = false }
        do {
            let datos = try await cargar()
            let p = try AVAudioPlayer(data: datos)
            p.enableRate = true
            p.rate = velocidad
            p.prepareToPlay()
            reproductor = p
            return p
        } catch let e as GhostyAPI.Fallo {
            fallo = e.errorDescription ?? "No pude bajarlo."
        } catch {
            fallo = "No pude reproducirlo."
            EasyBitsClient.diag("[voz] no pude preparar la nota: \(error.localizedDescription)")
        }
        return nil
    }

    private func alternar() async {
        if sonando { parar(); return }
        guard let p = await preparado() else { return }
        // Terminó la vez anterior: vuelve a empezar, no se queda en el final.
        if p.currentTime >= p.duration - 0.05 { p.currentTime = 0 }
        sonar(p)
    }

    private func saltar(a frac: Double) async {
        guard let p = await preparado() else { return }
        p.currentTime = frac * p.duration
        avance = frac
        if !sonando { sonar(p) }
    }

    private func sonar(_ p: AVAudioPlayer) {
        do {
            // ⚠️ `.playback` explícito: si la sesión se quedó en modo grabación, el audio
            // sale por el auricular de arriba a volumen mínimo y parece que no suena.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            EasyBitsClient.diag("[voz] sesión de audio: \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: ReproduccionDeVoz.suena, object: id)
        p.rate = velocidad
        p.play()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { sonando = true }
        if !escuchada {
            escuchada = true
            NotasEscuchadas.marcar(id)
        }
        reloj?.cancel()
        reloj = Task {
            while !Task.isCancelled, p.isPlaying {
                try? await Task.sleep(for: .milliseconds(50))
                if arrastrando == nil { avance = p.duration > 0 ? p.currentTime / p.duration : 0 }
            }
            guard !Task.isCancelled else { return }
            // Llegó al final: vuelve al principio, como WhatsApp.
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { sonando = false }
            avance = 0
            p.currentTime = 0
        }
    }

    private func parar() {
        reproductor?.pause()
        reloj?.cancel(); reloj = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { sonando = false }
    }

    private func cambiarVelocidad() {
        velocidad = velocidad == 1 ? 1.5 : velocidad == 1.5 ? 2 : 1
        reproductor?.rate = velocidad
    }
}

/// Avisa que una nota empezó a sonar, para que las demás se callen.
enum ReproduccionDeVoz {
    static let suena = Notification.Name("ghosty.voz.suena")
}
