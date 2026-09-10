import Foundation

/// Los archivos que el agente anuncia con un bloque ` ```eb-file `.
///
/// ⚠️ **Es un puente, y su sitio de verdad está en el relé.** Cuando el agente genera algo
/// —una cotización, una imagen— a veces lo anuncia con un bloque de Teams en vez de con la
/// notificación `ghosty/artifact` que esta app entiende:
///
/// ```
/// eb-file
/// {"url":"https://…"}
/// ```
///
/// El cliente web de Teams lo convierte en tarjeta; aquí salía el JSON crudo en mitad de la
/// respuesta y, peor, **nunca llegaba a Artefactos**: sin `ghosty/artifact` no hubo entrega,
/// así que no se podía abrir, ni compartir, ni borrar. Esto lo traduce. El día que el relé
/// emita `ghosty/artifact` para todo lo que produce, este archivo se borra entero.
///
/// ⚠️ Y es un contrato que NO es nuestro: si el formato cambia, esto deja de reconocerlo.
/// Por eso un bloque que no se puede leer **se deja tal cual y se anota**, en vez de
/// tragárselo — un puente que se rompe en silencio es peor que no tenerlo.
enum BloqueEbFile {

    struct Encontrado {
        let entrega: Entrega
        /// Lo que hay que quitar del texto visible.
        let rango: Range<String.Index>
    }

    /// Todos los bloques CERRADOS del texto.
    ///
    /// ⚠️ Cerrados importa: el texto del agente llega partido en trozos, y un bloque a
    /// medias daría una URL truncada. Quien los use debe recorrerlos AL REVÉS para ir
    /// quitándolos sin invalidar los índices de los demás.
    static func buscar(_ texto: String, agentID: String, sesionID: String?) -> [Encontrado] {
        guard texto.contains("```eb-file") else { return [] }
        var salida: [Encontrado] = []
        var desde = texto.startIndex

        while let abre = texto.range(of: "```eb-file", range: desde..<texto.endIndex) {
            guard let cierra = texto.range(of: "```", range: abre.upperBound..<texto.endIndex)
            else { break }   // sin cerrar: todavía está llegando
            let cuerpo = String(texto[abre.upperBound..<cierra.lowerBound])
            if let e = entrega(de: cuerpo, agentID: agentID, sesionID: sesionID) {
                salida.append(Encontrado(entrega: e, rango: abre.lowerBound..<cierra.upperBound))
            } else {
                EasyBitsClient.diag("[eb-file] ⚠️ no pude leerlo, lo dejo tal cual: \(cuerpo.prefix(120))")
            }
            desde = cierra.upperBound
        }
        return salida
    }

    /// Tolerante a propósito: lo único que se exige es la URL.
    private static func entrega(de cuerpo: String, agentID: String, sesionID: String?) -> Entrega? {
        guard let datos = cuerpo.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let url = (j["url"] as? String) ?? (j["href"] as? String),
              !url.isEmpty
        else { return nil }

        let nombre = (j["name"] as? String) ?? (j["nombre"] as? String)
            ?? (j["filename"] as? String) ?? (j["titulo"] as? String)
            // Sin nombre, el último trozo de la URL: es lo que llamaría cualquiera.
            ?? URL(string: url)?.lastPathComponent
            ?? "Archivo"

        var e = Entrega(id: "eb" + huella(url), agentID: agentID, sesionID: sesionID,
                        forma: .archivo, titulo: nombre, recibida: Date(),
                        contenido: nil, datos: nil)
        e.url = url
        e.bytesRemotos = (j["size"] as? Int) ?? (j["bytes"] as? Int)
        return e
    }

    /// El mismo hash determinista que las entregas del relé: dos anuncios del mismo archivo
    /// son UNA entrega, no dos.
    private static func huella(_ t: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in t.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 36)
    }
}
