import Foundation
import Observation

/// Lo que la app publicada cambia SIN build nueva: gs lo sirve en `/api/v2/app/config` y se
/// edita en /admin/settings. La revisión de Apple tarda de 1 a 3 días; esto, un minuto.
///
/// ⚠️ Sólo para lo que Apple ya revisó. Los flags APAGAN lo que falla; encender una función
/// que nunca vio la revisión es lo que prohíbe la 2.3.1.
///
/// Nunca bloquea el arranque: se pinta con lo último guardado (o los defaults) y se refresca
/// por detrás. Sin red, sigue lo de antes.
@MainActor
@Observable
final class AppConfig {
    static let shared = AppConfig()

    struct Values: Codable, Equatable {
        /// Builds menores ya no sirven: se pide actualizar y no se deja seguir.
        var minBuild = 0
        /// Builds menores ven un aviso que se puede cerrar.
        var suggestBuild = 0
        /// Ausente = encendido.
        var flags: [String: Bool] = [:]

        init() {}

        /// Una clave ausente es su default, no un error: una config vieja o parcial no puede
        /// tirar la config entera.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            minBuild = try c.decodeIfPresent(Int.self, forKey: .minBuild) ?? 0
            suggestBuild = try c.decodeIfPresent(Int.self, forKey: .suggestBuild) ?? 0
            flags = try c.decodeIfPresent([String: Bool].self, forKey: .flags) ?? [:]
        }
    }

    private(set) var values: Values
    /// El `suggestBuild` que ya se cerró: el aviso no vuelve hasta que suba el número.
    private var dismissedSuggest: Int

    private static let cacheKey = "appConfig.v1"
    private static let dismissedKey = "appConfig.dismissedSuggest"
    /// `itms-apps://` abre la App Store directo, sin pasar por Safari. ⚠️ El simulador no tiene
    /// App Store: ahí el botón «no hace nada» y es normal.
    static let storeURL = URL(string: "itms-apps://apps.apple.com/app/id6810017404")!

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    private init() {
        let d = UserDefaults.standard
        values = d.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(Values.self, from: $0) } ?? Values()
        dismissedSuggest = d.integer(forKey: Self.dismissedKey)
        // Gancho: `GHOSTY_CONFIG='{"minBuild":99}'` finge lo que diría gs, para ver los
        // avisos en el simulador sin tocar la config de producción.
        if let raw = Gancho.valor("GHOSTY_CONFIG"), let v = try? JSONDecoder().decode(Values.self, from: Data(raw.utf8)) {
            values = v
        }
    }

    func isOn(_ flag: String) -> Bool { values.flags[flag] ?? true }

    /// ⚠️ En Debug sólo con el gancho: el simulador compila con build 1 y cualquier
    /// `minBuild` real lo dejaría encerrado.
    private var gateApplies: Bool {
        #if DEBUG
        return Gancho.valor("GHOSTY_CONFIG") != nil
        #else
        return true
        #endif
    }

    var mustUpdate: Bool { gateApplies && Self.currentBuild < values.minBuild }

    var shouldSuggestUpdate: Bool {
        gateApplies && !mustUpdate && Self.currentBuild < values.suggestBuild && dismissedSuggest < values.suggestBuild
    }

    func dismissSuggestion() {
        dismissedSuggest = values.suggestBuild
        UserDefaults.standard.set(dismissedSuggest, forKey: Self.dismissedKey)
    }

    /// Al abrir y al volver del fondo. Barato: un GET público con caché de 60 s en gs.
    func refresh() async {
        if Gancho.valor("GHOSTY_CONFIG") != nil { return }
        var req = URLRequest(url: Session.base.appendingPathComponent("api/v2/app/config"))
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let v = try? JSONDecoder().decode(Values.self, from: data) else { return }
        if v != values {
            values = v
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}
