import SwiftUI

/// Los favicons apilados y «N fuentes», debajo de la respuesta. Tocarla abre la lista.
///
/// Es el mismo patrón que `PasosDelAgente`: UNA línea en el hilo y el detalle en una
/// hoja. Nueve fuentes puestas en el hilo empujan la respuesta fuera de la pantalla, que
/// es exactamente lo que ya pasó con la lista de herramientas.
struct BarraDeFuentes: View {
    let fuentes: [Fuente]
    @State private var hoja = false

    var body: some View {
        if !fuentes.isEmpty {
            Button { hoja = true } label: {
                HStack(spacing: 7) {
                    HStack(spacing: -7) {
                        ForEach(fuentes.prefix(3)) { f in
                            FaviconDeFuente(fuente: f, lado: 20)
                                .overlay(Circle().stroke(Color.gBg, lineWidth: 2))
                        }
                    }
                    Text(fuentes.count == 1 ? "1 fuente" : "\(fuentes.count) fuentes")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.gInk3)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("barra-de-fuentes")
            .sheet(isPresented: $hoja) {
                HojaDeFuentes(fuentes: fuentes)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.gBg)
            }
        }
    }
}

/// El icono del sitio, con el hueco de la inicial mientras carga o si no lo hay.
struct FaviconDeFuente: View {
    let fuente: Fuente
    var lado: CGFloat = 26

    var body: some View {
        // ⚠️ `AsyncImage` con `phase`, no la versión de dos ramas: un sitio sin
        // `/favicon.ico` devuelve una página de error y sin distinguir el fallo se
        // quedaba el spinner girando para siempre en la fila.
        AsyncImage(url: fuente.favicon) { fase in
            switch fase {
            case .success(let img): img.resizable().scaledToFill()
            default: hueco
            }
        }
        .frame(width: lado, height: lado)
        .clipShape(Circle())
    }

    private var hueco: some View {
        ZStack {
            Color.gFill
            Text(fuente.inicial)
                .font(.system(size: lado * 0.5, weight: .semibold))
                .foregroundStyle(Color.gInk3)
        }
    }
}

struct HojaDeFuentes: View {
    let fuentes: [Fuente]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var abrir

    var body: some View {
        NavigationStack {
            List {
                ForEach(fuentes) { f in
                    Button { abrir(f.url) } label: {
                        HStack(spacing: 11) {
                            FaviconDeFuente(fuente: f)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.titulo)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.gInk)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(f.dominio).gCaption()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.gBg)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.gBg)
            .navigationTitle("Fuentes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}
