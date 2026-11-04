import SwiftUI
import WebKit

/// Una página HTML entregada por el agente, viva: con su JavaScript y sus estilos de CDN.
///
/// ⚠️ Antes se abría con QuickLook, que pinta el HTML SIN JavaScript y sin recursos
/// remotos: una página con Tailwind por CDN o con su contenido armado en JS salía como
/// texto plano azul y negro, con secciones vacías («Barbería El Filo», 4-nov). En la web
/// se veía bien.
struct HTMLViewer: View {
    /// La copia en disco, o `nil` si se abre `live`.
    var file: URL?
    /// La página publicada: se carga ésa, con su backend. Ver `Delivery.liveURL`.
    var live: URL? = nil
    let title: String
    /// De dónde vino, para resolver rutas relativas (`styles.css`, `/assets/…`).
    var baseURL: URL?
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var state: LoadState = .loading
    /// Cambia para volver a cargar tras un fallo.
    @State private var attempt = 0

    enum LoadState: Equatable { case loading, ready, failed }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.gBg.ignoresSafeArea()
                HTMLWebView(file: file, live: live, baseURL: baseURL,
                            openExternal: { openURL($0) }, onState: { state = $0 })
                    .id(attempt)
                    .opacity(state == .failed ? 0 : 1)
                if state == .loading {
                    FlameLoading(text: "Abriendo la página…")
                        .accessibilityIdentifier("html-viewer-loading")
                }
                if state == .failed { failed }
            }
            // La página hasta el borde de abajo (sin franja de `gBg` bajo el indicador de inicio).
            .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { onClose() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Cerrar")
                            .accessibilityIdentifier("html-viewer-close")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if let compartible = live ?? file {
                            ShareLink(item: compartible) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                }
        }
        .accessibilityIdentifier("html-viewer")
    }

    /// Sin red o el sitio caído: se dice, y se ofrece Safari para la página publicada.
    private var failed: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(Color.gInk3)
            Text("No pude abrir la página")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.gInk)
            Button("Reintentar") { state = .loading; attempt += 1 }
                .buttonStyle(.borderedProminent)
                .tint(Color.gPrimary)
            if let live {
                Button("Abrir en Safari") { openURL(live) }
                    .foregroundStyle(Color.gPrimary)
            }
        }
        .padding(24)
        .accessibilityIdentifier("html-viewer-failed")
    }
}

private struct HTMLWebView: UIViewRepresentable {
    let file: URL?
    let live: URL?
    let baseURL: URL?
    let openExternal: (URL) -> Void
    let onState: (HTMLViewer.LoadState) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(openExternal: openExternal, onState: onState) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        // Sin el blanco de WebKit mientras carga: debajo está la flamita sobre `gBg`.
        web.isOpaque = false
        web.backgroundColor = .clear
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
        if let live {
            web.load(URLRequest(url: live))
        } else if let file, let html = try? String(contentsOf: file, encoding: .utf8) {
            // Con la URL de origen como base, lo relativo se resuelve contra el servidor;
            // sin ella, contra una https cualquiera para que el CDN y `fetch` funcionen.
            web.loadHTMLString(html, baseURL: baseURL ?? URL(string: "https://ghosty.studio/"))
        } else if let file {
            web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let openExternal: (URL) -> Void
        let onState: (HTMLViewer.LoadState) -> Void
        init(openExternal: @escaping (URL) -> Void, onState: @escaping (HTMLViewer.LoadState) -> Void) {
            self.openExternal = openExternal; self.onState = onState
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onState(.ready) }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            fail(error)
        }

        /// Un enlace que se va a Safari cancela la navegación con `NSURLErrorCancelled` (o
        /// WebKit 102): eso no es un fallo de la página.
        private func fail(_ error: Error) {
            let e = error as NSError
            if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
            onState(.failed)
        }

        /// Un enlace tocado que sale de la página va a Safari: el login con Google no deja
        /// entrar desde un WebView incrustado, y un `tel:`/`mailto:`/WhatsApp tiene su app.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            let scheme = url.scheme?.lowercased() ?? ""
            if !["http", "https", "about", "data", "blob", "file"].contains(scheme) {
                openExternal(url)
                return decisionHandler(.cancel)
            }
            // Dentro del mismo sitio se navega aquí; un enlace a OTRO sitio va fuera.
            if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true,
               url.host != webView.url?.host {
                openExternal(url)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        /// `target="_blank"` y `window.open`: a Safari también.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { openExternal(url) }
            return nil
        }
    }
}

/// Envoltura para `fullScreenCover(item:)`.
struct OpenHTML: Identifiable {
    var file: URL? = nil
    var live: URL? = nil
    var id: String { (live ?? file)?.absoluteString ?? "" }
}
