import Foundation

/// Las conversaciones favoritas, por `agente/sesión`. En el teléfono, como en Android.
enum ChatsFavoritos {
    /// La llave de una conversación: `agente/sesión`.
    static func llave(_ agente: String, _ sesion: String) -> String { "\(agente)/\(sesion)" }

    private static let clave = "app.chats.favoritas"
    static var ids: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: clave) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: clave) }
    }
    static func alternar(_ id: String) {
        var s = ids
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        ids = s
    }
}

/// Hilos largos cuyo aviso «Este chat ya es largo» cerraste, por `agente/sesión`.
enum HilosLargosOcultos {
    private static let clave = "app.chats.largosOcultos"
    static var ids: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: clave) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: clave) }
    }
}
