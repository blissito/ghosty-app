import Foundation

/// Las conversaciones favoritas, por `agente/sesión` (o `agente/<clave local>` mientras un
/// chat nuevo no tiene sesión). En el teléfono, como `FavoritesStore` de Android.
///
/// ⚠️ UN store observable que leen la lista y el chat. Antes cada vista copiaba el set de
/// UserDefaults al aparecer: marcar desde el chat no se veía en la lista, y en la lista el
/// primer toque decidía con la copia vieja (quitaba en vez de poner). Y el chat usaba el
/// agente SELECCIONADO y exigía sesión: en un chat nuevo la estrella no hacía nada.
@Observable
@MainActor
final class ChatsFavoritos {
    static let compartido = ChatsFavoritos()

    /// La llave de una conversación: `agente/sesión`.
    nonisolated static func llave(_ agente: String, _ sesion: String) -> String { "\(agente)/\(sesion)" }

    private static let clave = "app.chats.favoritas"
    private(set) var ids: Set<String> = Set(UserDefaults.standard.stringArray(forKey: ChatsFavoritos.clave) ?? []) {
        didSet { UserDefaults.standard.set(Array(ids).sorted(), forKey: Self.clave) }
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func alternar(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func poner(_ id: String, _ favorito: Bool) {
        if favorito { ids.insert(id) } else { ids.remove(id) }
    }

    /// Un chat nuevo marcado antes de tener sesión: al llegar la sesión, su llave local
    /// pasa a ser la real (la que usa la lista desde ese momento).
    func migrar(de vieja: String, a nueva: String) {
        guard vieja != nueva, ids.contains(vieja) else { return }
        ids.remove(vieja)
        ids.insert(nueva)
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
