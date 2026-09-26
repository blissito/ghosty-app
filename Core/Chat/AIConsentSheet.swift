import SwiftUI

/// Permiso para mandar lo que escribes a la IA de terceros que mueve al agente.
///
/// App Review 5.1.2(i): la app tiene que decir QUÉ se comparte y CON QUIÉN, y pedir permiso
/// explícito ANTES del primer envío. Sale al mandar el primer mensaje (no al abrir la app:
/// quien sólo mira conversaciones no comparte nada) y se revisa o retira en Ajustes.
struct AIConsentSheet: View {
    /// La bandera. Una sola llave para la hoja, el candado del envío y Ajustes.
    static let key = "ai.consentGiven"

    @AppStorage(AIConsentSheet.key) private var consentGiven = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Lo que se estaba mandando cuando salió la hoja; corre al aceptar.
    var onAccept: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image("ghosty-lila")
                    .resizable().scaledToFit()
                    .frame(width: 64, height: 64)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .accessibilityHidden(true)

                Text("Tu agente usa IA de terceros").gScreenTitle()

                Text("Para responderte, lo que le mandas a tu agente se envía al modelo de IA que lo mueve.")
                    .gBody()
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    fila("text.bubble", "Qué se envía",
                         "Tus mensajes, los archivos e imágenes que adjuntas, tus notas de voz y el historial de la conversación.")
                    fila("building.2", "A quién",
                         "Anthropic (Claude). Si configuras otro modelo en ghosty.studio: OpenAI, Google (Gemini) o DeepSeek.")
                    fila("lock", "Qué no",
                         "No enviamos tu nombre, correo ni identificadores del teléfono. Lo que mandas no se usa para entrenar modelos.")
                }

                Button {
                    openURL(URL(string: "https://www.ghosty.studio/privacidad")!)
                } label: {
                    HStack(spacing: 4) {
                        Text("Aviso de privacidad")
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    }
                    .gMeta()
                    .foregroundStyle(Color.gPrimary)
                }
                .buttonStyle(.plain)

                VStack(spacing: 10) {
                    ActionButton(title: consentGiven ? "Seguir permitiendo" : "Aceptar y continuar",
                                 kind: .primary) {
                        consentGiven = true
                        dismiss()
                        onAccept()
                    }
                    .accessibilityIdentifier("ai-consent-accept")

                    ActionButton(title: consentGiven ? "Retirar permiso" : "Ahora no",
                                 kind: consentGiven ? .destructive : .secondary) {
                        consentGiven = false
                        dismiss()
                    }
                    .accessibilityIdentifier("ai-consent-decline")
                }
                .padding(.top, 6)

                Text("Sin este permiso no se pueden mandar mensajes. Lo cambias cuando quieras en Tu cuenta → IA de terceros.")
                    .gCaption()
                    .foregroundStyle(Color.gInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .background(Color.gBg)
        .presentationDetents([.large])
    }

    private func fila(_ icono: String, _ titulo: String, _ texto: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            TintedIcon(systemName: icono, tint: .gPrimary, background: .gPrimaryTint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo).gRowTitle()
                Text(texto).gMeta().fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
