import Foundation

/// El transporte contra gs: HTTP para pedir, SSE para escuchar.
///
/// ⚠️ La diferencia con el WebSocket no es de tuberías, es de **quién es dueño del
/// trabajo**. Por socket el turno es del teléfono: medido contra la caja real el
/// 2026-09-10, cortar el socket a los 3 s de mandar y volver 25 s después devuelve CERO
/// caracteres —la caída del cliente cierra el socket hacia el motor y cancela el turno—.
/// Aquí el turno vive en gs, en su propia tarea, y el SSE es **re-suscribible**: al
/// conectarse manda primero todo lo que ya emitió y luego el directo. Irte deja de costar
/// el trabajo.
///
/// ⚠️ Lo que NO da: el backlog de un turno terminado se retiene unos minutos y vive en la
/// memoria de gs. Para «me fui una hora» lo correcto es pedir el hilo (`cargar`), no
/// confiar en el backlog.
actor ClienteGS: TransporteDeAgente {
    /// A quién avisar cuando el servidor no contesta y se está reintentando. Lo engancha
    /// el store para pintarlo en el turno: tres puntitos mudos durante un deploy de gs se
    /// sienten como una app colgada.
    nonisolated(unsafe) static var alReintentar: (@Sendable (String) -> Void)?

    private let agentID: String
    /// Cuántos mensajes se piden al recuperar un hilo. La cola es lo que se lee al volver.
    private static let cola = 60

    init(agentID: String) {
        self.agentID = agentID
    }

    // MARK: - Fontanería

    /// ⚠️ Sesión propia y con las mismas curas que el SSE de EasyBits, que ya costaron una
    /// tarde: `identity` para que nadie comprima el flujo por trozos, y timeouts largos
    /// porque un turno puede tardar minutos y `URLSession` corta por su cuenta.
    private static let sesion: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 3600
        c.waitsForConnectivity = true
        c.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        return URLSession(configuration: c)
    }()

    /// ⚠️ Las LECTURAS van por una sesión que NO espera conectividad. Con `waitsForConnectivity`
    /// el tope de la petición (15 s) no corre mientras iOS cree que no hay red, sólo el del recurso
    /// (1 h): tras un corte (-1005 al cambiar de red) un GET se quedaba esperando y el hilo en
    /// «Trayendo la conversación…» minutos (7-oct, 15:29 → 15:32 sin respuesta). Aquí falla pronto
    /// y el reintento abre conexión nueva.
    private static let readSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        return URLSession(configuration: c)
    }()

    private func base(_ sufijo: String) -> URL {
        Session.base.appendingPathComponent("api/v2/me/agents/\(agentID)\(sufijo)")
    }

    private func peticion(_ url: URL, metodo: String = "GET",
                          cuerpo: [String: Any]? = nil,
                          sse: Bool = false, rejected: String? = nil) async throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = metodo
        // ⚠️ El token se pide en CADA llamada, no se guarda: `Session.accessToken()` lo
        // refresca si caducó. Ningún cliente de esta app lo hacía —ver el aviso de
        // `Session.swift`— y una sesión caducada se veía como "el agente no contesta".
        // `rejected`: el token que el servidor acaba de rechazar con 401; fuerza refresh.
        r.setValue("Bearer \(try await Session.accessToken(rejected: rejected))", forHTTPHeaderField: "Authorization")
        // HTTP/3 fuera: por QUIC el cuerpo de un SSE puede no entregarse por trozos y el
        // turno se queda colgado SIN error. Ya mordió en dos clientes de este repo.
        r.assumesHTTP3Capable = false
        // La zona del teléfono viaja en cada petición: gs le da al agente la hora de la persona
        // (`timeZoneOf` en gs). Se lee por petición, no al crear la sesión: puede viajar.
        r.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
        if sse { r.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        // ⚠️ Una LECTURA no hereda los 600 s de la sesión (existen para el SSE). Al volver
        // del fondo por un push, URLSession reusa una conexión que murió dormida y el GET
        // se queda colgado sin error: «Trayendo la conversación…» ≥ 54 s contra 0.6 s del
        // servidor (medido 2026-09-25). Con tope corto falla pronto y el reintento abre
        // conexión nueva.
        else if metodo == "GET" { r.timeoutInterval = 15 }
        if let cuerpo {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: cuerpo)
        }
        return r
    }

    @discardableResult
    private func pedir(_ url: URL, metodo: String = "GET",
                       cuerpo: [String: Any]? = nil, rejected: String? = nil) async throws -> [String: Any] {
        let req = try await peticion(url, metodo: metodo, cuerpo: cuerpo, rejected: rejected)
        let (d, resp) = try await (metodo == "GET" ? Self.readSession : Self.sesion).data(for: req)
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if [502, 503, 504].contains(codigo) { throw ACPClient.Fallo.transitorio(codigo) }
        if codigo == 401 {
            // Una vez con token nuevo; si vuelve a rechazar, la sesión murió de verdad.
            if rejected == nil, let used = Self.bearerToken(req) {
                return try await pedir(url, metodo: metodo, cuerpo: cuerpo, rejected: used)
            }
            await Self.sessionDead()
            throw Session.Fallo.caducada
        }
        // 402 = un límite del plan: no es un fallo de red, y tratarlo como tal (volver a
        // escuchar) hacía desaparecer el mensaje sin decir nada.
        if codigo == 402 { throw ACPClient.Fallo.limit(mensajeDeError(d, codigo)) }
        guard (200..<300).contains(codigo) else {
            throw ACPClient.Fallo.remoto(mensajeDeError(d, codigo))
        }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    private static func bearerToken(_ r: URLRequest) -> String? {
        r.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
    }

    /// El servidor rechazó también el token recién refrescado: no hay nada que reintentar.
    /// Se borra la sesión y se manda al login, en vez de dejar un «401» que no se arregla.
    private static func sessionDead() async {
        EasyBitsClient.diag("[gs] 401 con token nuevo: sesión muerta, al login")
        Session.cerrar()
        await MainActor.run { Session.alCaducar?() }
    }

    /// Lo que se le enseña a una persona cuando el servidor dice que no.
    private func mensajeDeError(_ d: Data, _ codigo: Int) -> String {
        let cuerpo = String(decoding: d, as: UTF8.self).prefix(300)
        // gs contesta `{ error, message }` con la frase ya redactada (saldo agotado con su
        // fecha de reinicio, modelo que exige llave propia…). Antes se pintaba el JSON
        // crudo recortado a dos líneas, y un 402 se leía como «el agente no responde».
        let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        let mensaje = json?["message"] as? String
        switch codigo {
        case 401, 403: return "Hay que volver a entrar a tu cuenta."
        case 402:      return mensaje ?? "Se acabó el saldo de este agente."
        case 404:      return "Ese agente o esa conversación ya no existe."
        case 409:      return "Ese agente no es de los que hablan por aquí."
        case 429:      return "Se acabó el cupo de turnos por ahora."
        default:       return mensaje ?? (cuerpo.isEmpty ? "El servidor contestó \(codigo)." : String(cuerpo))
        }
    }

    // MARK: - Conexión

    /// No hay socket que abrir: se comprueba que el agente responde y ya.
    @discardableResult
    func conectar() async throws -> String {
        // ⚠️ Con reintentos, como el turno. Un deploy de gs (dos reinicios en cinco
        // minutos, medido el 2026-09-16) contestaba 502 aquí y el envío moría en «No
        // llegó a salir» sin que el servidor llegara a ver nada.
        // ⚠️ Ya NO se hace el viaje de prueba (GET de la lista entera). Iba ANTES de todo
        // lo demás, así que abrir un hilo —también al entrar por un push— esperaba primero
        // a que llegara la lista de conversaciones que nadie había pedido: un viaje de
        // más en frío, y el más pesado (2026-09-25). Cada llamada ya sabe reintentar un
        // 5xx y refrescar un 401 por su cuenta, que era lo único que aportaba la prueba.
        return "gs"
    }

    /// No hay nada que cerrar: cada llamada es su propia conexión. El turno sigue en gs,
    /// que es justo el punto de todo esto.
    func cerrar() {
        escuchas.values.forEach { $0.task.cancel() }
        escuchas.removeAll()
    }

    // MARK: - Conversaciones

    func sesiones() async throws -> [ACPClient.Session] {
        let r = try await pedir(base("/conversations"))
        return Self.parseSessions(r["conversaciones"] as? [[String: Any]] ?? [])
    }

    /// Las listas de VARIOS agentes en una sola llamada (`/me/conversations?agentes=`).
    /// Un agente sin acceso no viene en la respuesta.
    func listsForAgents(_ ids: [String]) async throws -> [String: [ACPClient.Session]] {
        var c = URLComponents(url: Session.base.appendingPathComponent("api/v2/me/conversations"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "agentes", value: ids.joined(separator: ","))]
        let r = try await leerConReintento(c.url!)
        let byAgent = r["porAgente"] as? [String: Any] ?? [:]
        return byAgent.compactMapValues { v in
            let list = (v as? [String: Any])?["conversaciones"] as? [[String: Any]] ?? v as? [[String: Any]]
            return list.map(Self.parseSessions)
        }
    }

    static func parseSessions(_ list: [[String: Any]]) -> [ACPClient.Session] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        return list.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            let f = (c["actualizada"] as? String).flatMap { iso.date(from: $0) ?? iso2.date(from: $0) }
            let permiso = (c["permisoPendiente"] as? [String: Any])?["title"] as? String
            return ACPClient.Session(id: id, title: c["titulo"] as? String ?? "Conversación",
                                     cwd: "/data/work", updatedAt: f, messageCount: nil,
                                     ultimoTurno: ACPClient.UltimoTurno.desde(c["ultimoTurno"]),
                                     permisoPendiente: permiso)
        }
    }

    func nuevaSesion(cwd: String) async throws -> (id: String, modos: ACPClient.Modos?) {
        // Ídem: un 502 de nginx significa que gs NO recibió el POST, así que reintentar
        // no crea dos conversaciones.
        let r = try await conReintentos { try await self.pedir(self.base("/conversations"), metodo: "POST", cuerpo: [:]) }
        guard let id = r["id"] as? String else {
            throw ACPClient.Fallo.handshake("el servidor no devolvió la conversación")
        }
        // Los modos son cosa del socket: aquí el permiso se pide por turno.
        return (id, nil)
    }

    /// El hilo, por su cola.
    ///
    /// ⚠️ Se pide SIEMPRE, aunque la conversación esté contestando. La guarda de «no
    /// pisar un turno vivo» vive donde debe —en quien aplica los mensajes, que compara
    /// contra lo que ya hay— y aquí sólo servía para devolver un hilo vacío justo cuando
    /// alguien tocaba un aviso para ir a verlo.
    func cargar(_ id: String, cwd: String) async throws -> [ACPClient.Replay]? {
        var c = URLComponents(url: base("/conversations/\(id)"), resolvingAgainstBaseURL: false)!
        // `archivos=1`: los archivos del hilo vienen en la MISMA respuesta (gs f0d8b97b) y no
        // hace falta el viaje aparte a `/me/files`. Se quedan aquí hasta que el store los tome.
        c.queryItems = [URLQueryItem(name: "tail", value: "\(Self.cola)"), URLQueryItem(name: "archivos", value: "1")]
        let r = try await leerConReintento(c.url!)
        saltados[id] = r["saltados"] as? Int ?? 0
        if let files = r["files"] as? [[String: Any]], let datos = try? JSONSerialization.data(withJSONObject: ["files": files]) {
            archivosDelHilo[id] = datos
        }
        ultimos[id] = ACPClient.UltimoTurno.desde(r["ultimoTurno"])
        largos[id] = (r["largo"] as? Bool ?? false, r["continuesFrom"] as? String)
        // ⚠️ `enCurso: true` NO es «esta conversación está vacía»: es «hay un turno vivo y
        // no te doy el historial», porque pedirlo con un turno en marcha deja mudo al
        // agente (ver `NOTAS-DEL-RELE.md`). gs da por hecho que quien pregunta ya tiene lo
        // anterior, y eso es falso justo cuando llegas por un push a una conversación que
        // este teléfono nunca abrió: se quedaba en blanco. Se distingue de una respuesta
        // vacía de verdad devolviendo `nil`, que quien llama ya sabe tratar como «todavía
        // no hay nada que pintar» en vez de como «no hay nada».
        if r["enCurso"] as? Bool == true {
            EasyBitsClient.diag("[hilo] \(id): turno vivo, el servidor no da historial; lo trae el SSE")
            sinHistorial.insert(id)
            return nil
        }
        sinHistorial.remove(id)
        // ⚠️ Cada mensaje de la copia va precedido de una frontera `.turno("m<i>")`: el
        // conversor pega trozos consecutivos del mismo rol (existe para los `*_chunk` de
        // ACP), y sin frontera dos mensajes seguidos del mismo lado salían fundidos en una
        // burbuja («baja este videoya?»). El endpoint no devuelve `seq`; la posición basta.
        return (r["messages"] as? [[String: Any]] ?? []).enumerated().flatMap { (i, m) in Self.replay(of: m, index: i) }
    }

    /// Un mensaje de la copia de gs como replay, precedido de su frontera `.turno("m<index>")`.
    static func replay(of m: [String: Any], index i: Int) -> [ACPClient.Replay] {
        // Una foto sola, sin texto, también es un mensaje.
        let hasFiles = !((m["attachments"] as? [Any]) ?? []).isEmpty
        guard let t = m["text"] as? String, !t.isEmpty || hasFiles else { return [] }
        // Los pasos que gs guarda con la respuesta (`stored-steps.ts`): sin ellos, al reabrir el
        // hilo la tarjeta de pasos desaparecía y sólo quedaba el texto. Van antes del texto,
        // igual que llegaron en vivo.
        guard m["role"] as? String == "user" else {
            let steps = (m["steps"] as? [[String: Any]] ?? []).compactMap { s -> ACPClient.Replay? in
                guard let id = s["id"] as? String else { return nil }
                return .tool(ACPClient.herramienta(s, id: id))
            }
            return [.turno("m\(i)")] + steps + [.agent(t)]
        }
        // Un turno abierto por la plataforma (agenda, entrega de un encargo): línea de
        // sistema con la causa, no burbuja de la persona con las instrucciones al modelo.
        if t.hasPrefix("⏰ ") { return [.turno("m\(i)"), .user(t)] }
        // ⚠️ Lo que se guardó es lo que se MANDÓ, con toda la fontanería dentro: el
        // bloque de conversación previa que ponía la app antes de esta mudanza, y los
        // `curl` de los adjuntos. Sin limpiarlo, al recargar el hilo la burbuja de la
        // persona sale con un muro de texto que ella nunca escribió — se vio tal cual
        // en el teléfono.
        //
        // ⚠️ Pero esa limpieza la hace `ReplayToMessages` y NO aquí: limpiar dos veces
        // borraba los NOMBRES de los adjuntos antes de que allá se reconstruyeran, y tu
        // foto desaparecía de tu mensaje en cuanto llegaba la respuesta (2026-09-26).
        // Un turno programado lleva pegadas las instrucciones al agente («nadie está
        // mirando… contesta OK»). Son para él; a la persona se le enseña lo que pidió.
        let names = (m["attachments"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return [.turno("m\(i)"), .user(Self.sinReglasDeAgenda(t))] + (names.isEmpty ? [] : [.userAttachments(names)])
    }

    /// Un GET que reintenta si la conexión se cayó o no contestó a tiempo. Sin aviso en
    /// pantalla (eso es de `conReintentos`, que habla del envío): aquí sólo se lee.
    private func leerConReintento(_ url: URL) async throws -> [String: Any] {
        let reintentables: [URLError.Code] = [.networkConnectionLost, .timedOut, .cannotConnectToHost]
        for intento in 1...2 {
            do { return try await pedir(url) }
            catch let e as URLError where reintentables.contains(e.code) {
                EasyBitsClient.diag("[gs] leer \(url.lastPathComponent): \(e.code.rawValue), reintento \(intento)")
            }
        }
        return try await pedir(url)
    }

    /// Sólo la causa de un mensaje de plataforma «⏰ … (causa). …»: en minúsculas; si no
    /// trae paréntesis, la primera frase recortada a 60.
    static func causaDeSistema(_ t: String) -> String {
        let sin = t.hasPrefix("⏰ ") ? String(t.dropFirst(2)) : t
        if let m = sin.range(of: #"^[^(\n]*\(([^)]+)\)"#, options: .regularExpression) {
            let dentro = sin[m]
            if let a = dentro.firstIndex(of: "("), let b = dentro.lastIndex(of: ")"), a < b {
                return String(dentro[dentro.index(after: a)..<b]).lowercased()
            }
        }
        let frase = sin.split(whereSeparator: { $0 == "." || $0 == "\n" || $0 == ":" }).first.map(String.init) ?? sin
        return frase.count > 60 ? String(frase.prefix(59)) + "…" : frase
    }

    /// Mismo prefijo que pone gs (`SCHEDULED_MARK` en `scheduled-turns.server.ts`).
    static func sinReglasDeAgenda(_ t: String) -> String {
        guard t.hasPrefix("⏰ Turno programado"),
              let corte = t.range(of: "\n\nNadie está mirando ahora") else { return t }
        return String(t[..<corte.lowerBound])
    }

    /// Cómo acabó el último turno de cada conversación, según el último `cargar`.
    private var ultimos: [String: ACPClient.UltimoTurno] = [:]
    func ultimoTurno(de sesion: String) async -> ACPClient.UltimoTurno? { ultimos[sesion] }

    /// Conversaciones cuyo historial NO se pudo traer porque había un turno vivo. Lo que
    /// falta llega por el SSE, pero lo de ANTES sigue sin pedirse: hay que volver cuando
    /// el turno cierre.
    private var sinHistorial: Set<String> = []
    func faltaHistorial(de sesion: String) async -> Bool { sinHistorial.contains(sesion) }

    /// Cuántos mensajes quedaron atrás en el último `cargar`. Es lo que permite ofrecer
    /// «ver lo anterior» en vez de fingir que la conversación empieza ahí.
    private(set) var saltados: [String: Int] = [:]
    /// Lo que dijo el último `cargar` del tamaño del hilo: si ya es largo (responde más lento
    /// y gasta más) y de qué conversación viene, si se siguió de otra.
    private var largos: [String: (largo: Bool, vieneDe: String?)] = [:]
    func largoDelHilo(_ id: String) -> (largo: Bool, vieneDe: String?)? { largos[id] }

    /// «Seguir en un chat nuevo»: gs abre una conversación enlazada y el agente recibe el
    /// final de ésta en su primer turno. Devuelve el id de la nueva.
    func continuar(_ id: String) async throws -> String {
        let r = try await pedir(base("/conversations/\(id)/continue"), metodo: "POST", cuerpo: [:])
        guard let nuevo = r["id"] as? String, !nuevo.isEmpty else {
            throw ACPClient.Fallo.remoto("No pude abrir el chat nuevo.")
        }
        largos[nuevo] = (false, id)
        return nuevo
    }

    /// Los archivos que trajo el último `cargar` de cada hilo (crudos, como `/me/files`).
    private var archivosDelHilo: [String: Data] = [:]

    /// Los archivos del hilo que vinieron con el historial; se entregan una vez.
    func tomarArchivos(de id: String) -> Data? {
        archivosDelHilo.removeValue(forKey: id)
    }

    func borrarSesion(_ id: String) async throws {
        // Archiva, no borra: la memoria del hilo sigue en la caja y es reversible.
        _ = try await pedir(base("/conversations/\(id)"), metodo: "DELETE")
    }

    func renombrarSesion(_ id: String, titulo: String) async throws {
        _ = try await pedir(base("/conversations/\(id)"), metodo: "PATCH", cuerpo: ["title": titulo])
    }

    func fijarModo(_ modo: String, sessionID: String) async throws {
        // El modo no se fija por conversación: el permiso se pide turno a turno.
    }

    // MARK: - El turno (AG-UI)

    /// El endpoint AG-UI del agente: un `POST` con `RunAgentInput` para TODO lo del turno —mandar,
    /// reconectar, aprobar, detener, steer—. Contrato estándar: `~/ghostykit/docs/protocol.md`; lo
    /// propio de gs («gs-agui 1»): `~/ghosty-studio/docs/claude/agui-adopcion.md` §0.
    static var runPath = "/agui"
    /// Otro servidor AG-UI para TODO agente (pruebas y desarrollo: `GHOSTY_AGUI_URL`).
    nonisolated(unsafe) static var runURL: URL? = {
        #if DEBUG
        return Gancho.valor("GHOSTY_AGUI_URL").flatMap(URL.init(string:))
        #else
        return nil
        #endif
    }()

    private var transporte: AGUITransport {
        AGUITransport(url: Self.runURL ?? base(Self.runPath), authorize: Self.autorizar)
    }

    /// Cómo se firma cada `POST` del turno. Se puede cambiar en pruebas.
    nonisolated(unsafe) static var autorizar: @Sendable (inout URLRequest, String?) async throws -> Void = { req, rejected in
        // ⚠️ El token se pide en CADA llamada: `Session.accessToken()` lo refresca si caducó.
        req.setValue("Bearer \(try await Session.accessToken(rejected: rejected))", forHTTPHeaderField: "Authorization")
        // La zona del teléfono viaja en cada petición: gs le da al agente la hora de la persona.
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
    }

    /// El `state` compartido de una conversación cambió (capacidades, modelo, subagentes). Lo mira
    /// la barra de subagentes: `(agentID, sessionID, state)`.
    nonisolated(unsafe) static var alCambiarState: (@Sendable (String, String, [String: Any]) -> Void)?

    /// Quién pinta cada conversación: el flujo del turno propio o el vigilante.
    private struct Oyente {
        let id = UUID()
        let cont: AsyncThrowingStream<ACPClient.Replay, Error>.Continuation
        /// El vigilante se queda quieto al terminar el run; el del turno cierra su flujo.
        let vigilante: Bool
    }

    /// La lectura viva de cada conversación (una a la vez). `token` dice cuál es la vigente: un steer
    /// la reemplaza SIN cerrar el flujo de quien pinta.
    private struct Escucha {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var escuchas: [String: Escucha] = [:]
    private var oyentes: [String: Oyente] = [:]
    /// El run que trabaja en cada conversación: va en `forwardedProps.cancel`/`steer` y nombra la
    /// burbuja (`turno-<runId>`).
    private var runVivo: [String: String] = [:]
    /// Aprobaciones abiertas por conversación y lo ya contestado. El contrato pide contestar TODAS
    /// las de un run en un solo `resume`.
    private var abiertas: [String: [AGUIState.Permission]] = [:]
    private var contestadas: [String: [String: AGUIState.Option]] = [:]
    var turnosVivos: Int { escuchas.count }

    private var permisoPendiente: (@Sendable (ACPClient.Permiso) -> Void)?
    func alPedirPermiso(_ handler: @escaping @Sendable (ACPClient.Permiso) -> Void) {
        permisoPendiente = handler
    }

    /// Qué está pasando de verdad en esa conversación, según el servidor.
    private var alCambiarEstado: (@Sendable (String, String) -> Void)?
    func alCambiarEstado(_ handler: @escaping @Sendable (String, String) -> Void) {
        alCambiarEstado = handler
    }

    /// gs ya no tiene cola (gs-agui 1): esto no vuelve a sonar. Queda por el protocolo del store.
    func alHacerCola(_ handler: @escaping @Sendable (Int) -> Void) {}

    private var permisoResuelto: (@Sendable (String) -> Void)?
    func alResolverPermiso(_ handler: @escaping @Sendable (String) -> Void) {
        permisoResuelto = handler
    }

    private var alCaerse: (@Sendable () -> Void)?
    func alPerderse(_ handler: @escaping @Sendable () -> Void) { alCaerse = handler }

    /// Lo que este agente SABE hacer, según el servidor (`state.caps.steer`).
    private var alSaberCapacidades: (@Sendable (Bool) -> Void)?
    func alConocerCapacidades(_ handler: @escaping @Sendable (Bool) -> Void) {
        alSaberCapacidades = handler
    }

    /// Manda el turno y pinta lo que vaya pasando. En AG-UI es UNA petición: el `POST` con el mensaje
    /// contesta el stream del run, así que ya no hay ventana entre encargar y escuchar.
    ///
    /// ⚠️ Si el run se detiene a pedir aprobación, el flujo NO termina: la respuesta a la tarjeta es
    /// otro `POST` (`resume`) cuyo stream sigue en esta misma burbuja, como cuando el turno esperaba.
    nonisolated func prompt(sessionID: String, texto: String, adjuntos: [Adjunto],
                            turnId: String) -> AsyncThrowingStream<ACPClient.Replay, Error> {
        AsyncThrowingStream { cont in
            let oyente = Oyente(cont: cont, vigilante: false)
            Task { await self.arrancarTurno(sessionID, texto: texto, adjuntos: adjuntos, turnId: turnId, oyente) }
            cont.onTermination = { _ in
                // ⚠️ Dejar de escuchar y NADA MÁS: soltar el flujo pasa al reenganchar, al cambiar de
                // pantalla o al suspenderse la app, y nada de eso para el trabajo. Detener lo pide
                // una persona (`cancelar`).
                Task { await self.dejarDeEscuchar(sessionID, si: oyente.id) }
            }
        }
    }

    private func arrancarTurno(_ sesion: String, texto: String, adjuntos: [Adjunto], turnId: String,
                               _ oyente: Oyente) async {
        let input: AGUITransport.Input
        do { input = try await entrada(sesion, texto: texto, adjuntos: adjuntos, runId: turnId) }
        catch { oyente.cont.finish(throwing: error); return }
        escuchar(sesion, oyente) { me in
            // ⚠️ Tiempo prestado por iOS para que el POST llegue aunque apagues el teléfono justo
            // después de mandar. Se suelta en cuanto el servidor acepta el run (`RUN_STARTED`).
            let token = await BackgroundTime.begin("encargar turno")
            self.runVivo[sesion] = turnId
            return try await self.correr(input, sesion: sesion, run: turnId, oyente: me,
                                         reintentarAntesDeEmpezar: true, tiempoPrestado: token)
        }
    }

    /// Engancharse a lo que ya esté pasando en esa conversación: un `POST` sin mensaje nuevo.
    ///
    /// gs contesta `MESSAGES_SNAPSHOT` + `STATE_SNAPSHOT` y luego el run vivo (abre con SU runId), las
    /// aprobaciones abiertas o nada. Después la escucha se queda QUIETA hasta que la reemplacen: gs
    /// puede abrir un turno solo (agenda, entrega) y eso lo avisa `/me/events`, que vuelve a llamar.
    /// El hilo NO sale del snapshot: lo trae el REST de siempre (`messages?after|before`, base local).
    nonisolated func seguir(sessionID: String) -> AsyncThrowingStream<ACPClient.Replay, Error>? {
        AsyncThrowingStream { cont in
            let oyente = Oyente(cont: cont, vigilante: true)
            Task {
                await self.escuchar(sessionID, oyente) { me in
                    let input = AGUITransport.Input(threadId: sessionID, runId: UUID().uuidString.lowercased())
                    return try await self.correr(input, sesion: sessionID, run: nil, oyente: me)
                }
            }
            cont.onTermination = { _ in
                // ⚠️ Irse de una conversación NO cancela su turno. Sólo se deja de escuchar.
                Task { await self.dejarDeEscuchar(sessionID, si: oyente.id) }
            }
        }
    }

    /// Pone `oyente` a pintar esa conversación y corre `trabajo` como la escucha vigente.
    private func escuchar(_ sesion: String, _ oyente: Oyente,
                          _ trabajo: @escaping (Oyente) async throws -> AGUIState.Outcome) {
        escuchas[sesion]?.task.cancel()
        oyentes[sesion] = oyente
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.vivir(sesion, oyente, token: token) { try await trabajo(oyente) }
        }
        escuchas[sesion] = Escucha(token: token, task: task)
    }

    /// El ciclo de una escucha: corre, y al acabar cierra el flujo si le toca. Un run detenido en una
    /// aprobación deja el flujo abierto; el vigilante se queda quieto.
    private func vivir(_ sesion: String, _ oyente: Oyente, token: UUID,
                       _ trabajo: () async throws -> AGUIState.Outcome) async {
        var error: Error?
        do {
            let fin = try await trabajo()
            if case .interrupt = fin { return }  // espera la respuesta a la tarjeta
            if oyente.vigilante { try await Task.sleep(for: .seconds(24 * 3600)) }
        } catch is CancellationError {
        } catch let e {
            error = await fallo(e)
        }
        // Un steer tomó la lectura con el MISMO oyente: su flujo sigue, no se cierra aquí.
        if escuchas[sesion]?.token != token, oyentes[sesion]?.id == oyente.id { return }
        if let error { oyente.cont.finish(throwing: error) } else { oyente.cont.finish() }
        if escuchas[sesion]?.token == token {
            escuchas[sesion] = nil
            oyentes[sesion] = nil
        }
    }

    private func dejarDeEscuchar(_ sesion: String, si id: UUID) {
        // Sólo si sigue siendo el suyo: una escucha nueva ya pudo reemplazarlo.
        guard let o = oyentes[sesion], o.id == id else { return }
        escuchas[sesion]?.task.cancel()
        escuchas[sesion] = nil
        oyentes[sesion] = nil
    }

    /// Corre un run y reparte lo que llega. Devuelve cómo terminó.
    ///
    /// `run`: el run que ya sabemos que es el de esta respuesta (el `turnId` propio, o el vivo en un
    /// resume/steer); `nil` al reconectar, donde lo dice `RUN_STARTED`.
    /// `reintentarAntesDeEmpezar`: red caída o 5xx ANTES de `RUN_STARTED` se reintenta con el MISMO
    /// run (el `runId` es la clave de idempotencia; gs no arranca dos veces el mismo).
    /// `alInyectar`: steer. Hasta `ghosty.injected` no se reparte nada (el stream viejo sigue
    /// pintando); al llegar, se avisa y desde ahí pinta éste.
    private func correr(_ input: AGUITransport.Input, sesion: String, run: String?, oyente: Oyente,
                        reintentarAntesDeEmpezar: Bool = false, tiempoPrestado: Int? = nil,
                        alInyectar: (() async -> Void)? = nil) async throws -> AGUIState.Outcome {
        var prestado = tiempoPrestado
        defer { if let t = prestado { Task { await BackgroundTime.end(t) } } }
        var bridge = AGUIBridge(agentID: agentID, sessionID: sesion, requestRunId: input.runId, knownRunId: run)
        var callado = alInyectar != nil
        var espera: UInt64 = 1
        var intento = 0
        while true {
            var empezo = false
            do {
                for try await e in transporte.run(input) {
                    try Task.checkCancellation()
                    if e.type == "RUN_STARTED" {
                        empezo = true
                        if let t = prestado { prestado = nil; await BackgroundTime.end(t) }
                    }
                    for o in bridge.apply(e) {
                        if callado {
                            guard case .injected = o else { continue }
                            callado = false
                            await alInyectar?()
                            continue
                        }
                        await repartir(o, sesion: sesion, oyente: oyente, bridge: bridge)
                    }
                    if e.type == "RUN_FINISHED" || e.type == "RUN_ERROR" { break }
                }
            } catch let e where !empezo && reintentarAntesDeEmpezar && intento < 4 && Self.reintentable(e) {
                intento += 1
                EasyBitsClient.diag("[agui] encargar: reintento \(intento) en \(espera) s (\(e))")
                Self.alReintentar?("El servidor no responde. Reintento \(intento) de 4…")
                try await Task.sleep(for: .seconds(espera))
                espera *= 2
                continue
            }
            if callado { return bridge.state.outcome ?? .success }  // steer que no entró
            if let id = bridge.liveRunId { runVivo[sesion] = id }
            let fin = bridge.state.outcome ?? .success
            switch fin {
            case .interrupt:
                break
            case .error(let m, let code):
                runVivo[sesion] = nil
                throw code == "quota_exceeded" ? ACPClient.Fallo.limit(m) : ACPClient.Fallo.remoto(m)
            default:
                runVivo[sesion] = nil
                // Un vigilante que vio trabajo en vivo lo cierra como turno; sigue escuchando.
                if oyente.vigilante, bridge.sawLive { oyente.cont.yield(.cerrado(bridge.liveRunId ?? "")) }
            }
            return fin
        }
    }

    /// Una salida del puente al flujo o a quien escucha la señal.
    private func repartir(_ o: AGUIBridge.Output, sesion: String, oyente: Oyente, bridge: AGUIBridge) async {
        switch o {
        case .replay(let r):
            oyente.cont.yield(r)
        case .phase(let p):
            // Esperando tu aprobación el turno NO está en reposo: está detenido por ti.
            if p == "reposo", bridge.state.outcome == .interrupt { return }
            // Sin run vivo detrás (reconectar a un hilo quieto) no hay fase que anunciar.
            if p != "reposo", !bridge.sawLive { return }
            alCambiarEstado?(sesion, p)
        case .caps(let steer):
            alSaberCapacidades?(steer)
        case .state(let s):
            Self.alCambiarState?(agentID, sesion, s)
        case .title(let t):
            EasyBitsClient.diag("[agui] título de \(sesion): \(t)")
        case .notice(let m):
            EasyBitsClient.diag("[agui] \(sesion): \(m)")
        case .injected:
            break
        case .interrupts(let ps):
            abrir(ps, en: sesion)
        case .finished(let fin):
            // Lo que estaba abierto y ya no viene: alguien lo contestó en otra superficie.
            if fin != .interrupt { abrir([], en: sesion) }
        }
    }

    /// Las aprobaciones abiertas de una conversación pasan a ser `ps`: las nuevas se piden, las que
    /// ya no están se retiran (gs ya no manda `permission-resolved`: lo dice su ausencia).
    private func abrir(_ ps: [AGUIState.Permission], en sesion: String) {
        let antes = abiertas[sesion] ?? []
        abiertas[sesion] = ps.isEmpty ? nil : ps
        for viejo in antes where !ps.contains(where: { $0.id == viejo.id }) {
            contestadas[sesion]?[viejo.id] = nil
            permisoResuelto?(viejo.id)
        }
        // ⚠️ Las tarjetas abiertas vuelven en CADA reconexión: sin esta memoria, cada reenganche
        // pintaba otra tarjeta del mismo pedido.
        for p in ps where !antes.contains(where: { $0.id == p.id }) {
            permisoPendiente?(ACPClient.Permiso(
                id: p.id, sessionID: sesion, titulo: p.title, herramienta: p.tool ?? "",
                opciones: p.options.map { ($0.id, $0.name, $0.kind) }))
        }
    }

    /// Contesta una tarjeta. Cuando están contestadas TODAS las del run, sale el `resume` y su stream
    /// sigue en la burbuja del turno que se detuvo (gs lo abre con el runId vivo).
    func responderPermiso(_ id: String, opcion: String) async throws {
        guard let sesion = abiertas.first(where: { $0.value.contains { $0.id == id } })?.key,
              let p = abiertas[sesion]?.first(where: { $0.id == id }) else { return }
        contestadas[sesion, default: [:]][id] = p.options.first { $0.id == opcion }
            ?? .init(id: opcion, name: opcion, kind: opcion.hasPrefix("allow") || opcion == "approve" ? "allow_once" : "reject_once")
        let todas = abiertas[sesion] ?? []
        let respuestas = contestadas[sesion] ?? [:]
        guard todas.allSatisfy({ respuestas[$0.id] != nil }) else { return }
        abiertas[sesion] = nil
        contestadas[sesion] = nil
        todas.forEach { permisoResuelto?($0.id) }
        var input = AGUITransport.Input(threadId: sesion, runId: UUID().uuidString.lowercased())
        input.resume = todas.map { p in
            let o = respuestas[p.id]!
            return .init(interruptId: p.id, approved: o.kind.hasPrefix("allow"), optionId: o.id)
        }
        // Sigue en quien estaba pintando; si nadie (se contestó sin el hilo abierto), el stream se lee
        // igual y lo demás lo trae el hilo al abrirlo.
        let oyente = oyentes[sesion] ?? Oyente(cont: AsyncThrowingStream<ACPClient.Replay, Error>.makeStream().continuation,
                                               vigilante: false)
        let vivo = runVivo[sesion]
        escuchar(sesion, oyente) { me in
            try await self.correr(input, sesion: sesion, run: vivo, oyente: me)
        }
    }

    /// Un mensaje MÁS para el turno que ya corre («steer», §0.6): `POST` con el mensaje, `runId`
    /// nuevo y `forwardedProps.steer` = el run vivo. Si entra (`ghosty.injected`), este stream
    /// sigue pintando el run y el viejo se suelta; si no, `409 run_active` y no pasa nada.
    func mandarMas(sessionID: String, texto: String, turnId: String) async throws -> Bool {
        guard let vivo = runVivo[sessionID], let oyente = oyentes[sessionID] else { return false }
        var input = try await entrada(sessionID, texto: texto, adjuntos: [], runId: turnId)
        input.forwarded["steer"] = vivo
        let decision = Decision()
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.vivir(sessionID, oyente, token: token) {
                do {
                    let fin = try await self.correr(input, sesion: sessionID, run: vivo, oyente: oyente) {
                        await self.tomarLectura(sessionID, token: token)
                        await decision.dar(true)
                    }
                    await decision.dar(false)
                    return fin
                } catch {
                    await decision.dar(false)
                    // No entró: no es asunto de quien pinta (sigue la lectura vieja).
                    if await self.escuchas[sessionID]?.token != token { throw CancellationError() }
                    throw error
                }
            }
        }
        pendiente[sessionID] = task
        let entro = await decision.esperar()
        if !entro { task.cancel(); pendiente[sessionID] = nil }
        return entro
    }

    /// La lectura de un steer mientras se sabe si entró.
    private var pendiente: [String: Task<Void, Never>] = [:]

    /// El steer entró: desde aquí su lectura es la vigente y la vieja se va SIN cerrar el flujo.
    private func tomarLectura(_ sesion: String, token: UUID) {
        let vieja = escuchas[sesion]
        if let t = pendiente.removeValue(forKey: sesion) { escuchas[sesion] = Escucha(token: token, task: t) }
        vieja?.task.cancel()
    }

    /// Encarga un turno SIN pintar su respuesta (la extensión «Enviar a Ghosty»): el mismo `POST`,
    /// leído hasta que el servidor lo acepta. El turno es del servidor; soltar no lo detiene.
    func encargarSinEscuchar(sessionID: String, texto: String, adjuntos: [Adjunto]) async throws -> String {
        let turnId = UUID().uuidString.lowercased()
        let input = try await entrada(sessionID, texto: texto, adjuntos: adjuntos, runId: turnId)
        do {
            for try await e in transporte.run(input) where e.type == "RUN_STARTED" { break }
        } catch { throw await fallo(error) }
        return turnId
    }

    /// Detener: un `POST` sin mensaje con el run en `forwardedProps.cancel`. Si la conversación
    /// esperaba aprobaciones, se contestan `cancelled` (= no) en la misma petición.
    func cancelar(_ sessionID: String) async {
        var input = AGUITransport.Input(threadId: sessionID, runId: UUID().uuidString.lowercased())
        input.cancel = runVivo[sessionID] ?? ""
        if let ps = abiertas[sessionID] {
            input.resume = ps.map { .init(interruptId: $0.id, approved: nil) }
            abiertas[sessionID] = nil
            contestadas[sessionID] = nil
            ps.forEach { permisoResuelto?($0.id) }
        }
        runVivo[sessionID] = nil
        await soloLeer(input, "detener")
    }

    /// Detener UN subagente (`forwardedProps.stopSubagent`, sustituye `POST …/subagents/:id/stop`).
    func detenerSubagente(_ taskId: String, en sessionID: String) async {
        var input = AGUITransport.Input(threadId: sessionID, runId: UUID().uuidString.lowercased())
        input.forwarded["stopSubagent"] = taskId
        await soloLeer(input, "detener subagente")
    }

    /// Lee un run que nadie pinta hasta que cierra (detener, subagentes).
    private func soloLeer(_ input: AGUITransport.Input, _ que: String) async {
        do {
            for try await e in transporte.run(input) {
                if e.type == "STATE_SNAPSHOT", let s = e["snapshot"] as? [String: Any] {
                    Self.alCambiarState?(agentID, input.threadId, s)
                }
                if e.type == "RUN_FINISHED" || e.type == "RUN_ERROR" { break }
            }
        } catch {
            EasyBitsClient.diag("[agui] \(que) \(input.threadId): \(error)")
        }
    }

    /// El `state` de una conversación sin pintar nada: reconectar y leer hasta su `STATE_SNAPSHOT`.
    /// Cortar después no detiene nada (§6 del contrato).
    func estado(de sessionID: String) async throws -> [String: Any]? {
        let input = AGUITransport.Input(threadId: sessionID, runId: UUID().uuidString.lowercased())
        do {
            for try await e in transporte.run(input) {
                if e.type == "STATE_SNAPSHOT" { return e["snapshot"] as? [String: Any] ?? [:] }
                if e.type == "RUN_FINISHED" || e.type == "RUN_ERROR" { return nil }
            }
        } catch { throw await fallo(error) }
        return nil
    }

    /// El `RunAgentInput` de un mensaje nuevo. Si había tarjetas abiertas, escribir otra cosa las
    /// contesta `cancelled` (§4 del contrato): el agente no corre esa acción.
    private func entrada(_ sesion: String, texto: String, adjuntos: [Adjunto], runId: String) async throws -> AGUITransport.Input {
        var input = AGUITransport.Input(threadId: sesion, runId: runId, text: texto)
        for a in adjuntos {
            input.attachments.append(.init(json: try await Self.parte(a)))
        }
        if let ps = abiertas[sesion] {
            input.resume = ps.map { .init(interruptId: $0.id, approved: nil) }
            abiertas[sesion] = nil
            contestadas[sesion] = nil
            ps.forEach { permisoResuelto?($0.id) }
        }
        return input
    }

    /// Un adjunto como parte de contenido AG-UI. Lo preferido por gs (§0.2) es la URL del archivo ya
    /// subido (`GhostyAPI.subir` lo hace antes de mandar); si no hay, va en base64 (≤ 10 MB).
    static func parte(_ a: Adjunto) async throws -> [String: Any] {
        let tipo = a.mime.hasPrefix("image/") ? "image" : a.mime.hasPrefix("audio/") ? "audio" : "document"
        var p: [String: Any] = ["type": tipo, "mimeType": a.mime, "filename": a.nombre]
        // De «Mis archivos»: por id, con su liga fresca.
        if a.esDeBiblioteca, let id = a.remoto?.id {
            p["metadata"] = ["fileId": id]
            let url = (try? await GhostyAPI.urlDe(id)) ?? ""
            p["source"] = ["type": "url", "value": url, "mimeType": a.mime]
            return p
        }
        if let url = a.remoto?.url, !url.isEmpty {
            if let id = a.remoto?.id { p["metadata"] = ["fileId": id] }
            p["source"] = ["type": "url", "value": url, "mimeType": a.mime]
        } else {
            p["source"] = ["type": "data", "value": a.datos.base64EncodedString(), "mimeType": a.mime]
        }
        return p
    }

    /// Reintenta ante red caída o 502/503/504 (gs reiniciándose por un deploy): 1, 2, 4, 8 s. Un 4xx
    /// no se reintenta: eso es un «no», no un «ahora no».
    private func conReintentos(_ op: () async throws -> [String: Any]) async throws -> [String: Any] {
        var espera: UInt64 = 1
        for intento in 1...5 {
            do { return try await op() }
            catch let e as ACPClient.Fallo {
                guard case .transitorio = e, intento < 5 else { throw e }
            } catch {
                guard Self.reintentable(error), intento < 5 else { throw error }
            }
            EasyBitsClient.diag("[gs] reintento \(intento) en \(espera) s")
            Self.alReintentar?("El servidor no responde. Reintento \(intento) de 4…")
            try await Task.sleep(for: .seconds(espera))
            espera *= 2
        }
        throw ACPClient.Fallo.noConectado
    }

    private static func reintentable(_ e: Error) -> Bool {
        if let h = e as? AGUITransport.HTTPError { return [502, 503, 504].contains(h.status) }
        if let u = e as? URLError {
            return [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet,
                    .cannotFindHost, .dnsLookupFailed].contains(u.code)
        }
        // ⚠️ Lo que deja iOS al apagar la pantalla con el POST en el aire: un error POSIX (53, 54,
        // 57), no un `URLError`. Reintentar es seguro: el `runId` es la clave de idempotencia.
        let n = e as NSError
        return n.domain == NSPOSIXErrorDomain && [53, 54, 57].contains(n.code)
    }

    /// Lo que se le enseña a la app cuando el servidor dijo que no antes de empezar.
    private func fallo(_ error: Error) async -> Error {
        guard let h = error as? AGUITransport.HTTPError else { return error }
        switch h.status {
        case 401:
            await Self.sessionDead()
            return Session.Fallo.caducada
        // 402 = un límite del plan: no es un fallo de red; la frase ya viene redactada por gs.
        case 402: return ACPClient.Fallo.limit(h.message)
        case 502, 503, 504: return ACPClient.Fallo.transitorio(h.status)
        case 403: return ACPClient.Fallo.remoto("Hay que volver a entrar a tu cuenta.")
        // Un mensaje con un run vivo que no admite steer (§0.6): no hay cola, se dice.
        case 409 where h.code == "run_active":
            return ACPClient.Fallo.remoto("Tu agente sigue con lo anterior. Espera a que termine o detenlo.")
        case 409 where h.code == "interrupt_pending":
            return ACPClient.Fallo.remoto("Tu agente espera tu visto bueno antes de seguir.")
        case 404: return ACPClient.Fallo.remoto("Ese agente o esa conversación ya no existe.")
        case 429: return ACPClient.Fallo.remoto(h.message.isEmpty ? "Se acabó el cupo de turnos por ahora." : h.message)
        default: return ACPClient.Fallo.remoto(h.message)
        }
    }
}


