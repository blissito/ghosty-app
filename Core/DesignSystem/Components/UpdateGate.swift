import SwiftUI

/// Pantalla completa cuando la build ya no sirve (`AppConfig.mustUpdate`). Sin botón de
/// cerrar a propósito: si gs la pide, es porque esa build rompe algo que no se puede
/// parchar del lado del servidor.
struct UpdateRequiredView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("ghosty-lila")
                .resizable()
                .aspectRatio(120.0 / 144.0, contentMode: .fit)
                .frame(height: 96)
            Text("Hay una versión nueva de Ghosty")
                .gScreenTitle()
                .multilineTextAlignment(.center)
            Text("Esta versión ya no funciona. Actualiza para seguir con tus agentes; tus conversaciones te esperan.")
                .gBody()
                .foregroundStyle(Color.gInk2)
                .multilineTextAlignment(.center)
            Spacer()
            Button { openURL(AppConfig.storeURL) } label: {
                Text("Actualizar")
                    .gButtonLabel()
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.primaryGradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("actualizar")
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gBg.ignoresSafeArea())
    }
}

/// Aviso que se puede cerrar (`AppConfig.shouldSuggestUpdate`). Una vez cerrado no vuelve
/// hasta que gs suba `suggestBuild`: un cartel que reaparece en cada arranque se vuelve ruido.
struct UpdateSuggestionBanner: View {
    @Environment(\.openURL) private var openURL
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.gPrimary)
            Text("Hay una versión nueva de Ghosty")
                .gRowTitle()
            Spacer(minLength: 4)
            Button("Actualizar") { openURL(AppConfig.storeURL) }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.gPrimary)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.gInk3)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cerrar-aviso-version")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }
}
