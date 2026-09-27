import SwiftUI
import UniformTypeIdentifiers

/// La tarjeta de tabla del diseño: encabezado en mayúsculas sobre `#F7F7FA`, filas con
/// línea fina y, abajo, «Exportar a Excel» y «Copiar».
///
/// Sale de dos sitios: una tabla de markdown en la respuesta (`Theme.ghosty.table`) y una
/// entrega CSV (`EntregaCard`). Los dos tienen los datos en la mano, así que el Excel se
/// arma EN EL TELÉFONO (`HojaXLSX`) y se comparte con la hoja del sistema: no hay que
/// pedirle al agente otro archivo.
struct TablaCard: View {
    let filas: [[String]]
    /// El nombre del archivo que se comparte (sin extensión).
    var nombre = "Tabla"
    /// Un rótulo arriba de todo (el nombre de la entrega). `nil` = sin rótulo.
    var titulo: String?

    @Environment(Toaster.self) private var toaster: Toaster?
    @State private var todas = false

    /// Más de esto se pliega: el Excel y el copiar llevan TODAS igual.
    private static let visibles = 10

    private var encabezado: [String] { filas.first ?? [] }
    private var cuerpo: [[String]] { Array(filas.dropFirst()) }
    private var columnas: Int { filas.map(\.count).max() ?? 0 }
    private var aLoAncho: Bool { columnas <= 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let titulo {
                HStack(spacing: 8) {
                    ChatIcons.tabla.dibujo(Color.gGreen, size: 16, ancho: 1.7)
                    Text(titulo)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.gHairline).frame(height: 1) }
            }

            if aLoAncho {
                rejilla
            } else {
                ScrollView(.horizontal, showsIndicators: false) { rejilla }
            }