/// Tiempo de ejecución en segundo plano que iOS presta a una tarea corta (`beginBackgroundTask`).
/// `Core` también vive en la extensión «Enviar a Ghosty», donde `UIApplication.shared` no
/// existe: por eso la APP conecta los ganchos al arrancar (`Delegado`). Sin ellos no hace nada.
enum BackgroundTime {
    @MainActor static var onBegin: ((String) -> Int)?
    @MainActor static var onEnd: ((Int) -> Void)?
    @MainActor static func begin(_ name: String) -> Int { onBegin?(name) ?? -1 }
    @MainActor static func end(_ id: Int) { if id >= 0 { onEnd?(id) } }
}

// MARK: - Sync v2 (`docs/claude/sync-v2.md` en gs)

extension ClienteGS {
    /// Una página del hilo por `seq`.
    struct MessagesPage: Sendable {
        /// Qué copia de gs es. Si cambia, lo guardado de ese hilo ya no vale.
        var epoch: String?
        /// Con `seq`, `turnId` e id de vista `s<seq>`; las entregas de la página, sin `seq`.
        var messages: [Message]
        var hasMoreBefore: Bool
        var hasMoreAfter: Bool
        var lastSeq: Int?
        var enCurso: Bool
        var ultimoTurno: ACPClient.UltimoTurno?
        var largo: Bool
        var continuesFrom: String?
        /// Los archivos de la página, por nombre (para entregas y adjuntos).
        var files: [String: GhostyAPI.ArchivoDeSesion]
    }

