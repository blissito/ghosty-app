import Foundation

/// Una página que el agente consultó o citó.
///
/// ⚠️ El relé NO manda citas estructuradas: no hay un campo `sources` que copiar. Lo que
/// hay son los enlaces que el agente escribió en la respuesta y las URLs de las
/// herramientas web que corrió, así que esto se saca de ahí. Si algún día el relé manda
/// citas de verdad, este extractor se cambia por el campo y las vistas no se enteran.
struct Fuente: Identifiable, Equatable, Hashable, Sendable {
    /// La URL es la identidad: la misma página citada dos veces es una sola fuente.
    var id: String { url.absoluteString }
    let url: URL
    /// Lo que se lee en la lista. El texto del enlace si lo hubo; si no, el dominio.
    let titulo: String

    /// «causo.io» — sin `www.`, que es ruido y hace que dos entradas del mismo sitio
    /// parezcan distintas.
    var dominio: String {
        let h = url.host ?? url.absoluteString
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// La inicial para el hueco cuando el sitio no tiene favicon donde se espera.
    var inicial: String { String(dominio.prefix(1)).uppercased() }

    /// El logo del sitio, por el servicio de iconos de DuckDuckGo.
    ///
    /// ⚠️ Primero se pedía `https://<sitio>/favicon.ico` para no tocar a nadie de fuera, y
    /// media lista salía con la inicial en un círculo: muchos sitios declaran el icono en
    /// el HTML y no lo sirven en la raíz. El precio de tener logos de verdad es que
    /// DuckDuckGo ve los DOMINIOS que el agente consultó —no la conversación, no la URL
    /// completa—. Decisión de bliss, 2026-09-22.
    var favicon: URL? {
        guard let host = url.host else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
    }
}

enum Fuentes {

    /// Las fuentes de una respuesta, en el orden en que aparecen y sin repetir URL.
    static func de(texto: String, herramientas: [Herramienta]) -> [Fuente] {
        var vistas = Set<String>()
        var salida: [Fuente] = []

        func agregar(_ crudo: String, titulo: String?) {
            guard let u = normalizar(crudo) else { return }
            guard vistas.insert(u.absoluteString).inserted else { return }
            let t = (titulo?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            salida.append(Fuente(url: u, titulo: t ?? (u.host ?? u.absoluteString)))
        }

        for (url, titulo) in enlacesDe(texto) { agregar(url, titulo: titulo) }
        for h in herramientas where h.clase == .fetch || h.clase == .search {
            // `donde` y `detalle` son lo que la herramienta dice que tocó. La SALIDA no se
            // mira: el resultado de una búsqueda trae decenas de URLs que el agente ni
            // abrió, y listarlas como fuentes de la respuesta sería mentir.
            for campo in [h.donde, h.detalle].compactMap({ $0 }) {
                for url in urlsSueltas(campo) { agregar(url, titulo: nil) }
            }
        }
        return salida
    }

    /// `[texto](url)` con esquema http(s). Las imágenes (`![…](…)`) se saltan: una foto
    /// no es una fuente.
    private static func enlacesDe(_ texto: String) -> [(String, String?)] {
        var salida: [(String, String?)] = []
        let patron = try? NSRegularExpression(pattern: "(!?)\\[([^\\]\\n]*)\\]\\((https?://[^)\\s]+)\\)")
        let rango = NSRange(texto.startIndex..<texto.endIndex, in: texto)
        patron?.enumerateMatches(in: texto, range: rango) { m, _, _ in
            guard let m, let rTexto = Range(m.range(at: 2), in: texto),
                  let rURL = Range(m.range(at: 3), in: texto) else { return }
            if let rBang = Range(m.range(at: 1), in: texto), !texto[rBang].isEmpty { return }
            salida.append((String(texto[rURL]), String(texto[rTexto])))
        }
        // Y las URLs que el agente escribe a pelo, sin enlace.
        for url in urlsSueltas(texto) { salida.append((url, nil)) }
        return salida
    }

    private static func urlsSueltas(_ texto: String) -> [String] {
        let patron = try? NSRegularExpression(pattern: "https?://[^\\s)\\]\"'<>]+")
        let rango = NSRange(texto.startIndex..<texto.endIndex, in: texto)
        var salida: [String] = []
        patron?.enumerateMatches(in: texto, range: rango) { m, _, _ in
            if let m, let r = Range(m.range, in: texto) { salida.append(String(texto[r])) }
        }
        return salida
    }

    /// Quita la puntuación pegada al final («…/precios.» dentro de una frase) y tira lo
    /// que no tenga dominio.
    private static func normalizar(_ crudo: String) -> URL? {
        var s = crudo
        while let u = s.unicodeScalars.last, ".,;:!?»\"'".unicodeScalars.contains(u) { s.removeLast() }
        guard let u = URL(string: s), let host = u.host, host.contains(".") else { return nil }
        return u
    }
}
