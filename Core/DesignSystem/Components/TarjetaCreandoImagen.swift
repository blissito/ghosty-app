import SwiftUI
import UIKit

/// Lo que va en la caja de la imagen de un turno.
enum ImagenDelTurno: Equatable {
    /// La herramienta de imagen corre (o terminó y la entrega todavía no llega).
    case creando(editando: Bool)
    /// Llegó la imagen del turno: se revela EN LA MISMA caja.
    case lista(Entrega)
    /// La herramienta falló: el error va dentro de la caja, no en otro sitio.
    case fallo(String)
}

/// La caja de la imagen de un turno: el híbrido de ChatGPT y Gemini del notch (nota
/// `creando-imagen-chatgpt-gemini`), adaptado al teléfono.
///
/// - Al ancho de la columna del chat, 1:1 mientras crea, radio 32.
/// - Encabezado fuera del cuadro: puntitos animados + «Creando imagen» con brillo.
/// - Fondo: un blob con la paleta Ghosty que deriva, late y rota su degradado, y encima la
///   rejilla de puntitos de ChatGPT: los que el blob toca se encienden y, en el núcleo, se
///   vuelven glifos mono que se «descifran».
/// - Abajo a la derecha, el tiempo que lleva (sin inventar porcentaje).
/// - Al llegar la imagen, la MISMA caja anima su alto al aspecto real y la imagen entra de
///   arriba abajo (máscara + blur 20 → 0, 1.2 s). La entrega no sale además como tarjeta
///   suelta (ver `ConversationView.visibles`).
/// - Lista: en el teléfono no hay hover, así que los controles van SIEMPRE: copiar y
///   compartir/guardar arriba a la derecha, «Editar» abajo a la izquierda; tocar la
///   imagen abre el visor.
/// - Con «reducir movimiento», todo quieto y la imagen entra con un fundido.
struct TarjetaCreandoImagen: View {
    let estado: ImagenDelTurno
    /// «Editar»: la imagen va al compositor como adjunto.
    var alEditar: ((Adjunto?) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var sinMovimiento
    @State private var inicio = Date()
    @State private var imagen: UIImage?
    @State private var datos: Data?
    /// 0 = nada revelado, 1 = revelada entera (anima la máscara, el blur y apaga los puntos).
    @State private var revelado: CGFloat = 0
    @State private var falloDeCarga: String?
    @State private var copiada = false
    @State private var mirando: UIImage?
    /// El ancho de la columna, medido: con él se acota el alto de una imagen vertical.
    @State private var columna: CGFloat = 0
    /// Revelada y asentada: los controles salen DESPUÉS del revelado.
    @State private var lista = false
    /// La imagen ya estaba al abrir el hilo: se pinta de una, sin revelado.
    @State private var yaEstaba: Bool?

    private let radio: CGFloat = 32

    private var aspecto: CGFloat {
        guard let imagen, imagen.size.height > 0 else { return 1 }
        return imagen.size.width / imagen.size.height
    }

    /// Una imagen vertical se estrecha antes que ocupar más de 1.25 veces el ancho de alto.
    private var ancho: CGFloat? {
        guard columna > 0 else { return nil }
        return min(columna, columna * 1.25 * aspecto)
    }

    private var entrega: Entrega? {
        if case .lista(let e) = estado { return e }
        return nil
    }

    private var creando: Bool { if case .creando = estado { return imagen == nil } else { return false } }
    private var fallo: Bool { if case .fallo = estado { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            encabezado
            caja
                .frame(width: ancho)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { columna = g.size.width }
                        .onChange(of: g.size.width) { _, w in columna = w }
                })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if yaEstaba == nil { yaEstaba = entrega != nil } }
        .task(id: entrega?.id) { await cargar() }
        .animation(.easeOut(duration: 0.3), value: lista)
        .fullScreenCover(item: $mirando) { img in
            VisorDeImagen(imagen: img, titulo: entrega?.titulo ?? "Imagen",
                          archivo: archivoTemporal(), onCerrar: { mirando = nil })
        }
    }

    // MARK: - Encabezado

    private var encabezado: some View {
        let titulo: String = {
            switch estado {
            case .creando(let editando): return imagen == nil ? (editando ? "Editando imagen" : "Creando imagen") : "Imagen creada"
            case .lista: return "Imagen creada"
            case .fallo: return "No se pudo crear la imagen"
            }
        }()
        return HStack(spacing: 8) {
            PuntitosAnimados(activos: creando, fallo: fallo)
            Group {
                if creando && !sinMovimiento {
                    // Un brillo recorre el rótulo mientras crea.
                    Text(titulo).modifier(BrilloQueRecorre())
                } else {
                    Text(titulo)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.gInk2)
            // Cambio SECO del rótulo: un fundido cruzado los enciman.
            .transaction { $0.animation = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("creando-imagen")
    }

    // MARK: - La caja

    private var caja: some View {
        ZStack {
            // Blob + rejilla. Debajo hasta que la imagen se revela entera; los puntos se
            // apagan con el revelado.
            if revelado < 1 {
                FondoBlobYPuntos(apagado: revelado, quieto: fallo)
            }

            if let imagen {
                Image(uiImage: imagen)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: sinMovimiento ? 0 : 20 * (1 - revelado))
                    .mask(MascaraQueBaja(avance: revelado))
                    .accessibilityLabel(entrega?.titulo ?? "Imagen")
                if !sinMovimiento { DestelloQueBaja(avance: revelado) }
            }

            if case .fallo(let m) = estado { falloView(m) }
            else if let falloDeCarga, imagen == nil { falloView(falloDeCarga) }

            if creando { reloj }
            if lista { controles.transition(.opacity) }
        }
        .aspectRatio(aspecto, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radio, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radio, style: .continuous)
                .strokeBorder(Color.gSeparator, lineWidth: 1)
        }
        // Mientras crea, un anillo de luz fino recorre el borde.
        .overlay { if creando { AnilloDeLuz(radio: radio).transition(.opacity) } }
        .contentShape(RoundedRectangle(cornerRadius: radio, style: .continuous))
        // ⚠️ `onTapGesture`, no `Button`: un `Button` que presenta un `fullScreenCover` se
        // queda «pulsado» y el siguiente toque del hilo reabre el visor (ver `EntregaCard`).
        .onTapGesture { if lista, let imagen { mirando = imagen } }
        .animation(.smooth(duration: 0.5), value: aspecto)
    }

    /// El tiempo que lleva, abajo a la derecha.
    private var reloj: some View {
        TimelineView(.periodic(from: inicio, by: 1)) { ctx in
            Text(Self.reloj(ctx.date.timeIntervalSince(inicio)))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.gInk2)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.gCard.opacity(0.85), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.gSeparator, lineWidth: 1))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    private func falloView(_ m: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.gDanger)
            Text(m)
                .font(.system(size: 13))
                .foregroundStyle(Color.gDangerInk)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
        .padding(16)
        .frame(maxWidth: 280)
        .background(Color.gCard.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Controles (lista)

    private var controles: some View {
        ZStack {
            HStack(spacing: 8) {
                BotonRedondo(icono: copiada ? "checkmark" : "doc.on.doc",
                             etiqueta: copiada ? "Copiada" : "Copiar imagen", accion: copiar)
                    .accessibilityIdentifier("copiar-imagen")
                if let imagen {
                    // La hoja de compartir trae «Guardar imagen» (a Fotos) y todo lo demás.
                    ShareLink(item: Image(uiImage: imagen),
                              preview: SharePreview(entrega?.titulo ?? "Imagen", image: Image(uiImage: imagen))) {
                        CirculoTranslucido(icono: "square.and.arrow.up")
                    }
                    .buttonStyle(.gPressIcon)
                    .accessibilityLabel("Guardar o compartir")
                    .accessibilityIdentifier("compartir-imagen")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            if alEditar != nil {
                Button(action: editar) {
                    Label("Editar", systemImage: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.gPressPill)
                .accessibilityHint("Pedirle un cambio a esta imagen")
                .accessibilityIdentifier("editar-imagen")
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    // MARK: - Acciones

    static func reloj(_ s: TimeInterval) -> String {
        let n = max(0, Int(s))
        return String(format: "%d:%02d", n / 60, n % 60)
    }

    private func copiar() {
        guard let imagen else { return }
        UIPasteboard.general.image = imagen
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.2)) { copiada = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy(duration: 0.2)) { copiada = false }
        }
    }

    /// Los bytes de la imagen tal cual llegaron (o en PNG si sólo hay la decodificada).
    private var bytes: Data? { datos ?? imagen?.pngData() }

    private var nombre: String {
        var n = (entrega?.titulo ?? "imagen").replacingOccurrences(of: "/", with: "-")
        if (n as NSString).pathExtension.isEmpty { n += ".png" }
        return n
    }

    /// La imagen como archivo temporal con su nombre: lo que abre el visor para compartir.
    private func archivoTemporal() -> URL? {
        guard let bytes else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: nombre)
        return (try? bytes.write(to: url, options: .atomic)) != nil ? url : nil
    }

    private func editar() {
        guard let bytes else { alEditar?(nil); return }
        let ext = (nombre as NSString).pathExtension.lowercased()
        let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : ext == "webp" ? "image/webp" : "image/png"
        alEditar?(Adjunto(nombre: nombre, mime: mime, datos: bytes))
    }

    /// La imagen entregada: los bytes que vinieron dentro, la memoria, el disco o la red.
    private func cargar() async {
        guard let e = entrega, imagen == nil else { return }
        let clave = "entrega:" + (e.remotoID ?? e.id)
        var d: Data? = e.datos
        if d == nil, let id = e.remotoID, ArchivosEnDisco.hay(id) { d = await ArchivosEnDisco.leer(id) }
        if d == nil, let id = e.remotoID { d = try? await GhostyAPI.bajar(id) }
        if d == nil, let s = e.url, let u = URL(string: s) { d = await Descargas.bytes(u) }
        var img = d.flatMap(UIImage.init(data:))
        if img == nil { img = MiniaturasEnMemoria.imagen(clave) }
        guard let img else { falloDeCarga = "No pude cargar la imagen."; return }
        MiniaturasEnMemoria.guardar(img, clave: clave)
        datos = d
        if yaEstaba == true || sinMovimiento {
            if sinMovimiento, yaEstaba != true {
                withAnimation(.easeOut(duration: 0.3)) { imagen = img; revelado = 1 }
            } else {
                imagen = img; revelado = 1
            }
            lista = true
            return
        }
        // Primero el alto al aspecto real (la caja cambia en su sitio), y a la vez el
        // revelado de arriba abajo mientras los puntos se apagan.
        withAnimation(.smooth(duration: 0.5)) { imagen = img }
        withAnimation(.easeOut(duration: 1.2)) { revelado = 1 }
        try? await Task.sleep(for: .milliseconds(1250))
        lista = true
    }
}

// MARK: - Piezas

/// El círculo translúcido de los controles sobre la imagen.
private struct CirculoTranslucido: View {
    let icono: String

    var body: some View {
        Image(systemName: icono)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 38, height: 38)
            .background(.ultraThinMaterial.opacity(0.6), in: Circle())
            .background(Color.black.opacity(0.35), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .contentShape(Circle())
    }
}

/// Botón redondo translúcido sobre la imagen.
private struct BotonRedondo: View {
    let icono: String
    let etiqueta: String
    let accion: () -> Void

    var body: some View {
        Button(action: accion) { CirculoTranslucido(icono: icono) }
            .buttonStyle(.gPressIcon)
            .accessibilityLabel(etiqueta)
    }
}

/// El brillo que recorre el rótulo mientras crea (el «Working…» de claude.ai).
private struct BrilloQueRecorre: ViewModifier {
    @State private var fase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(colors: [.clear, Color.white.opacity(0.7), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 60)
                    .offset(x: fase * 110)
                    .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { fase = 1 }
            }
    }
}

/// El ícono del encabezado: una rejilla de 3 × 3 puntitos que se encienden en ola mientras
/// crea (tipo Gemini). Quieto al terminar; rojo si falló.
private struct PuntitosAnimados: View {
    let activos: Bool
    let fallo: Bool
    @Environment(\.accessibilityReduceMotion) private var sinMovimiento

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !activos || sinMovimiento)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let animar = activos && !sinMovimiento
            Canvas { g, size in
                let paso = size.width / 3
                for f in 0..<3 {
                    for c in 0..<3 {
                        let fase = Double(f + c) * 0.35
                        let k = animar ? 0.5 + 0.5 * sin(t * 4 - fase) : 1
                        let r = paso * (0.22 + 0.12 * k)
                        let centro = CGPoint(x: paso * (CGFloat(c) + 0.5), y: paso * (CGFloat(f) + 0.5))
                        let color: Color = fallo ? .gDanger : (animar ? Color.gPrimary.opacity(0.35 + 0.65 * k) : .gPrimary)
                        g.fill(Path(ellipseIn: CGRect(x: centro.x - r, y: centro.y - r, width: r * 2, height: r * 2)),
                               with: .color(color))
                    }
                }
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// La máscara del revelado: opaca arriba, un borde degradado, transparente abajo. El borde
/// baja con `avance` (0 → 1).
private struct MascaraQueBaja: View, Animatable {
    var avance: CGFloat
    var animatableData: CGFloat {
        get { avance }
        set { avance = newValue }
    }

    var body: some View {
        GeometryReader { g in
            let borde = g.size.height * 0.28
            let y = -borde + (g.size.height + borde) * avance
            VStack(spacing: 0) {
                Rectangle().fill(.black).frame(height: max(0, y))
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: borde)
                Spacer(minLength: 0)
            }
            .offset(y: min(0, y))
        }
    }
}

/// La paleta viva del blob: morado → lavanda → cielo.
enum PaletaDelBlob {
    typealias RGB = (r: Double, g: Double, b: Double)
    static let morado: RGB = (0x5B / 255.0, 0x4B / 255.0, 0xD6 / 255.0)
    static let lavanda: RGB = (0x8B / 255.0, 0x7D / 255.0, 0xF2 / 255.0)
    static let cielo: RGB = (0x76 / 255.0, 0xD3 / 255.0, 0xCB / 255.0)
    static let gris: RGB = (0xA3 / 255.0, 0xA2 / 255.0, 0xB0 / 255.0)
    static let colores: [Color] = [Color(hex: 0x5B4BD6), Color(hex: 0x8B7DF2), Color(hex: 0x76D3CB), Color(hex: 0x5B4BD6)]

    static func mezcla(_ a: RGB, _ b: RGB, _ k: Double) -> RGB {
        (a.r + (b.r - a.r) * k, a.g + (b.g - a.g) * k, a.b + (b.b - a.b) * k)
    }

    /// El color del degradado en una fracción de vuelta (0…1, cíclico).
    static func en(_ u: Double) -> RGB {
        let v = (u.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 3
        switch v {
        case ..<1: return mezcla(morado, lavanda, v)
        case ..<2: return mezcla(lavanda, cielo, v - 1)
        default:   return mezcla(cielo, morado, v - 2)
        }
    }
}

/// El fondo mientras crea (el mismo del notch):
/// - La rejilla de ChatGPT cubre TODO el cuadro, centrada, y ningún punto desaparece:
///   lejos del blob quedan tenues.
/// - UN blob grande (≈ 65 % del lado) que deriva en una Lissajous lenta (10 s × 12.7 s) y
///   late 0.87 ↔ 1 (9.5 s). Cada punto toma el color del degradado que rota en el ángulo
///   donde cae; la intensidad es un `smoothstep` de la distancia: sin bordes duros.
/// - Cerca del núcleo los puntos se abren 1–2 pt (lente que respira) y titilan ±15 %.
/// - En el núcleo cada celda es un glifo mono (0–9 A–F · + × / ◇) que cambia 8–12 veces
///   por segundo; al revelar, la franja delante de la máscara «resuelve» y se apaga.
/// Un `Canvas` a 60 Hz; con «reducir movimiento», una versión quieta.
private struct FondoBlobYPuntos: View {
    /// 0 → 1 mientras la imagen se revela (lo que la máscara ya cubrió se apaga).
    var apagado: CGFloat = 0
    /// Con error: todo quieto.
    var quieto = false
    @Environment(\.accessibilityReduceMotion) private var sinMovimiento
    @Environment(\.colorScheme) private var esquema

    private static let caracteres: [String] = ["0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F","·","+","×","/","◇"]

    var body: some View {
        let oscuro = esquema == .dark
        TimelineView(.animation(minimumInterval: 1 / 60, paused: quieto || sinMovimiento)) { ctx in
            // Quieto: un instante fijo (el blob al centro), no el reloj de cuando se pausó.
            let t = quieto || sinMovimiento ? 0 : ctx.date.timeIntervalSinceReferenceDate
            let apagado = apagado
            Canvas { g, size in Self.dibujar(&g, size: size, t: t, apagado: apagado, oscuro: oscuro) }
        }
        .accessibilityHidden(true)
    }

    private static func suave(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }

    /// Un entero pseudoaleatorio estable por celda (y por «tic» del descifrado).
    private static func hash(_ a: Int, _ b: Int, _ c: Int = 0) -> UInt64 {
        var h = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663 ^ c &* 83_492_791))
        h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33; h &*= 0xc4ceb9fe1a85ec53; h ^= h >> 33
        return h
    }

    private static func dibujar(_ g: inout GraphicsContext, size: CGSize, t: Double, apagado: CGFloat, oscuro: Bool) {
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: oscuro ? 0x1C1B22 : 0xF7F7FA)))
        let w = Double(size.width), h = Double(size.height)
        let lado = min(w, h)

        // UN blob: Lissajous lenta dentro del cuadro y latido 0.87 ↔ 1.
        let cx = w * (0.5 + 0.26 * sin(t * 2 * .pi / 10))
        let cy = h * (0.5 + 0.24 * sin(t * 2 * .pi / 12.7 + 1.1))
        let escala = 0.935 + 0.065 * sin(t * 2 * .pi / 9.5)
        let radio = lado * 0.33 * escala
        let giro = t / 12   // vueltas del degradado

        // El frente del revelado (lo de arriba ya lo cubre la imagen).
        let borde = h * 0.28
        let frente = apagado > 0 ? -borde + (h + borde) * Double(apagado) : -.infinity

        // Halo: el mismo blob, muy tenue, con el color del degradado.
        let c0 = PaletaDelBlob.en(giro)
        let rh = CGFloat(radio * 1.35)
        let centro = CGPoint(x: cx, y: cy)
        g.fill(Path(ellipseIn: CGRect(x: centro.x - rh, y: centro.y - rh, width: rh * 2, height: rh * 2)),
               with: .radialGradient(Gradient(colors: [Color(.sRGB, red: c0.r, green: c0.g, blue: c0.b, opacity: oscuro ? 0.22 : 0.16), .clear]),
                                     center: centro, startRadius: 0, endRadius: rh))

        // Glifos resueltos UNA vez por cuadro (21 caracteres), y se reusan en cada celda.
        let resueltos = caracteres.map {
            g.resolve(Text($0).font(.system(size: 10, weight: .medium, design: .monospaced)))
        }

        // La rejilla, centrada: márgenes iguales en los cuatro lados.
        let paso = 13.0
        let columnas = max(1, Int(w / paso))
        let filas = max(1, Int(h / paso))
        let x0 = (w - Double(columnas - 1) * paso) / 2
        let y0 = (h - Double(filas - 1) * paso) / 2
        let base = oscuro ? 0.22 : 0.28
        for f in 0..<filas {
            let yBase = y0 + Double(f) * paso
            // Ya bajo la imagen: no se pinta.
            if yBase < frente { continue }
            // La franja delante de la máscara «resuelve»: deja de cambiar y se apaga.
            let franja = apagado > 0 ? suave((yBase - frente) / 60) : 1
            for c in 0..<columnas {
                let xBase = x0 + Double(c) * paso
                let dx = xBase - cx, dy = yBase - cy
                let d = (dx * dx + dy * dy).squareRoot()
                let k = suave(1 - d / (radio * 1.25))
                let hc = hash(c, f)
                // Titileo ±15 %, desfasado por celda.
                let fase = Double(hc % 1000) / 1000 * 2 * .pi
                let titileo = 1 + 0.15 * sin(t * (2.2 + Double(hc % 7) * 0.3) + fase) * k
                // Lente: cerca del núcleo el punto se abre 1–2 pt hacia afuera.
                let abre = d > 0.5 ? (1 + 0.6 * sin(t * 2 * .pi / 4)) * k / d : 0
                let x = xBase + dx * abre, y = yBase + dy * abre
                // Color del degradado en el ángulo donde cae; gris lejos del blob.
                let ang = atan2(dy, dx) / (2 * .pi) + giro
                let col = PaletaDelBlob.mezcla(PaletaDelBlob.gris, PaletaDelBlob.en(ang), min(1, k * 1.6))
                let opac = min(1, (base + 0.62 * k) * titileo) * franja
                // Punto → glifo en el borde del blob.
                let gk = suave((k - 0.3) / 0.3)
                if gk < 1 {
                    let tam = 1 + 1.6 * k
                    g.fill(Path(ellipseIn: CGRect(x: x - tam / 2, y: y - tam / 2, width: tam, height: tam)),
                           with: .color(Color(.sRGB, red: col.r, green: col.g, blue: col.b, opacity: opac * (1 - gk))))
                }
                if gk > 0 {
                    // 8–12 cambios por segundo, desfasados; la franja resuelta ya no cambia.
                    let ritmo = 8 + Double(hc % 5)
                    let tic = franja < 1 ? 0 : Int(t * ritmo + Double(hc % 97) / 97)
                    var r = resueltos[Int(hash(c, f, tic) % UInt64(resueltos.count))]
                    r.shading = .color(Color(.sRGB, red: col.r, green: col.g, blue: col.b, opacity: 1))
                    var cg = g
                    cg.opacity = opac * gk
                    cg.translateBy(x: x, y: y)
                    let esc = 0.75 + 0.45 * k
                    cg.scaleBy(x: esc, y: esc)
                    cg.draw(r, at: .zero, anchor: .center)
                }
            }
        }
    }
}

