import SwiftUI

/// «Mis archivos»: elegir de la biblioteca de la cuenta sin volver a subir (como la Library
/// de ChatGPT). Tú eliges, así que el agente sólo ve lo que mandas; viaja por id (`fileId`).
struct MisArchivosSheet: View {
    let maximo: Int
    let alElegir: ([GhostyAPI.ArchivoDeSesion]) -> Void

    @Environment(\.dismiss) private var cerrar
    @State private var archivos: [GhostyAPI.ArchivoDeSesion] = []
    @State private var cargando = true
    @State private var busqueda = ""
    @State private var tipo: String?
    @State private var elegidos: [GhostyAPI.ArchivoDeSesion] = []

    /// El `kind` de `/api/v2/me/files` (nil = todo).
    private static let tipos: [(String?, String)] = [(nil, "Todo"), ("image", "Fotos"), ("video", "Videos"),
                                                     ("document", "Documentos"), ("audio", "Audio")]

    private var visibles: [GhostyAPI.ArchivoDeSesion] {
        let q = busqueda.trimmingCharacters(in: .whitespaces).lowercased()
        // Las notas de voz grabadas en el chat no son «archivos» (como WhatsApp).
        return archivos.filter { f in
            f.segundos == nil && (q.isEmpty || f.nombre.lowercased().contains(q))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.tipos, id: \.1) { t in
                            Button(t.1) { tipo = t.0 }
                                .font(.system(size: 14, weight: .medium))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(tipo == t.0 ? Color.gPrimaryTint : Color.gCard)
                                .foregroundStyle(tipo == t.0 ? Color.gPrimary : Color.gInk)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                Group {
                    if cargando && archivos.isEmpty {
                        ProgressView().frame(maxHeight: .infinity)
                    } else if visibles.isEmpty {
                        Text(busqueda.isEmpty ? "Aún no tienes archivos. Lo que subas o te entregue un agente se queda aquí."
                                              : "Nada con «\(busqueda)».")
                            .font(.system(size: 15)).foregroundStyle(Color.gInk3)
                            .multilineTextAlignment(.center).padding(32)
                            .frame(maxHeight: .infinity)
                    } else {
                        List(visibles, id: \.id) { f in fila(f) }
                            .listStyle(.plain)
                    }
                }
            }
            .searchable(text: $busqueda, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar por nombre")
            .navigationTitle("Mis archivos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { cerrar() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(elegidos.isEmpty ? "Adjuntar" : "Adjuntar \(elegidos.count)") { alElegir(elegidos) }
                        .disabled(elegidos.isEmpty)
                        .accessibilityIdentifier("mis-archivos-adjuntar")
                }
            }
            .task(id: tipo) { await cargar() }
        }
    }

    private func fila(_ f: GhostyAPI.ArchivoDeSesion) -> some View {
        let elegido = elegidos.contains { $0.id == f.id }
        let puede = elegido || elegidos.count < maximo
        return Button {
            if elegido { elegidos.removeAll { $0.id == f.id } } else if puede { elegidos.append(f) }
        } label: {
            HStack(spacing: 12) {
                miniatura(f)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.nombre).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.gInk)
                        .lineLimit(1).truncationMode(.middle)
                    Text(detalle(f)).font(.system(size: 13)).foregroundStyle(Color.gInk3).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: elegido ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(elegido ? Color.gPrimary : Color.gInk3.opacity(puede ? 1 : 0.4))
                    .accessibilityLabel(elegido ? "Quitar \(f.nombre)" : "Elegir \(f.nombre)")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mis-archivos-\(f.id)")
    }

    private func miniatura(_ f: GhostyAPI.ArchivoDeSesion) -> some View {
        MiniaturaDeBiblioteca(archivo: f)
    }

    private func detalle(_ f: GhostyAPI.ArchivoDeSesion) -> String {
        var partes = [f.origen == "agente" ? "Generado" : "Subido"]
        if f.bytes > 0 { partes.append(ByteCountFormatter.string(fromByteCount: Int64(f.bytes), countStyle: .file)) }
        if let c = f.creado { partes.append(c.formatted(.dateTime.day().month(.abbreviated))) }
        return partes.joined(separator: " · ")
    }

    private func cargar() async {
        cargando = true
        if archivos.isEmpty, let ya = GhostyAPI.accountFilesGuardados(kind: tipo) { archivos = ya }
        if let nuevos = await GhostyAPI.accountFiles(kind: tipo) { archivos = nuevos }
        cargando = false
    }
}

/// Miniatura de una fila: la foto (con la caché de siempre) o la sigla del tipo.
private struct MiniaturaDeBiblioteca: View {
    let archivo: GhostyAPI.ArchivoDeSesion
    @State private var imagen: UIImage?

    var body: some View {
        let forma = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            if let imagen {
                Image(uiImage: imagen).resizable().scaledToFill()
            } else {
                let ext = (archivo.nombre as NSString).pathExtension.uppercased()
                forma.fill(Color.gPrimaryTint)
                    .overlay {
                        Text(ext.isEmpty ? "ARCH" : String(ext.prefix(4)))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.gPrimary)
                    }
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(forma)
        .task(id: archivo.id) {
            guard archivo.mime.hasPrefix("image/") else { return }
            imagen = await CacheDeImagenes.imagen(Adjunto(deBiblioteca: archivo))
        }
    }
}
