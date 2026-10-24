import Foundation

/// «Tomar el control» por LiveKit: el contrato entre quien maneja (este teléfono) y la caja del
/// agente (el publicador). Espejo de `~/ghosty-studio/packages/computer/src/protocol.ts`, que es la
/// fuente única: si allá cambia un tope o un tipo, cambia aquí y en `TakeoverProtocolTests`, que
/// repite los mismos casos de `computer.test.ts` para que no diverjan.
///
/// - La pantalla del agente llega como pista de video del participante `publisherIdentity`.
/// - La entrada va por el canal de datos CONFIABLE y ordenado, tema `inputTopic` (un «soltar» que
///   llegara antes que su «bajar» rompería la selección).
/// - Lo que necesita respuesta va por RPC: `rpcCopy` → `{text}`, `rpcRelease` → `{ok}`.
enum TakeoverProtocol {
    static let version = "gc-takeover/1"
    static let inputTopic = "gc.input"
    static let rpcCopy = "gc.copy"
    static let rpcRelease = "gc.release"
    static let publisherIdentity = "agent-browser"

    /// Los topes de `INPUT_LIMITS`.
    enum Limits {
        static let text = 2000
        static let scroll = 3000
        static let coord = 10_000
        static let clickCount = 3
    }

    // Teclas como las nombra Playwright: «Enter», «ArrowLeft», «Shift+ArrowUp», «Control+a», o un carácter.
    private static let keyPattern = try! NSRegularExpression(
        pattern: #"^(?:(?:Control|Shift|Alt|Meta)\+)*(?:[A-Za-z][A-Za-z0-9]{0,15}|[^\s])$"#)

    static func isValidKey(_ key: String) -> Bool {
        keyPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }
}

/// Un evento de la persona, en px del viewport de la página. Espejo de `HumanInput`.
enum HumanInput: Equatable, Sendable {
    enum MouseAction: String, Sendable { case down, move, up }

    case mouse(MouseAction, x: Int, y: Int, clickCount: Int? = nil)
    case click(x: Int, y: Int)
    case type(String)
    case key(String)
    case scroll(dy: Int)

    // MARK: normalizeInput

    /// Valida y normaliza un evento crudo (lo que da `JSONSerialization`): coordenadas enteras
    /// dentro de la pantalla, texto y rueda con su tope, teclas con la forma de Playwright. Lo que
    /// no cuadra regresa `nil` y se ignora. Mismas reglas que `normalizeInput`.
    static func normalize(_ raw: Any?) -> HumanInput? {
        guard let e = raw as? [String: Any] else { return nil }
        let L = TakeoverProtocol.Limits.self
        switch e["type"] as? String {
        case "mouse":
            guard let x = coord(e["x"]), let y = coord(e["y"]),
                  let a = (e["action"] as? String).flatMap(MouseAction.init(rawValue:)) else { return nil }
            if a == .move { return .mouse(.move, x: x, y: y) }
            let n = max(1, min(L.clickCount, num(e["clickCount"], L.clickCount) ?? 1))
            return .mouse(a, x: x, y: y, clickCount: n)
        case "click":
            guard let x = coord(e["x"]), let y = coord(e["y"]) else { return nil }
            return .click(x: x, y: y)
        case "type":
            guard let t = e["text"] as? String, !t.isEmpty else { return nil }
            return .type(prefixUTF16(t, L.text))
        case "key":
            guard let k = e["key"] as? String, TakeoverProtocol.isValidKey(k) else { return nil }
            return .key(k)
        case "scroll":
            guard let dy = num(e["dy"], L.scroll), dy != 0 else { return nil }
            return .scroll(dy: dy)
        default:
            return nil
        }
    }

    /// Lo mismo que `normalize` sobre sí mismo: lo que la app arma también pasa por los topes.
    var normalized: HumanInput? { Self.normalize(jsonObject) }

    // MARK: canal de datos

    var jsonObject: [String: Any] {
        switch self {
        case let .mouse(a, x, y, n):
            var o: [String: Any] = ["type": "mouse", "action": a.rawValue, "x": x, "y": y]
            if let n { o["clickCount"] = n }
            return o
        case let .click(x, y): return ["type": "click", "x": x, "y": y]
        case let .type(t): return ["type": "type", "text": t]
        case let .key(k): return ["type": "key", "key": k]
        case let .scroll(dy): return ["type": "scroll", "dy": dy]
        }
    }

    /// `encodeInput`: el JSON que viaja por `gc.input`.
    func encoded() -> Data {
        (try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])) ?? Data()
    }

    /// `decodeInput`: del canal de datos a un evento válido, o `nil`.
    static func decode(_ data: Data) -> HumanInput? {
        normalize(try? JSONSerialization.jsonObject(with: data))
    }

    static func decode(_ text: String) -> HumanInput? { decode(Data(text.utf8)) }

    // MARK: enqueueInput

    /// Mientras un envío va en camino, lo pendiente se compacta: de varios movimientos sólo cuenta
    /// el último y la rueda se suma. Igual que `enqueueInput`.
    static func enqueue(_ queue: [HumanInput], _ ev: HumanInput) -> [HumanInput] {
        guard let last = queue.last else { return [ev] }
        switch (last, ev) {
        case (.mouse(.move, _, _, _), .mouse(.move, _, _, _)):
            return queue.dropLast() + [ev]
        case let (.scroll(a), .scroll(b)):
            let L = TakeoverProtocol.Limits.scroll
            return queue.dropLast() + [.scroll(dy: max(-L, min(L, a + b)))]
        default:
            return queue + [ev]
        }
    }

    // MARK: ayudantes (los de `protocol.ts`)

    /// `typeof v === "number" && Number.isFinite(v)`, redondeado como `Math.round` y acotado.
    /// ⚠️ Un booleano de JSON también llega como `NSNumber`: en JS es `boolean`, así que no cuenta.
    private static func num(_ v: Any?, _ max: Int) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite else { return nil }
        // `Math.round` redondea los .5 hacia +∞ (−4.5 → −4), no lejos del cero como `rounded()`.
        let r = (d + 0.5).rounded(.down)
        return Int(Swift.max(Double(-max), Swift.min(Double(max), r)))
    }

    private static func coord(_ v: Any?) -> Int? {
        num(v, TakeoverProtocol.Limits.coord).map { Swift.max(0, $0) }
    }

    /// `String.slice(0, n)` cuenta unidades UTF-16; aquí sin partir un carácter a la mitad.
    private static func prefixUTF16(_ s: String, _ n: Int) -> String {
        guard s.utf16.count > n else { return s }
        var out = "", count = 0
        for ch in s {
            let w = ch.utf16.count
            if count + w > n { break }
            out.append(ch)
            count += w
        }
        return out
    }
}
