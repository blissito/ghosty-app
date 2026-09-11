import SwiftUI

/// Deslizar a la izquierda → «Borrar», con la misma confirmación que el toque largo.
///
/// Lo nativo para borrar una fila en iOS es deslizar, pero `.swipeActions` sólo existe
/// dentro de un `List` y aquí las listas son `VStack` en tarjetas. Así que el gesto es
/// propio: la fila se desplaza y detrás asoma el botón rojo. El toque largo se conserva
/// como segundo camino (VoiceOver, y quien ya se lo sabía).
///
/// ⚠️ Sólo se lleva el arrastre HORIZONTAL: `minimumDistance` y la comparación `|dx| >
/// |dy|` son lo que evita robarle el scroll a la lista. Sin eso, cada intento de bajar
/// abría una fila.
struct DeslizarParaBorrar: ViewModifier {
    let titulo: String
    let consecuencia: String?
    let alBorrar: () -> Void

    @State private var desplazamiento: CGFloat = 0
    @State private var abierta = false
    @State private var preguntando = false

    private let ancho: CGFloat = 88

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            // El botón vive DEBAJO y sólo existe con la fila abierta. Como overlay o
            // background del contenido desplazado, su frame accesible salía corrido y el
            // toque no le llegaba nunca: un ZStack de verdad no tiene ese problema.
            if abierta {
                Button { preguntando = true } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 16, weight: .semibold))
                        Text("Borrar").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: ancho)
                    .frame(maxHeight: .infinity)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("borrar-deslizado")
                // Con la fila abierta, tocar la fila la cierra en vez de abrir la conversación.
                Color.clear
                    .contentShape(Rectangle())
                    .padding(.trailing, ancho)
                    .onTapGesture { cerrar() }
            }
            content
                .contextMenu {
                    Button(role: .destructive) { preguntando = true } label: {
                        Label("Borrar", systemImage: "trash")
                    }
                }
                .offset(x: desplazamiento)
                .allowsHitTesting(!abierta)
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    let base: CGFloat = abierta ? -ancho : 0
                    desplazamiento = min(0, max(-ancho - 20, base + v.translation.width))
                }
                .onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    let quedaAbierta = (abierta ? -ancho : 0) + v.translation.width < -60
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        abierta = quedaAbierta
                        desplazamiento = quedaAbierta ? -ancho : 0
                    }
                }
        )
        .accessibilityAction(named: "Borrar") { preguntando = true }
        .confirmarBorrado(titulo, consecuencia: consecuencia, preguntando: $preguntando) {
            cerrar()
            alBorrar()
        }
        .onChange(of: preguntando) { _, abiertoDialogo in
            if !abiertoDialogo { cerrar() }
        }
    }

    private func cerrar() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            abierta = false
            desplazamiento = 0
        }
    }
}

/// La confirmación, compartida con el toque largo: borrar aquí siempre es irreversible.
struct ConfirmarBorrado: ViewModifier {
    let titulo: String
    let consecuencia: String?
    @Binding var preguntando: Bool
    let alBorrar: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(titulo, isPresented: $preguntando, titleVisibility: .visible) {
                Button("Borrar", role: .destructive, action: alBorrar)
                Button("Cancelar", role: .cancel) {}
            } message: {
                if let consecuencia { Text(consecuencia) }
            }
    }
}

extension View {
    func deslizarParaBorrar(_ titulo: String,
                            consecuencia: String? = nil,
                            alBorrar: @escaping () -> Void) -> some View {
        modifier(DeslizarParaBorrar(titulo: titulo, consecuencia: consecuencia, alBorrar: alBorrar))
    }

    func confirmarBorrado(_ titulo: String, consecuencia: String?,
                          preguntando: Binding<Bool>,
                          alBorrar: @escaping () -> Void) -> some View {
        modifier(ConfirmarBorrado(titulo: titulo, consecuencia: consecuencia,
                                  preguntando: preguntando, alBorrar: alBorrar))
    }
}
