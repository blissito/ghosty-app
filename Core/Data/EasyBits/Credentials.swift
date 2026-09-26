import Foundation
import Security

/// Un agente conectado en este teléfono.
///
/// El nombre lo pone la persona: con un token de agente (`agt_…`) el API contesta
/// **401** tanto al listar como al leer ese agente —sólo deja mandarle mensajes—, así
/// que el servidor no puede decirnos cómo se llama. Comprobado contra la API real.
struct AgentAccount: Identifiable, Codable, Equatable {
    var id: String          // agentId
    var token: String       // agt_… · eb_sk_… · gat_… (agente nativo por ACP)
    var name: String
    /// Host de la caja ACP, tal como lo manda el servidor. `nil` = derivarlo del id
    /// (el dominio por defecto). Viene del servidor y no cableado porque ya hay dos
    /// fierros y el dominio puede cambiar sin que la app se entere.
    var host: String?
    /// Motor (`claude`, `ghosty-lite`, `goose`…), para distinguir homónimos.
    var motor: String? = nil
    /// Correo del dueño cuando el agente es compartido conmigo (`AgentShare` en gs).
    var compartidoPor: String? = nil
    /// Último turno MÍO con este agente, para ordenar por último uso.
    var ultimaActividad: Date? = nil
    /// De qué espacio es. Opcional: el caché guardado antes de esto sigue decodificando.
    var space: AgentSpace? = nil

    var esCompartido: Bool { compartidoPor != nil }
    /// «Ghosty · claude»: el nombre solo no distingue cuatro «Ghosty».
    var rotulo: String { motor.map { "\(name) · \($0)" } ?? name }

    var esTokenDeAgente: Bool { token.hasPrefix("agt_") }
    var esLlaveDeCuenta: Bool { token.hasPrefix("eb_sk_") }
    /// Agente nativo de ghosty.studio que habla ACP.
    var esAgenteNativo: Bool { token.hasPrefix("gat_") }
}

/// Los agentes conectados y cuál está activo. Todo en el llavero de ESTE teléfono.
enum Credentials {

    // MARK: - Lectura

    static var accounts: [AgentAccount] {
        if let json = Keychain.leer(.cuentas),
           let datos = json.data(using: .utf8),
           let lista = try? JSONDecoder().decode([AgentAccount].self, from: datos),
           !lista.isEmpty {
            return lista
        }
        // ⚠️ Ya NO hay respaldo al token horneado en el build. La credencial sale del
        // login contra ghosty.studio, y punto: dos caminos de autenticación vivos
        // significan que el que no pruebas es donde se esconde el fallo.
        return []
    }

    static var activeID: String? {
        let ids = accounts.map(\.id)
        if let guardado = Keychain.leer(.activo), ids.contains(guardado) { return guardado }
        return ids.first
    }

    static var active: AgentAccount? {
        guard let id = activeID else { return nil }
        return accounts.first { $0.id == id }
    }

    // MARK: - Escritura

    static func guardar(_ lista: [AgentAccount]) {
        guard let datos = try? JSONEncoder().encode(lista),
              let json = String(data: datos, encoding: .utf8) else { return }
        lista.isEmpty ? Keychain.borrar(.cuentas) : Keychain.escribir(.cuentas, json)
    }

    /// Añade o reemplaza por id, y lo deja activo.
    static func upsert(_ cuenta: AgentAccount) {
        var lista = accounts
        if let i = lista.firstIndex(where: { $0.id == cuenta.id }) {
            lista[i] = cuenta
        } else {
            lista.append(cuenta)
        }
        guardar(lista)
        activar(cuenta.id)
    }

    static func quitar(_ id: String) {
        guardar(accounts.filter { $0.id != id })
        if Keychain.leer(.activo) == id { Keychain.borrar(.activo) }
    }

    static func activar(_ id: String) {
        Keychain.escribir(.activo, id)
    }

    static func olvidarTodo() {
        Keychain.borrar(.cuentas); Keychain.borrar(.activo)
    }

}

/// Llavero. `AfterFirstUnlockThisDeviceOnly`: la credencial no viaja al respaldo de
/// iCloud ni a otro dispositivo.
enum Keychain {
    enum Clave: String {
        case cuentas = "easybits.accounts"
        case activo  = "ghosty.activeAgent"
        /// La sesión OAuth2 con ghosty.studio (access + refresh). Ver `Session`.
        case sesion  = "ghosty.session"
    }

    private static let servicio = "studio.ghosty.app"

    /// Una sola vez por instalación: los ítems escritos con `WhenUnlocked` se reescriben
    /// con `AfterFirstUnlock` para que el push silencioso en frío (teléfono bloqueado)
    /// pueda leer la sesión. Corre en primer plano, con el teléfono desbloqueado.
    private static var migrado = false
    static func migrarAccesibilidad() {
        guard !migrado else { return }
        migrado = true
        let marca = "llavero.afterFirstUnlock"
        guard !UserDefaults.standard.bool(forKey: marca) else { return }
        for clave in [Clave.cuentas, .activo, .sesion] {
            if let v = leer(clave) { escribir(clave, v) }
        }
        UserDefaults.standard.set(true, forKey: marca)
    }

    static func leer(_ clave: Clave) -> String? {
        var q = base(clave)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var salida: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &salida) == errSecSuccess,
              let d = salida as? Data, let t = String(data: d, encoding: .utf8), !t.isEmpty
        else { return nil }
        return t
    }

    static func escribir(_ clave: Clave, _ valor: String) {
        borrar(clave)
        var item = base(clave)
        item[kSecValueData as String] = Data(valor.utf8)
        // `AfterFirstUnlock` y no `WhenUnlocked`: un push silencioso con el teléfono
        // bloqueado arranca la app en frío y tiene que poder leer la sesión (`recogerYa`).
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func borrar(_ clave: Clave) { SecItemDelete(base(clave) as CFDictionary) }

    private static func base(_ clave: Clave) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: servicio,
         kSecAttrAccount as String: clave.rawValue]
    }
}

/// Agentes favoritos, por TELÉFONO (UserDefaults), no por cuenta: es una comodidad de
/// esta pantalla, igual que en la app de Mac (`notch.favoritos`).
enum Favoritos {
    private static let clave = "app.favoritos"
    static var ids: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: clave) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: clave) }
    }
    static func es(_ id: String) -> Bool { ids.contains(id) }
    static func alternar(_ id: String) {
        var s = ids
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        ids = s
    }
}
