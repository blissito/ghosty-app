import UIKit

/// La conversación del prototipo, para poder MIRAR el chat en el simulador
/// (`GHOSTY_DEMO=1 GHOSTY_DEMO_CHAT=1`): pasos hechos, viñetas, una tabla de markdown y un
/// PDF entregado. Sólo se usa con el modo demo encendido.
enum DemoDelChat {
    static func mensajes() -> [Message] {
        func pasos(_ rotulos: [String]) -> ToolRun {
            ToolRun(herramientas: rotulos.enumerated().map { i, r in
                Herramienta(id: "demo-paso-\(r.hashValue)-\(i)", titulo: r, clase: .read,
                            estado: .hecha, salida: nil, donde: nil, detalle: nil)
            })
        }
        let pdf = Entrega(id: "demo-cotizacion", agentID: "demo-1", sesionID: nil, forma: .archivo,
                          titulo: "Cotizacion_0134.pdf", recibida: Date(), datos: cotizacion())
        return [
            Message(id: "dc-u1", kind: .user("Resume este PDF")),
            Message(id: "dc-a1", kind: .agent(
                text: "Listo. Lo importante del contrato:\n\n"
                    + "- Vigencia de 12 meses con renovación automática.\n"
                    + "- Pago a 30 días; penalización del 2% por atraso.\n"
                    + "- Cancelación con 60 días de aviso por escrito.",
                tools: pasos(["Leyendo Contrato_Proveedor.pdf · 12 págs", "Extrayendo cláusulas clave"]),
                trailing: nil)),
            Message(id: "dc-u2", kind: .user("Búscame precios y hazme una tabla")),
            Message(id: "dc-a2", kind: .agent(
                text: "Comparé cajas de cartón 40×30×30 cm, precio por 100 piezas:\n\n"
                    + "| Proveedor | Precio | Entrega |\n|---|---|---|\n"
                    + "| EmpaquesMX | $1,240 | 2 días |\n| CartoPack | $1,315 | 1 día |\n"
                    + "| Grupo Caja | $1,190 | 5 días |\n| Embalex | $1,402 | 3 días |",
                tools: pasos(["Buscando en la web", "Comparando 4 proveedores", "Armando la tabla"]),
                trailing: nil)),
            Message(id: "dc-u3", kind: .user("Arma una cotización en PDF")),
            Message(id: "dc-a3", kind: .agent(
                text: "Tu cotización está lista: 3 conceptos, total $18,420 MXN con IVA.",
                tools: pasos(["Leyendo tu catálogo", "Calculando totales con IVA", "Generando PDF"]),
                trailing: nil)),
            Message(id: "entrega-demo-cotizacion", kind: .entrega(pdf)),
        ]
    }

    /// Un PDF de dos páginas de verdad, para que la tarjeta tenga portada.
    private static func cotizacion() -> Data {
        let hoja = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: hoja).pdfData { ctx in
            for pagina in 1...2 {
                ctx.beginPage()
                UIColor(red: 0.36, green: 0.29, blue: 0.84, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 612, height: 110))
                ("Cotización #0134" as NSString).draw(at: CGPoint(x: 48, y: 38), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: UIColor.white])
                let lineas = pagina == 1
                    ? ["Cliente: Restaurante Mi Ranchito", "", "Cajas 40×30×30 · 100 pzas   $1,190",
                       "Etiquetas térmicas · 500     $2,880", "Cinta canela · 36 rollos    $12,410",
                       "", "Subtotal   $15,879", "IVA 16%    $2,541", "Total      $18,420 MXN"]
                    : ["Condiciones", "", "Precios válidos 15 días.", "Entrega en 2 a 5 días hábiles."]
                for (i, l) in lineas.enumerated() {
                    (l as NSString).draw(at: CGPoint(x: 48, y: CGFloat(150 + i * 30)), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.darkGray])
                }
            }
        }
    }
}
