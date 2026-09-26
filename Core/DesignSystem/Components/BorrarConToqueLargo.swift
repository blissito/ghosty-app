import SwiftUI

/// Mantener pulsado → «Borrar», con su confirmación.
///
/// Para las filas de conversaciones está `DeslizarParaBorrar`, que es lo nativo y además
/// conserva este toque largo. Esto se queda solo donde deslizar no aplica —la tarjeta de
/// entrega dentro del chat—, que ahí el estándar es mantener pulsado.
///
/// ⚠️ La confirmación NO es opcional: los tres borrados de esta app son irreversibles y uno
/// de ellos —el archivo de la cuenta— además deja cojas las conversaciones que lo nombran.
struct BorrarConToqueLargo: ViewModifier {
    let titulo: String
    /// Lo que de verdad va a pasar, dicho antes de que pase.
    let consecuencia: String?
    let alBorrar: () -> Void

    @State private var preguntando = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(role: .destructive) { preguntando = true } label: {
                    Label("Borrar", systemImage: "trash")
                }
            }
            .confirmarBorrado(titulo, consecuencia: consecuencia, preguntando: $preguntando,
                              alBorrar: alBorrar)
    }
}

extension View {
    func borrarConToqueLargo(_ titulo: String,
                             consecuencia: String? = nil,
                             alBorrar: @escaping () -> Void) -> some View {
        modifier(BorrarConToqueLargo(titulo: titulo, consecuencia: consecuencia, alBorrar: alBorrar))
    }
}