            if cuerpo.count > Self.visibles {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { todas.toggle() }
                } label: {
                    Text(todas ? "Ver menos" : "Ver las \(cuerpo.count) filas")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Rectangle().fill(Color.gHairline).frame(height: 1) }
            }

            acciones
        }
        .ghostyCard(radius: Theme.Radius.threadCard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabla")
    }

    // MARK: - La rejilla

    private var rejilla: some View {
        VStack(alignment: .leading, spacing: 0) {
            fila(encabezado, cabeza: true)
                .background(Color.gCardSunken)
            ForEach(Array((todas ? cuerpo : Array(cuerpo.prefix(Self.visibles))).enumerated()),
                    id: \.offset) { _, f in
                fila(f, cabeza: false)
                    .overlay(alignment: .top) { Rectangle().fill(Color.gHairline).frame(height: 1) }
            }
        }
    }

    /// Anchos del prototipo (`1.4fr 1fr .9fr`) cuando caben; si no, columnas fijas y
    /// scroll de lado —una tabla de seis columnas apretada a 330 pt no se lee—.
    private func peso(_ i: Int) -> CGFloat {
        guard aLoAncho else { return 1 }
        switch (columnas, i) {
        case (3, 0): return 1.4
        case (3, 2): return 0.9
        case (2, 0): return 1.3
        default: return 1
        }
    }

    @ViewBuilder
    private func fila(_ celdas: [String], cabeza: Bool) -> some View {
        let contenido = ForEach(0..<columnas, id: \.self) { i in
            celda(i < celdas.count ? celdas[i] : "", columna: i, cabeza: cabeza)
        }
        Group {
            if aLoAncho {
                FilaPonderada(pesos: (0..<columnas).map(peso), espacio: 10) { contenido }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(0..<columnas, id: \.self) { i in
                        celda(i < celdas.count ? celdas[i] : "", columna: i, cabeza: cabeza)
                            .frame(width: i == 0 ? 132 : 108, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, cabeza ? 9 : 10)
    }

    @ViewBuilder
    private func celda(_ texto: String, columna: Int, cabeza: Bool) -> some View {
        if cabeza {
            Text(texto.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.44)
                .foregroundStyle(Color.gInk3)
                .lineLimit(2)
        } else {
            Text(texto)
                .font(.system(size: 13, weight: columna == 0 ? .semibold : .regular).monospacedDigit())
                // La última columna, más suave: es la de «detalle» (entrega, notas).
                .foregroundStyle(columna == columnas - 1 && columnas > 2 ? Color.gInk2 : Color.gInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Acciones

    private var acciones: some View {
        HStack(spacing: 8) {
            ShareLink(item: HojaExportable(filas: filas, nombre: nombre),
                      preview: SharePreview("\(nombre).xlsx")) {
                Text("Exportar a Excel")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.gPrimary)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Color.gPrimaryTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.gPressPill)
            .accessibilityIdentifier("exportar-excel")

            Button {
                UIPasteboard.general.string = HojaXLSX.tsv(filas)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                toaster?.show("Tabla copiada")
            } label: {
                Text("Copiar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.gInk)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Color.gFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.gPressPill)
            .accessibilityIdentifier("copiar-tabla")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Color.gHairline).frame(height: 1) }
    }
}

/// Columnas a fracciones del ancho, como `grid-template-columns: 1.4fr 1fr .9fr`.
private struct FilaPonderada: Layout {
    let pesos: [CGFloat]
    let espacio: CGFloat

    private func anchos(_ total: CGFloat, _ n: Int) -> [CGFloat] {
        let p = (0..<n).map { $0 < pesos.count ? pesos[$0] : 1 }
        let suma = max(p.reduce(0, +), 0.001)
        let libre = max(0, total - espacio * CGFloat(max(0, n - 1)))
        return p.map { libre * $0 / suma }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 320
        let w = anchos(total, subviews.count)
        let alto = subviews.indices.map {
            subviews[$0].sizeThatFits(ProposedViewSize(width: w[$0], height: nil)).height
        }.max() ?? 0
        return CGSize(width: total, height: alto)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = anchos(bounds.width, subviews.count)
        var x = bounds.minX
        for (i, s) in subviews.enumerated() {
            s.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: w[i], height: nil))
            x += w[i] + espacio
        }
    }
}

// MARK: - De dónde salen las filas

enum Tabular {
    /// Una tabla GFM (`| a | b |`) a filas. Salta la línea de `---` y limpia el markdown
    /// en línea de cada celda (negritas, código, enlaces): en la tarjeta y en el Excel
    /// lo que importa es el texto.
    static func deMarkdown(_ md: String) -> [[String]] {
        var filas: [[String]] = []
        for linea in md.components(separatedBy: .newlines) {
            var l = linea.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("|") || l.contains("|") else { continue }
            if l.hasPrefix("|") { l.removeFirst() }
            if l.hasSuffix("|") && !l.hasSuffix("\\|") { l.removeLast() }
            let celdas = partir(l).map { limpiar($0.trimmingCharacters(in: .whitespaces)) }
            // La línea de alineación: sólo guiones, dos puntos y espacios.
            if celdas.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { continue }
            filas.append(celdas)
        }
        return filas
    }

    /// Parte por `|` respetando `\|`.
    private static func partir(_ l: String) -> [String] {
        var celdas: [String] = []
        var actual = ""
        var escapado = false
        for c in l {
            if escapado { actual.append(c); escapado = false; continue }
            if c == "\\" { escapado = true; continue }
            if c == "|" { celdas.append(actual); actual = ""; continue }
            actual.append(c)
        }
        celdas.append(actual)
        return celdas
    }

    static func limpiar(_ s: String) -> String {
        var t = s
        // [texto](url) → texto
        while let a = t.range(of: "["), let m = t.range(of: "](", range: a.upperBound..<t.endIndex),
              let c = t.range(of: ")", range: m.upperBound..<t.endIndex) {
            t.replaceSubrange(a.lowerBound..<c.upperBound, with: t[a.upperBound..<m.lowerBound])
        }
        for marca in ["**", "__", "`", "~~"] { t = t.replacingOccurrences(of: marca, with: "") }
        return t.replacingOccurrences(of: "<br>", with: " ")
    }

    /// CSV (RFC 4180 a lo práctico): comillas dobles, `""` dentro, comas o `;`.
    static func deCSV(_ texto: String) -> [[String]] {
        let primera = texto.prefix { $0 != "\n" }
        let sep: Character = primera.filter { $0 == ";" }.count > primera.filter { $0 == "," }.count ? ";" : ","
        var filas: [[String]] = []
        var fila: [String] = []
        var campo = ""
        var entreComillas = false
        var i = texto.startIndex
        while i < texto.endIndex {
            let c = texto[i]
            if entreComillas {
                if c == "\"" {
                    let sig = texto.index(after: i)
                    if sig < texto.endIndex, texto[sig] == "\"" { campo.append("\""); i = sig }
                    else { entreComillas = false }
                } else { campo.append(c) }
            } else if c == "\"" {
                entreComillas = true
            } else if c == sep {
                fila.append(campo); campo = ""
            } else if c == "\n" || c == "\r\n" {
                fila.append(campo); campo = ""
                if !(fila.count == 1 && fila[0].isEmpty) { filas.append(fila) }
                fila = []
            } else if c != "\r" {
                campo.append(c)
            }
            i = texto.index(after: i)
        }
        if !campo.isEmpty || !fila.isEmpty { fila.append(campo); filas.append(fila) }
        return filas
    }
}

// MARK: - Excel

/// La tabla como `.xlsx`, generada al compartir (no al pintar).
struct HojaExportable: Transferable {
    let filas: [[String]]
    let nombre: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data) { h in
            SentTransferredFile(try HojaXLSX.escribir(h.filas, nombre: h.nombre))
        }
    }
}

/// Un `.xlsx` mínimo y de verdad: el paquete OOXML (cinco XML) en un ZIP sin comprimir.
///
/// ⚠️ Sin dependencias a propósito: el ZIP «stored» es un formato de treinta líneas y
/// Excel, Numbers y Google Sheets lo abren igual que uno comprimido. Los números puros
/// van como número (se pueden sumar); todo lo demás —«$1,240», «2 días»— como texto, tal
/// cual se ve en la tarjeta.
enum HojaXLSX {
    static func tsv(_ filas: [[String]]) -> String {
        filas.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }
            .joined(separator: "\n")
    }

    static func escribir(_ filas: [[String]], nombre: String) throws -> URL {
        let limpio = nombre.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(limpio).xlsx")
        try datos(filas).write(to: url, options: .atomic)
        return url
    }

    static func datos(_ filas: [[String]]) -> Data {
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
        let cabecera = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

        let tipos = cabecera + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>"#
        let raiz = cabecera + #"<Relationships xmlns="\#(pkg)"><Relationship Id="rId1" Type="\#(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>"#
        let libro = cabecera + #"<workbook xmlns="\#(ns)" xmlns:r="\#(rel)"><sheets><sheet name="Hoja1" sheetId="1" r:id="rId1"/></sheets></workbook>"#
        let libroRels = cabecera + #"<Relationships xmlns="\#(pkg)"><Relationship Id="rId1" Type="\#(rel)/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="\#(rel)/styles" Target="styles.xml"/></Relationships>"#
        // Estilo 1 = negrita, para el encabezado.
        let estilos = cabecera + #"<styleSheet xmlns="\#(ns)"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#

        var hoja = cabecera + #"<worksheet xmlns="\#(ns)"><sheetData>"#
        for (r, fila) in filas.enumerated() {
            hoja += #"<row r="\#(r + 1)">"#
            for (c, valor) in fila.enumerated() {
                let ref = "\(columna(c))\(r + 1)"
                let estilo = r == 0 ? #" s="1""# : ""
                if r > 0, let n = numero(valor) {
                    hoja += #"<c r="\#(ref)"\#(estilo)><v>\#(n)</v></c>"#
                } else {
                    hoja += #"<c r="\#(ref)" t="inlineStr"\#(estilo)><is><t xml:space="preserve">\#(escapar(valor))</t></is></c>"#
                }
            }
            hoja += "</row>"
        }
        hoja += "</sheetData></worksheet>"

        return ZipSinComprimir.armar([
            ("[Content_Types].xml", tipos),
            ("_rels/.rels", raiz),
            ("xl/workbook.xml", libro),
            ("xl/_rels/workbook.xml.rels", libroRels),
            ("xl/styles.xml", estilos),
            ("xl/worksheets/sheet1.xml", hoja),
        ].map { ($0.0, Data($0.1.utf8)) })
    }

    /// A, B, … Z, AA, AB…
    static func columna(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(65 + r)!) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// Sólo un número PURO («1240», «-3.5», «1,240.50»). Con moneda o unidades se queda
    /// como texto: convertirlo perdería lo que dice.
    static func numero(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.range(of: #"^-?\d{1,3}(,\d{3})*(\.\d+)?$|^-?\d+(\.\d+)?$"#,
                                  options: .regularExpression) != nil else { return nil }
        let sinComas = t.replacingOccurrences(of: ",", with: "")
        return Double(sinComas) != nil ? sinComas : nil
    }

    private static func escapar(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// ZIP con las entradas guardadas tal cual (método 0). Suficiente para un `.xlsx`.
enum ZipSinComprimir {
    static func armar(_ entradas: [(String, Data)]) -> Data {
        var zip = Data()
        var central = Data()
        for (nombre, datos) in entradas {
            let n = Data(nombre.utf8)
            let crc = crc32(datos)
            let desplazamiento = UInt32(zip.count)
            // Cabecera local.
            zip.u32(0x04034b50); zip.u16(20); zip.u16(0x0800); zip.u16(0)
            zip.u16(0); zip.u16(0x21)                       // 1980-01-01 00:00
            zip.u32(crc); zip.u32(UInt32(datos.count)); zip.u32(UInt32(datos.count))
            zip.u16(UInt16(n.count)); zip.u16(0)
            zip.append(n); zip.append(datos)
            // Su entrada en el directorio central.
            central.u32(0x02014b50); central.u16(20); central.u16(20); central.u16(0x0800); central.u16(0)
            central.u16(0); central.u16(0x21)
            central.u32(crc); central.u32(UInt32(datos.count)); central.u32(UInt32(datos.count))
            central.u16(UInt16(n.count)); central.u16(0); central.u16(0)
            central.u16(0); central.u16(0); central.u32(0)
            central.u32(desplazamiento)
            central.append(n)
        }
        let inicioCentral = UInt32(zip.count)
        zip.append(central)
        zip.u32(0x06054b50); zip.u16(0); zip.u16(0)
        zip.u16(UInt16(entradas.count)); zip.u16(UInt16(entradas.count))
        zip.u32(UInt32(central.count)); zip.u32(inicioCentral); zip.u16(0)
        return zip
    }

    private static let tabla: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = tabla[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
