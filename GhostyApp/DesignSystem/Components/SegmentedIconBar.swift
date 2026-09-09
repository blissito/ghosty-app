import SwiftUI

/// El segmentado de la hoja del agente. Es propio y no `Picker(.segmented)` porque
/// aquél no deja controlar el tamaño ni el color de los iconos, y arrastra el
/// aspecto de UIKit.
struct SegmentedIconBar<T: Hashable & Identifiable>: View {
    let items: [T]
    let icon: (T) -> String
    @Binding var selection: T
    @Namespace private var resaltado

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items) { item in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selection = item
                    }
                } label: {
                    ZStack {
                        if selection == item {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.gCard)
                                .shadow(color: .black.opacity(0.09), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "seg", in: resaltado)
                        }
                        Image(systemName: icon(item))
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(selection == item ? Color.gInk : Color.gInk3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.gFillStrong)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