    /// `after` = lo nuevo, `before` = lo anterior; sin ninguno, la última página.
    func messages(_ sid: String, agentID: String, after: Int? = nil, before: Int? = nil,
                  limit: Int = 40) async throws -> MessagesPage {
        var c = URLComponents(url: base("/conversations/\(sid)/messages"), resolvingAgainstBaseURL: false)!
        var q = [URLQueryItem(name: "limit", value: "\(limit)"), URLQueryItem(name: "archivos", value: "1")]
        if let after { q.append(URLQueryItem(name: "after", value: "\(after)")) }
        if let before { q.append(URLQueryItem(name: "before", value: "\(before)")) }
        c.queryItems = q
        let r = try await leerConReintento(c.url!)
        let raw = r["messages"] as? [[String: Any]] ?? []
        // El conversor ubica las entregas por `despuesDe` contra el índice del servidor: con
        // `afterSeq` como `afterIndex` y `m<seq>` como frontera, todo cae en su sitio por seq.
        var files: [String: GhostyAPI.ArchivoDeSesion] = [:]
        if let list = r["files"] as? [[String: Any]] {
            let renamed = list.map { f -> [String: Any] in
                var f = f
                if let a = f["afterSeq"] { f["afterIndex"] = a is NSNull ? -1 : a }
                return f
            }
            if let datos = try? JSONSerialization.data(withJSONObject: ["files": renamed]) {
                files = GhostyAPI.archivosDe(sesion: sid, agente: agentID, datos: datos) ?? [:]
            }
        }
        let replay = raw.flatMap { m -> [ACPClient.Replay] in
            guard let seq = m["seq"] as? Int else { return [] }
            return Self.replay(of: m, index: seq)
        }
        let turnBySeq = Dictionary(raw.compactMap { m -> (Int, String)? in
            guard let seq = m["seq"] as? Int, let t = m["turnId"] as? String else { return nil }
            return (seq, t)
        }, uniquingKeysWith: { a, _ in a })
        let converted = ReplayToMessages.convertWithServerIndex(replay, archivos: files)
        let messages = converted.messages.map { m -> Message in
            guard let seq = converted.serverIndex[m.id] else { return m }
            return Message(id: "s\(seq)", kind: m.kind, seq: seq, turnId: turnBySeq[seq])
        }
        let epoch: String? = (r["epoch"] as? String) ?? (r["epoch"] as? NSNumber)?.stringValue
        return MessagesPage(
            epoch: epoch, messages: messages,
            hasMoreBefore: r["hasMoreBefore"] as? Bool ?? false,
            hasMoreAfter: r["hasMoreAfter"] as? Bool ?? false,
            lastSeq: r["lastSeq"] as? Int, enCurso: r["enCurso"] as? Bool ?? false,
            ultimoTurno: ACPClient.UltimoTurno.desde(r["ultimoTurno"]),
            largo: r["largo"] as? Bool ?? false, continuesFrom: r["continuesFrom"] as? String,
            files: files)
    }
}

