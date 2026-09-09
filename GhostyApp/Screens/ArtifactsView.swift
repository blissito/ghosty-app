import SwiftUI

/// Lo que hay en el almacenamiento: documentos y archivos.
///
/// ⚠️ **Es de la cuenta, no del agente**, y la pantalla lo dice. El modelo `File` de
/// EasyBits no guarda `agentId`, y los artefactos que crea un agente se atribuyen al
/// DUEÑO —su MCP arma el contexto con `ctxForOwner`—, así que el agente desaparece
/// del registro. Filtrar por agente en el cliente sería inventar un dato que no existe.
struct ArtifactsView: View {
    let store: LiveAgentStore
    var onOpenSheet: () -> Void

    @State private var pestana = 0
    @Environment(\.openURL) private var abrir

    var body: some View {
        VStack(spacing: 0) {
            if let agente = store.selectedAgent {
                AgentHeader(agent: agente, onTap: onOpenSheet).padding(.top, 8)
            }

            segmentos.padding(.horizontal, Theme.Space.screenH).padding(.top, 16)

            ScrollView {
                contenido.padding(.top, 16)
            }
        }
        .task(id: store.selectedAgentID) { await store.cargarArchivos() }
    }

    private var segmentos: some View {
        HStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { i in
                let titulo = i == 0
                    ? "Documentos\(store.documentos.isEmpty ? "" : " \(store.documentos.count)")"
                    : "Archivos\(store.archivos.isEmpty ? "" : " \(store.archivos.count)")"
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pestana = i }
                } label: {
                    Text(titulo)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(pestana == i ? Color.gInk : Color.gInk3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if pestana == i {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.gCard)
                                    .shadow(color: .black.opacity(0.09), radius: 2, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(height: 42)
        .background(Color.gFillStrong)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var contenido: some View {
        switch store.estadoArchivos {
        case .sinPedir, .cargando:
            VStack(spacing: 12) { ProgressView(); Text("Buscando…").gMeta() }
                .frame(maxWidth: .infinity).padding(.top, 70)

        case .noPermitido:
            EmptyState(icon: "lock",
                       title: "Con este token no se puede",
                       detail: "El token de un agente sólo sirve para mandarle mensajes: el API contesta 401 al pedir archivos. Con la llave de la cuenta sí se ven.")
                .padding(.top, 60)

        case .fallo(let d):
            VStack(spacing: 14) {
                EmptyState(icon: "exclamationmark.triangle", title: "No pude traerlos", detail: d)
                Button("Reintentar") { Task { await store.cargarArchivos() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gPrimary)
            }
            .padding(.top, 50)

        case .listo:
            if pestana == 0 { lista(documentos: store.documentos) }
            else { lista(archivos: store.archivos) }
        }
    }

    @ViewBuilder
    private func lista(documentos: [EasyBitsClient.RemoteDocument]) -> some View {
        if documentos.isEmpty {
            EmptyState(icon: "doc.text", title: "Sin documentos",
                       detail: "Lo que el agente entregue como documento aparece aquí.")
                .padding(.top, 60)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(documentos.enumerated()), id: \.element.id) { i, d in
                    Button {
                        if let t = d.shareUrl ?? d.pdfUrl, let u = URL(string: t) { abrir(u) }
                    } label: {
                        fila(icono: "doc.text",
                             tono: (.gPrimary, .gPrimaryTint),
                             titulo: d.name?.isEmpty == false ? d.name! : "Sin título",
                             detalle: detalleDoc(d),
                             abrible: (d.shareUrl ?? d.pdfUrl) != nil)
                    }
                    .buttonStyle(.plain)
                    .ghostySeparator(inset: i == documentos.count - 1 ? .infinity : 51)
                }
            }
            .padding(.horizontal, Theme.Space.cardH)
            .ghostyCard()
            .padding(.horizontal, Theme.Space.screenH)
            nota
        }
    }

    @ViewBuilder
    private func lista(archivos: [EasyBitsClient.RemoteFile]) -> some View {
        if archivos.isEmpty {
            EmptyState(icon: "folder", title: "Sin archivos",
                       detail: "Lo que se suba o el agente guarde aparece aquí.")
                .padding(.top, 60)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(archivos.enumerated()), id: \.element.id) { i, f in
                    Button {
                        Task { if let u = await store.ligaDeArchivo(f.id) { abrir(u) } }
                    } label: {
                        fila(icono: icono(f.contentType),
                             tono: tono(f.contentType),
                             titulo: f.name ?? f.id,
                             detalle: detalleArchivo(f),
                             abrible: true)
                    }
                    .buttonStyle(.plain)
                    .ghostySeparator(inset: i == archivos.count - 1 ? .infinity : 51)
                }
            }
            .padding(.horizontal, Theme.Space.cardH)
            .ghostyCard()
            .padding(.horizontal, Theme.Space.screenH)
            nota
        }
    }

