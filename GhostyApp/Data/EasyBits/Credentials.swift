import Foundation
import Security

/// Dónde vive la credencial.
///
/// Orden: **Keychain** (lo que la persona pegó en Ajustes) → variables de entorno
/// (el camino de desarrollo con el simulador) → `Info.plist`. Nunca se versiona ni
/// viaja en el binario.
///
/// ⚠️ Hay dos clases de llave y no dan lo mismo:
/// - `agt_…` es el **token del agente** (su `embedToken`, que la caja hornea como
///   `ACP_AGENT_TOKEN`). Alcanza **sólo a ese agente** y no puede listar ni borrar.
///   Es la que va en el teléfono de alguien más.
/// - `eb_sk_…` es la **llave de cuenta**. Lista todos los agentes y **puede
///   borrarlos**. Sólo para tu propia máquina.
enum Credentials {

    static var apiKey: String? {
        Keychain.leer(.token)
            ?? entorno("EASYBITS_API_KEY")
            ?? plist("EasyBitsAPIKey")
    }

    static var agentID: String? {
        Keychain.leer(.agente)
            ?? entorno("GHOSTY_AGENT_ID")
            ?? plist("GhostyAgentId")
    }

    /// `true` cuando la llave sólo alcanza a un agente: entonces no se puede listar
    /// y hay que traer el id configurado.
    static var esTokenDeAgente: Bool {
        (apiKey ?? "").hasPrefix("agt_")
    }

    static func guardar(token: String, agente: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = agente.trimmingCharacters(in: .whitespacesAndNewlines)
        t.isEmpty ? Keychain.borrar(.token)  : Keychain.escribir(.token, t)
        a.isEmpty ? Keychain.borrar(.agente) : Keychain.escribir(.agente, a)
    }

    // MARK: - Fuentes de respaldo

    private static func entorno(_ clave: String) -> String? {
        let v = ProcessInfo.processInfo.environment[clave]
        return (v?.isEmpty == false) ? v : nil
    }

    private static func plist(_ clave: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: clave) as? String,
              !v.isEmpty, !v.hasPrefix("$(") else { return nil }
        return v
    }
}

/// Llavero. Se usa `kSecClassGenericPassword` con `WhenUnlockedThisDeviceOnly`: la
/// credencial no debe viajar al respaldo de iCloud ni a otro dispositivo.
enum Keychain {
    enum Clave: String {
        case token  = "easybits.token"
        case agente = "ghosty.agentId"
    }

    private static let servicio = "studio.ghosty.app"

    static func leer(_ clave: Clave) -> String? {
        var consulta = base(clave)
        consulta[kSecReturnData as String] = true
        consulta[kSecMatchLimit as String] = kSecMatchLimitOne
        var salida: CFTypeRef?
        guard SecItemCopyMatching(consulta as CFDictionary, &salida) == errSecSuccess,
              let datos = salida as? Data,
              let texto = String(data: datos, encoding: .utf8),
              !texto.isEmpty
        else { return nil }
        return texto
    }

    static func escribir(_ clave: Clave, _ valor: String) {
        borrar(clave)
        var item = base(clave)
        item[kSecValueData as String] = Data(valor.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func borrar(_ clave: Clave) {
        SecItemDelete(base(clave) as CFDictionary)
    }

    private static func base(_ clave: Clave) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicio,
            kSecAttrAccount as String: clave.rawValue,
        ]
    }
}
