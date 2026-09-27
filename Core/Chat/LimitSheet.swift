import SwiftUI

/// Se llegó a un límite del plan (sesión de 5 h, semana, modelo top…). Hoja nativa a media
/// altura: qué pasó, cuándo vuelve y dónde ver el uso. La frase la redacta gs.
///
/// ⚠️ Sin «recarga» ni «mejora tu plan»: Apple (3.1.1) no deja ni insinuar una compra fuera de
/// la tienda. Aquí sólo se explica.
struct LimitSheet: View {
    let message: String
    var onShowUsage: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var shown = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Color.gBird, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .symbolEffect(.bounce, value: shown)
                .padding(.top, 8)
            Text("Llegaste a tu límite")
                .font(.gDisplay(20, .bold))
                .foregroundStyle(Color.gInk)
            Text(message)
                .gBody()
                .foregroundStyle(Color.gInk2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Tu mensaje sigue en el compositor para cuando vuelva.")
                .gCaption()
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ActionButton(title: "Ver mi uso", kind: .primary) {
                    dismiss()
                    onShowUsage()
                }
                .accessibilityIdentifier("limit-show-usage")
                ActionButton(title: "Entendido") { dismiss() }
                    .accessibilityIdentifier("limit-ok")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .onAppear { shown = true }
    }
}
