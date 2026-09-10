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

    private struct Guardado: Codable {
        var sesionID: String
        var mensajes: [MensajeGuardado]
    }

    private struct Disco: Codable {
        var lista: [String: [SesionGuardada]] = [:]
        var abierto: [String: Guardado] = [:]
    }

    private var disco = Disco()

    private var archivo: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "hilos.json")
    }

    init() {
        if let d = try? Data(contentsOf: archivo),
           let leido = try? JSONDecoder().decode(Disco.self, from: d) {
            disco = leido
        }
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

    func abierto(_ agentID: String) -> (sesionID: String, mensajes: [Message])? {
        guard let g = disco.abierto[agentID] else { return nil }
        return (g.sesionID, g.mensajes.compactMap(\.mensaje))
    }

    func guardarAbierto(_ mensajes: [Message], hilo sesionID: String?, de agentID: String) {
        // Sin hilo no hay nada que retomar: un turno sin `sessionId` no se puede continuar.
        guard let sesionID else { disco.abierto[agentID] = nil; guardar(); return }
        let guardables = mensajes.compactMap(MensajeGuardado.init)
        guard !guardables.isEmpty else { disco.abierto[agentID] = nil; guardar(); return }
        disco.abierto[agentID] = Guardado(sesionID: sesionID,
                                          mensajes: Array(guardables.suffix(Self.tope)))
        guardar()
    }

    // MARK: - Olvidar

    func olvidar(_ agentID: String) {
        disco.lista[agentID] = nil
        disco.abierto[agentID] = nil
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
