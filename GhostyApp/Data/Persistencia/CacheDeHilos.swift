import Foundation
import Observation

/// Las conversaciones, guardadas en este teléfono.
///
/// ⚠️ **Qué se guarda y qué no, y por qué.** Todo lo del hilo se le pide hoy a la caja:
/// abrir el historial cuesta despertarla (segundos) más `session/list`, y abrir un hilo
/// cuesta un `session/load` entero. Nada de eso sobrevivía a cerrar la app.
///
/// Se guardan DOS cosas por agente:
/// - **La lista de hilos**, para pintar el historial al instante.
/// - **El hilo abierto**, para que la app te devuelva donde la dejaste.
///
/// Y NO se guardan los demás hilos, que es donde se satura el teléfono sin comprar nada:
/// el replay es la verdad —un hilo puede haber avanzado desde otro cliente— y bajarlo es
/// justo lo que hay que hacer cuando lo abres.
///
/// Mismo molde que `TitleStore` y `TurnLogStore`: un JSON en Application Support, tope y
/// escritura atómica.
@Observable
@MainActor
final class CacheDeHilos {
    /// El mismo número que la bitácora de turnos. Un hilo más largo se recorta por el
    /// principio: lo que importa al volver es el final.
    private static let tope = 200
    /// Cuántas conversaciones por agente se guardan. Son las que retomas, no un archivo:
    /// el archivo es la caja.
    private static let topeDeHilos = 5

    private struct Disco: Codable {
        /// ⚠️ La versión existe por un fallo concreto: hasta la v1, un turno vivo podía
        /// escribir sus mensajes bajo el `sessionId` de OTRA conversación, así que lo
        /// guardado puede estar cruzado. Al no coincidir, las conversaciones guardadas se
        /// marcan **sospechosas**: se siguen pintando —no se le quita nada a nadie sin
        /// red— pero se recargan de la caja en cuanto se abren, y la caja sí tiene la
        /// verdad. La lista de hilos se conserva tal cual: es inofensiva.
        var version = 2
        var lista: [String: [SesionGuardada]] = [:]
        var abiertos: [String: [String: [MensajeGuardado]]] = [:]
        var sospechosos: [String] = []
        /// Conversaciones que se quedaron a medias cuando iOS suspendió la app.
        ///
        /// ⚠️ **Opcional a propósito**: un archivo escrito por una versión anterior no
        /// trae esta clave, y con un campo no opcional el decodificador sintetizado
        /// LANZA — se descartaría el archivo entero y con él todas las conversaciones
        /// guardadas. Subir el número de versión habría hecho lo mismo.
        var pendientes: [String: [Deuda]]?
    }

    /// Un turno que la caja seguía trabajando cuando el teléfono se durmió.
    ///
    /// ⚠️ Vive en DISCO porque iOS mata el proceso a los pocos minutos de irte: al
    /// relanzar no queda ningún hilo marcado en memoria, y sin esto la respuesta que el
    /// agente sí produjo no la reclamaba nadie. Es la mitad del arreglo que el simulador
    /// no puede probar, porque ahí la app no se suspende de verdad.
    struct Deuda: Codable, Equatable {
        var sesionID: String
        var desde: Date
        var intentos: Int = 0
        /// Cuántos mensajes tenía el hilo al cortarse. Sirve para saber si lo que trae la
        /// caja es NUEVO o es lo mismo que ya teníamos.
        var mensajesAlCortar: Int = 0
    }

    private var disco = Disco()

