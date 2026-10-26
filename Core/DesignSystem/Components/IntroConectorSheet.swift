import SwiftUI

/// Lo que se lee antes de ir a conectar: qué marcar del otro lado y por qué es seguro.
/// El texto entero lo manda gs (`intro` del conector).
struct IntroConectorSheet: View {
    let intro: IntroDeConector
    let continuar: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(intro.title).gScreenTitle()
                        .padding(.bottom, 4)
                    if !intro.subtitle.isEmpty {
                        Text(intro.subtitle).gScreenSubtitle()
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 18)
                    }
                    ForEach(Array(intro.items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.gInk)
                            Text(item.body)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.gInk3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.top, 24)
            }
            .scrollIndicators(.hidden)
            VStack(spacing: 6) {
                Button(action: continuar) {
                    Text(intro.continueLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.gDark, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.gPressPill)
                .accessibilityIdentifier("intro-continuar")
                Button(intro.cancelLabel) { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gInk3)
                    .frame(height: 40)
                    .accessibilityIdentifier("intro-cancelar")
            }
            .padding(.horizontal, Theme.Space.screenH)
            .padding(.bottom, 12)
        }
        .presentationDetents([.large])
        .presentationBackground(Color.gBg)
    }
}
