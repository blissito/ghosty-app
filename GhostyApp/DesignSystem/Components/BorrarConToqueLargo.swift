import SwiftUI

/// Mantener pulsado → «Borrar», con su confirmación.
///
/// ⚠️ **Toque largo y no deslizar**, y no por gusto: lo nativo para borrar una fila en iOS
/// es deslizar, pero `.swipeActions` sólo existe dentro de un `List`, y aquí las listas son
/// `VStack` dentro de `ghostyCard()`. Pasarlas a `List` para ganar el gesto rompería el
/// diseño de tarjetas de toda la app. Además hay una superficie donde deslizar no aplica
/// —la tarjeta de entrega dentro del chat—, y ahí el estándar ya es mantener pulsado.
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
            .confirmationDialog(titulo, isPresented: $preguntando, titleVisibility: .visible) {
                Button("Borrar", role: .destructive, action: alBorrar)
                Button("Cancelar", role: .cancel) {}
            } message: {
                if let consecuencia { Text(consecuencia) }
            }
    }
}

extension View {
    func borrarConToqueLargo(_ titulo: String,
                             consecuencia: String? = nil,
                             alBorrar: @escaping () -> Void) -> some View {
        modifier(BorrarConToqueLargo(titulo: titulo, consecuencia: consecuencia, alBorrar: alBorrar))
    }
}