    private var archivo: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "hilos.json")
    }

    init() {
        guard let d = try? Data(contentsOf: archivo) else { return }
        if let leido = try? JSONDecoder().decode(Disco.self, from: d), leido.version == 2 {
            disco = leido
            return
        }
        // Formato viejo: se rescata lo que se puede y se marca lo dudoso.
        if let viejo = try? JSONDecoder().decode(DiscoV1.self, from: d) {
            disco.lista = viejo.lista
            for (agente, g) in viejo.abierto {
                disco.abiertos[agente] = [g.sesionID: g.mensajes]
                disco.sospechosos.append(g.sesionID)
            }
            guardar()
        }
    }

    /// El formato anterior, sólo para leerlo una vez.
    private struct DiscoV1: Codable {
        struct Guardado: Codable { var sesionID: String; var mensajes: [MensajeGuardado] }
        var lista: [String: [SesionGuardada]] = [:]
        var abierto: [String: Guardado] = [:]
    }

    // MARK: - Deudas del fondo

    func deudas(_ agentID: String) -> [Deuda] {
        disco.pendientes?[agentID] ?? []
    }

    var hayDeudas: Bool { !(disco.pendientes?.isEmpty ?? true) }

    /// Todas, con su agente. Al arrancar en frío es lo único que dice qué hay que recoger.
    var todasLasDeudas: [(agentID: String, deuda: Deuda)] {
        (disco.pendientes ?? [:]).flatMap { agente, ds in ds.map { (agente, $0) } }
    }

    func anotarDeuda(_ deuda: Deuda, de agentID: String) {
        var ds = disco.pendientes?[agentID] ?? []
        // Una por conversación: si ya estaba, se conserva su `desde` —lo que importa es
        // cuánto lleva esperando, no cuántas veces la hemos vuelto a apuntar.
        if let i = ds.firstIndex(where: { $0.sesionID == deuda.sesionID }) {
            ds[i].intentos = deuda.intentos
            ds[i].mensajesAlCortar = deuda.mensajesAlCortar
        } else {
            ds.append(deuda)
        }
        disco.pendientes = (disco.pendientes ?? [:]).merging([agentID: ds]) { _, n in n }
        guardar()
    }

    func saldarDeuda(sesion: String, de agentID: String) {
        guard var ds = disco.pendientes?[agentID] else { return }
        ds.removeAll { $0.sesionID == sesion }
        var todas = disco.pendientes ?? [:]
        if ds.isEmpty { todas.removeValue(forKey: agentID) } else { todas[agentID] = ds }
        disco.pendientes = todas
        guardar()
    }

    // MARK: - La lista

    func lista(_ agentID: String) -> [ACPClient.Session] {
        (disco.lista[agentID] ?? []).map(\.sesion)
    }

    func guardarLista(_ hilos: [ACPClient.Session], de agentID: String) {
        disco.lista[agentID] = hilos.map(SesionGuardada.init)
        guardar()
    }

    // MARK: - El hilo abierto

    /// Todas las conversaciones guardadas de un agente.
    func abiertos(_ agentID: String) -> [(sesionID: String, mensajes: [Message], sospechoso: Bool)] {
        (disco.abiertos[agentID] ?? [:]).map { sid, guardados in
            (sid, guardados.compactMap(\.mensaje), disco.sospechosos.contains(sid))
        }
    }

    /// Una conversación concreta.
    func abierto(_ agentID: String, sesion: String) -> [Message]? {
        disco.abiertos[agentID]?[sesion]?.compactMap(\.mensaje)
    }

    func guardarAbiertos(_ hilos: [(sesionID: String, mensajes: [Message])], de agentID: String) {
        var mapa: [String: [MensajeGuardado]] = [:]
        // Las más recientes primero: si hay más de las que caben, sobran las viejas.
        for h in hilos.suffix(Self.topeDeHilos) {
            let guardables = h.mensajes.compactMap(MensajeGuardado.init)
            guard !guardables.isEmpty else { continue }
            mapa[h.sesionID] = Array(guardables.suffix(Self.tope))
        }
        // ⚠️ Se FUNDE con lo que ya había en vez de reemplazarlo. Reemplazando, una
        // conversación que se quedara vacía en memoria por un tropiezo borraba también su
        // copia de disco: el hilo desaparecía del todo y no había de dónde recuperarlo.
        var previo = disco.abiertos[agentID] ?? [:]
        for (sid, msgs) in mapa { previo[sid] = msgs }
        // Sólo se recorta cuando de verdad sobran, y por lo más viejo de lo que hay.
        if previo.count > Self.topeDeHilos {
            let vivos = Set(mapa.keys)
            for sid in previo.keys where !vivos.contains(sid) {
                guard previo.count > Self.topeDeHilos else { break }
                previo[sid] = nil
            }
        }
        disco.abiertos[agentID] = previo
        // Lo que se acaba de escribir ya no es sospechoso: salió del ruteo por hilo.
        disco.sospechosos.removeAll { mapa.keys.contains($0) }
        guardar()
    }

    // MARK: - Olvidar

    func olvidar(_ agentID: String) {
        disco.lista[agentID] = nil
        disco.abiertos[agentID] = nil
        guardar()
    }

    func limpiar() {
        disco = Disco()
        guardar()
    }

    private func guardar() {
        guard let d = try? JSONEncoder().encode(disco) else { return }
        try? d.write(to: archivo, options: .atomic)
    }
}
