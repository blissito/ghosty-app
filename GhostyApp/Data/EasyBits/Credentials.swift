import Foundation

/// De dónde sale la llave. **Nunca se versiona**: se lee del entorno o de un
/// archivo en el home. Si un día esto se reparte a alguien más, la llave de cuenta
/// no puede viajar en el binario — ahí tocaría un token por agente.
enum Credentials {
    static func easyBitsAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["EASYBITS_API_KEY"],
           !env.isEmpty { return env }

        // Info.plist, para poder correr desde el simulador sin exportar variables
        if let plist = Bundle.main.object(forInfoDictionaryKey: "EasyBitsAPIKey") as? String,
           !plist.isEmpty, !plist.hasPrefix("$(") { return plist }

        // ~/.ghosty-app.json → { "easyBitsApiKey": "eb_sk_live_…", "agentId": "…" }
        // Sólo en macOS: en iOS el sandbox no tiene home del usuario.
        if let cfg = localConfig(), let k = cfg["easyBitsApiKey"] as? String, !k.isEmpty {
            return k
        }
        return nil
    }

    static func defaultAgentID() -> String? {
        if let env = ProcessInfo.processInfo.environment["GHOSTY_AGENT_ID"], !env.isEmpty { return env }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "GhostyAgentId") as? String,
           !plist.isEmpty, !plist.hasPrefix("$(") { return plist }
        if let cfg = localConfig(), let a = cfg["agentId"] as? String, !a.isEmpty { return a }
        return nil
    }

    private static func localConfig() -> [String: Any]? {
        #if !os(macOS)
        return nil
        #else
        let ruta = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".ghosty-app.json")
        guard let data = try? Data(contentsOf: ruta),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
        #endif
    }
}
