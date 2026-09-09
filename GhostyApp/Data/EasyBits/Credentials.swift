import Foundation
import Security

/// Un agente conectado en este teléfono.
///
/// El nombre lo pone la persona: con un token de agente (`agt_…`) el API contesta
/// **401** tanto al listar como al leer ese agente —sólo deja mandarle mensajes—, así
/// que el servidor no puede decirnos cómo se llama. Comprobado contra la API real.
struct AgentAccount: Identifiable, Codable, Equatable {
    var id: String          // agentId
    var token: String       // agt_… o eb_sk_…
    var name: String

    var esTokenDeAgente: Bool { token.hasPrefix("agt_") }
    var esLlaveDeCuenta: Bool { token.hasPrefix("eb_sk_") }
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
        // Nada guardado: se cae al agente horneado en el build (el del demo) o a las
        // variables de entorno del simulador.
        if let t = deEntornoOPlist("EASYBITS_API_KEY", "EasyBitsAPIKey"),
           let id = deEntornoOPlist("GHOSTY_AGENT_ID", "GhostyAgentId") {
            let nombre = deEntornoOPlist("GHOSTY_AGENT_NAME", "GhostyAgentName") ?? "Mi agente"
            return [AgentAccount(id: id, token: t, name: nombre)]
        }
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

    // MARK: - Respaldos

    private static func deEntornoOPlist(_ env: String, _ plist: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        if let v = Bundle.main.object(forInfoDictionaryKey: plist) as? String,
           !v.isEmpty, !v.hasPrefix("$(") { return v }
        return nil
    }
}

/// Llavero. `WhenUnlockedThisDeviceOnly`: la credencial no viaja al respaldo de
/// iCloud ni a otro dispositivo.
enum Keychain {
    enum Clave: String {
        case cuentas = "easybits.accounts"
        case activo  = "ghosty.activeAgent"
    }

    private static let servicio = "studio.ghosty.app"

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
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func borrar(_ clave: Clave) { SecItemDelete(base(clave) as CFDictionary) }

    private static func base(_ clave: Clave) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: servicio,
         kSecAttrAccount as String: clave.rawValue]
    }
}
