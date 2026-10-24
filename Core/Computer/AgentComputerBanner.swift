import SwiftUI

/// Encima del compositor, mientras el agente usa su navegador en ESTA conversación: «Te necesito
/// aquí» con «Tomar el control» al frente si pidió ayuda; si sólo navega, un renglón discreto para
/// mirarlo en vivo. La pantalla la abre `RootView` (`AgentComputerStore.presenting`).
struct AgentComputerBanner: View {
    let live: BrowserLive

    var body: some View {
        if let ask = live.needsHuman {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.gPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Te necesito aquí")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                    Text(ask)
                        .gMeta().foregroundStyle(Color.gInk2)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Tomar el control") { AgentComputerStore.shared.open(live, mode: .takeover) }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.gPrimary, in: Capsule())
                    .accessibilityIdentifier("tomar-el-control")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.gPrimaryTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.gPrimaryLight, lineWidth: 1))
            .padding(.horizontal, 16).padding(.bottom, 6)
        } else {
            Button { AgentComputerStore.shared.open(live, mode: .watch) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "display")
                    Text(live.title.flatMap { $0.isEmpty ? nil : $0 } ?? host(live.url) ?? "Navegando")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Mirar en vivo").fontWeight(.semibold).foregroundStyle(Color.gPrimary)
                }
                .font(.system(size: 13))
                .foregroundStyle(Color.gInk2)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.gCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 6)
            .accessibilityIdentifier("mirar-en-vivo")
        }
    }

    private func host(_ s: String?) -> String? {
        s.flatMap(URL.init(string:))?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }
}