    private var nota: some View {
        Text("Es el almacenamiento de tu cuenta, no de este agente: EasyBits no guarda a qué agente pertenece cada archivo.")
            .gCaption()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.screenH + 4)
            .padding(.top, 14)
            .padding(.bottom, 8)
    }

    private func fila(icono: String, tono: (Color, Color), titulo: String,
                      detalle: String, abrible: Bool) -> some View {
        HStack(spacing: 13) {
            TintedIcon(systemName: icono, tint: tono.0, background: tono.1, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(titulo).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.gInk).lineLimit(1)
                Text(detalle).gCaption()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if abrible {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.gInk4)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Formato

    private func detalleDoc(_ d: EasyBitsClient.RemoteDocument) -> String {
        var partes: [String] = []
        if let p = d.pageCount { partes.append(p == 1 ? "1 página" : "\(p) páginas") }
        if let s = d.status { partes.append(s == "DRAFT" ? "borrador" : s.lowercased()) }
        if (d.shareUrl ?? d.pdfUrl) == nil { partes.append("sin publicar") }
        return partes.joined(separator: " · ")
    }

    private func detalleArchivo(_ f: EasyBitsClient.RemoteFile) -> String {
        var partes: [String] = []
        if let s = f.size { partes.append(pesar(s)) }
        if let t = f.contentType { partes.append(t.components(separatedBy: "/").last ?? t) }
        if f.access == "private" { partes.append("privado") }
        return partes.joined(separator: " · ")
    }

    private func pesar(_ b: Int) -> String {
        if b >= 1_048_576 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        if b >= 1024 { return "\(b / 1024) KB" }
        return "\(b) B"
    }

    private func icono(_ tipo: String?) -> String {
        guard let t = tipo else { return "doc" }
        if t.hasPrefix("image/") { return "photo" }
        if t.hasPrefix("video/") { return "film" }
        if t.hasPrefix("audio/") { return "waveform" }
        if t.contains("pdf") { return "doc.richtext" }
        if t.contains("zip") || t.contains("gzip") || t.contains("tar") { return "shippingbox" }
        if t.contains("json") || t.contains("javascript") { return "curlybraces" }
        return "doc"
    }

    private func tono(_ tipo: String?) -> (Color, Color) {
        guard let t = tipo else { return (.gInk2, .gFill) }
        if t.hasPrefix("image/") || t.hasPrefix("video/") { return (.gGreenInk, .gGreenTint) }
        if t.contains("pdf") { return (.gDangerInk, .gDangerTint) }
        return (.gInk2, .gFill)
    }
}

/// Estado vacío honesto. Las secciones que no existen se dicen, no se disfrazan.
struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.gInk4)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.gInk2)
            Text(detail).gMeta().multilineTextAlignment(.center)
        }
        .frame(maxWidth: 280)
        .frame(maxWidth: .infinity)
    }
}
