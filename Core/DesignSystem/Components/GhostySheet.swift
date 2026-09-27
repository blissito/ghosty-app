import SwiftUI

/// La hoja del diseño: tarjeta flotante a 8 pt de los bordes, radio 34, agarradera,
/// título, y un velo que cierra al tocarlo. No es `.sheet`: la del sistema no deja
/// despegar la tarjeta de los bordes ni poner el velo del diseño.
///
/// Entra Y sale animada: el `if` vive dentro de un contenedor que está siempre, así
/// que SwiftUI puede correr la transición de salida (con `.sheet` casera montada sólo
/// cuando está abierta, la salida se cortaba de golpe).
struct GhostySheetContainer<Contenido: View>: View {
    @Binding var isPresented: Bool
    var title: String?
    var identifier: String?
    @ViewBuilder var contenido: () -> Contenido

    @State private var arrastre: CGFloat = 0
    @State private var altoContenido: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                if isPresented {
                    // `rgba(21,20,27,.3)`
                    Color(hex: 0x15141B, opacity: 0.3)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { cerrar() }
                        .accessibilityElement()
                        .accessibilityLabel("Cerrar")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("velo-hoja")
                        .transition(.opacity)

                    tarjeta(maxAlto: (geo.size.height + geo.safeAreaInsets.top) * 0.82)
                        .offset(y: max(0, arrastre))
                        .gesture(
                            DragGesture()
                                .onChanged { arrastre = $0.translation.height }
                                .onEnded { g in
                                    if g.translation.height > 90 || g.predictedEndTranslation.height > 220 {
                                        cerrar()
                                    }
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { arrastre = 0 }
                                }
                        )
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)))
                        .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isPresented)
        // Cerrada no toca nada: los toques pasan a la pantalla de abajo.
        .allowsHitTesting(isPresented)
    }

    private func tarjeta(maxAlto: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color.gFillStrong)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)
            if let title {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.gInk)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 12)
                    .accessibilityAddTraits(.isHeader)
            }
            // Si no cabe, se desplaza; si cabe, la hoja mide lo que su contenido.
            ScrollView {
                contenido()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { altoContenido = $0 }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(altoContenido, max(120, maxAlto - 90)))
        }
        .padding(.top, 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gCard, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier ?? "hoja")
    }

    private func cerrar() { isPresented = false }
}

extension View {
    /// Monta una `GhostySheet` encima de esta vista. Se pone en la raíz para que el velo
    /// tape también la barra de pestañas.
    func ghostySheet<C: View>(isPresented: Binding<Bool>, title: String? = nil,
                              identifier: String? = nil,
                              @ViewBuilder content: @escaping () -> C) -> some View {
        overlay {
            GhostySheetContainer(isPresented: isPresented, title: title,
                                 identifier: identifier, contenido: content)
        }
    }
}

/// Fila de hoja del diseño: icono o imagen de 36–40, título 600 15, subtítulo 13 y un
/// accesorio a la derecha. Radio 16; la seleccionada va sobre `gPrimaryWash`.
struct GhostySheetRow<Leading: View, Extra: View>: View {
    let title: String
    var subtitle: String?
    var selected = false
    let action: () -> Void
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.gInk3)
                            .lineLimit(1)
                    }
                    extra()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    CheckIcon()
                        .stroke(Color.gPrimary, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                        .frame(width: 18, height: 18)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(12)
            .background(selected ? Color.gPrimaryWash : Color.gCard,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.gPressRow)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension GhostySheetRow where Extra == EmptyView {
    init(title: String, subtitle: String? = nil, selected: Bool = false,
         action: @escaping () -> Void, @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title: title, subtitle: subtitle, selected: selected, action: action,
                  leading: leading, extra: { EmptyView() })
    }
}