/// El anillo de luz del borde mientras crea: 1.5 pt con el degradado de la paleta,
/// girando (4 s). Muy tenue; con «reducir movimiento», quieto.
private struct AnilloDeLuz: View {
    let radio: CGFloat
    @Environment(\.accessibilityReduceMotion) private var sinMovimiento

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: sinMovimiento)) { ctx in
            let a = sinMovimiento ? 0 : ctx.date.timeIntervalSinceReferenceDate / 4 * 360
            RoundedRectangle(cornerRadius: radio, style: .continuous)
                .strokeBorder(AngularGradient(colors: PaletaDelBlob.colores, center: .center,
                                              angle: .degrees(a.truncatingRemainder(dividingBy: 360))),
                              lineWidth: 1.5)
                .opacity(0.55)
        }
        .allowsHitTesting(false)
    }
}

/// El destello del revelado: una franja del degradado que va justo delante de la máscara.
private struct DestelloQueBaja: View, Animatable {
    var avance: CGFloat
    var animatableData: CGFloat {
        get { avance }
        set { avance = newValue }
    }

    var body: some View {
        GeometryReader { g in
            let borde = g.size.height * 0.28
            let y = -borde + (g.size.height + borde) * avance
            LinearGradient(colors: [.clear, Color(hex: 0x8B7DF2).opacity(0.35), Color(hex: 0x76D3CB).opacity(0.25), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: borde * 0.9)
                .offset(y: y + borde * 0.35)
                .opacity(avance > 0 && avance < 1 ? Double(min(1, (1 - avance) * 4)) : 0)
        }
        .allowsHitTesting(false)
    }
}
