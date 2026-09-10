import Foundation

/// El diagnóstico, en un archivo que se puede compartir desde el teléfono.
///
/// ⚠️ Existe porque medir en el iPhone dependía del cable, y el túnel por WiFi se cayó
/// tres veces seguidas — y cuando aguantó, el mensaje se mandó desde la instancia de la
/// app que NO estaba enganchada a la consola, así que el registro salió vacío. Dos horas
/// de fallo reproducible sin una sola línea de log. Un archivo no se cae.
///
/// No sustituye a `NSLog`: lo acompaña. Con el cable delante, la consola sigue siendo más
/// cómoda; sin él, esto es lo único que hay.
enum Bitacora {
    /// Cuánto se guarda. Un turno con herramientas escribe decenas de renglones, así que
    /// esto son varias sesiones de trabajo — y el archivo se recorta solo.
    private static let tope = 2000

    private static let cola = DispatchQueue(label: "ghosty.bitacora")
    private static var lineas: [String] = []
    private static var sucia = false

    static var archivo: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "bitacora.txt")
    }

    private static let hora: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func anotar(_ mensaje: String) {
        let linea = "\(hora.string(from: Date())) \(mensaje)"
        cola.async {
            lineas.append(linea)
            if lineas.count > tope { lineas.removeFirst(lineas.count - tope) }
            // ⚠️ No se escribe a disco en cada renglón: un turno los suelta a ráfagas y
            // eso serían cientos de escrituras por respuesta. Se vuelca al pedirlo y al
            // irse al fondo, que es justo cuando hace falta que sobreviva.
            sucia = true
        }
    }

    /// Deja el archivo al día y devuelve dónde está.
    @discardableResult
    static func volcar() -> URL {
        cola.sync {
            guard sucia else { return }
            try? lineas.joined(separator: "\n").write(to: archivo, atomically: true, encoding: .utf8)
            sucia = false
        }
        return archivo
    }

    /// Lo que hay ahora mismo, para enseñarlo o copiarlo.
    static var texto: String {
        cola.sync { lineas.joined(separator: "\n") }
    }

    static func limpiar() {
        cola.sync {
            lineas = []
            try? FileManager.default.removeItem(at: archivo)
            sucia = false
        }
    }
}
