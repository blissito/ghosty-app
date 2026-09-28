import SwiftUI
import UIKit

/// La entrada de la extensión «Enviar a Ghosty»: una ACCIÓN, que es lo que sale en la
/// lista de abajo de la hoja de compartir (como «Ask Gemini» o «Send to Manus»). Las de
/// tipo *share* salen en la fila de iconos de arriba.
///
/// Sólo monta la hoja de SwiftUI y le presta tres cosas que únicamente tiene el
/// controlador: lo compartido, cerrar y abrir la app.
@objc(ActionViewController)
final class ActionViewController: UIViewController {

    private let modelo = ModeloDeEnvio()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        modelo.cerrar = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        modelo.abrirApp = { [weak self] url in
            self?.abrirEnLaApp(url)
        }
        let hoja = UIHostingController(rootView: HojaDeEnvio(modelo: modelo))
        hoja.view.backgroundColor = .clear
        addChild(hoja)
        hoja.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hoja.view)
        NSLayoutConstraint.activate([
            hoja.view.topAnchor.constraint(equalTo: view.topAnchor),
            hoja.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hoja.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hoja.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hoja.didMove(toParent: self)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { await modelo.cargar(items) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Hoja chica, no una pantalla entera. Si el anfitrión no la presenta como hoja,
        // esto no hace nada.
        if let s = sheetPresentationController ?? parent?.sheetPresentationController {
            s.detents = [.medium(), .large()]
            s.prefersGrabberVisible = true
        }
    }

    /// Abre la app contenedora.
    ///
    /// ⚠️ `extensionContext.open` sólo funciona en widgets: en una acción contesta `false`
    /// y no pasa nada. Lo que sí funciona es pedírselo a la `UIApplication` que está en la
    /// cadena de respondedores, y por selector, porque el SDK de extensiones marca `open`
    /// como no disponible. Es el mismo camino que usan las demás apps con esta entrada.
    private func abrirEnLaApp(_ url: URL) {
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        var r: UIResponder? = self
        while let actual = r {
            if actual.isKind(of: NSClassFromString("UIApplication")!), actual.responds(to: sel) {
                typealias Abrir = @convention(c) (AnyObject, Selector, NSURL, NSDictionary,
                                                  (@convention(block) (Bool) -> Void)?) -> Void
                let f = unsafeBitCast(actual.method(for: sel), to: Abrir.self)
                f(actual, sel, url as NSURL, NSDictionary(), nil)
                break
            }
            r = actual.next
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