// MARK: - Sync v2: la cuenta entera (`/me/sync`)

extension ClienteGS {
    struct AccountSync: Sendable {
        struct Item: Sendable {
            var agentID: String
            var session: ACPClient.Session
            var lastSeq: Int?
            var preview: (text: String, fromUser: Bool)?
            var archived: Bool
        }
        var cursor: String?
        var agents: [String]
        var items: [Item]
        var hasMore: Bool
    }

    /// Lo que cambió desde `since` en TODOS los agentes (sin `since`, todo). Una llamada.
    func syncAccount(since: String?) async throws -> AccountSync {
        var c = URLComponents(url: Session.base.appendingPathComponent("api/v2/me/sync"), resolvingAgainstBaseURL: false)!
        var q = [URLQueryItem(name: "client", value: "ios")]
        if let since { q.append(URLQueryItem(name: "since", value: since)) }
        c.queryItems = q
        let r = try await leerConReintento(c.url!)
        let raw = r["conversations"] as? [[String: Any]] ?? []
        let items = raw.compactMap { c -> AccountSync.Item? in
            guard let agent = c["agentId"] as? String, let session = Self.parseSessions([c]).first else { return nil }
            let p = c["preview"] as? [String: Any]
            return AccountSync.Item(
                agentID: agent, session: session, lastSeq: c["lastSeq"] as? Int,
                preview: (p?["text"] as? String).map { ($0, p?["role"] as? String == "user") },
                archived: c["archived"] as? Bool ?? false)
        }
        let cursor = (r["cursor"] as? String) ?? (r["cursor"] as? NSNumber)?.stringValue
        return AccountSync(cursor: cursor, agents: r["agents"] as? [String] ?? [], items: items,
                           hasMore: r["hasMore"] as? Bool ?? false)
    }
}


/// Una respuesta de un solo uso (¿entró el steer?): la primera gana.
private actor Decision {
    private var valor: Bool?
    private var esperando: [CheckedContinuation<Bool, Never>] = []

    func dar(_ v: Bool) {
        guard valor == nil else { return }
        valor = v
        esperando.forEach { $0.resume(returning: v) }
        esperando = []
    }

    func esperar() async -> Bool {
        if let valor { return valor }
        return await withCheckedContinuation { esperando.append($0) }
    }
}
