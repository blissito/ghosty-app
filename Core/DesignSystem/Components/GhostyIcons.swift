import SwiftUI

/// Los iconos de trazo del diseño (los `<path d=…>` del prototipo), dibujados a mano en
/// su propio `viewBox` y escalados al marco. Se pintan con `.stroke`, como en el SVG:
/// `stroke-width` 1.8, puntas y uniones redondas.
struct GhostyStrokeIcon: Shape {
    /// El lado del `viewBox` del SVG original (22, 20, 18, 10…).
    var viewBox: CGFloat
    var trazo: (inout Path) -> Void

    func path(in rect: CGRect) -> Path {
        var p = Path()
        trazo(&p)
        let s = min(rect.width, rect.height) / viewBox
        return p.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: s, y: s))
    }
}

/// El estilo de trazo del diseño a un grosor dado, en puntos del `viewBox`.
extension StrokeStyle {
    static func ghosty(_ ancho: CGFloat = 1.8) -> StrokeStyle {
        StrokeStyle(lineWidth: ancho, lineCap: .round, lineJoin: .round)
    }
}

private func arco(_ p: inout Path, centro: CGPoint, r: CGFloat, de a: Double, a b: Double, horario: Bool) {
    // `clockwise` de SwiftUI va en coordenadas de pantalla (y hacia abajo): se invierte.
    p.addArc(center: centro, radius: r, startAngle: .degrees(a), endAngle: .degrees(b), clockwise: !horario)
}

enum GhostyIcons {
    /// Chat: `M4 6.5A2.5 2.5 0 016.5 4h9A2.5 2.5 0 0118 6.5v6a2.5 2.5 0 01-2.5 2.5H10l-4 3v-3h0A2 2 0 014 13z`
    static let chat = GhostyStrokeIcon(viewBox: 22) { p in
        p.move(to: CGPoint(x: 4, y: 6.5))
        arco(&p, centro: CGPoint(x: 6.5, y: 6.5), r: 2.5, de: 180, a: 270, horario: true)
        p.addLine(to: CGPoint(x: 15.5, y: 4))
        arco(&p, centro: CGPoint(x: 15.5, y: 6.5), r: 2.5, de: 270, a: 360, horario: true)
        p.addLine(to: CGPoint(x: 18, y: 12.5))
        arco(&p, centro: CGPoint(x: 15.5, y: 12.5), r: 2.5, de: 0, a: 90, horario: true)
        p.addLine(to: CGPoint(x: 10, y: 15))
        p.addLine(to: CGPoint(x: 6, y: 18))
        p.addLine(to: CGPoint(x: 6, y: 15))
        arco(&p, centro: CGPoint(x: 6, y: 13), r: 2, de: 90, a: 180, horario: true)
        p.closeSubpath()
    }

    /// Archivos: `M6 3.5h6.5L17 8v10.5H6zM12.5 3.5V8H17`
    static let archivos = GhostyStrokeIcon(viewBox: 22) { p in
        p.move(to: CGPoint(x: 6, y: 3.5))
        p.addLine(to: CGPoint(x: 12.5, y: 3.5))
        p.addLine(to: CGPoint(x: 17, y: 8))
        p.addLine(to: CGPoint(x: 17, y: 18.5))
        p.addLine(to: CGPoint(x: 6, y: 18.5))
        p.closeSubpath()
        p.move(to: CGPoint(x: 12.5, y: 3.5))
        p.addLine(to: CGPoint(x: 12.5, y: 8))
        p.addLine(to: CGPoint(x: 17, y: 8))
    }

    /// Integraciones (un enchufe): `M8 4v3M14 4v3M6 7h10v4a5 5 0 01-10 0zM11 16v3`
    static let integraciones = GhostyStrokeIcon(viewBox: 22) { p in
        p.move(to: CGPoint(x: 8, y: 4)); p.addLine(to: CGPoint(x: 8, y: 7))
        p.move(to: CGPoint(x: 14, y: 4)); p.addLine(to: CGPoint(x: 14, y: 7))
        p.move(to: CGPoint(x: 6, y: 7))
        p.addLine(to: CGPoint(x: 16, y: 7))
        p.addLine(to: CGPoint(x: 16, y: 11))
        arco(&p, centro: CGPoint(x: 11, y: 11), r: 5, de: 0, a: 180, horario: true)
        p.closeSubpath()
        p.move(to: CGPoint(x: 11, y: 16)); p.addLine(to: CGPoint(x: 11, y: 19))
    }

    /// Perfil: `M11 11a3.8 3.8 0 100-7.6 3.8 3.8 0 000 7.6zM4 18.5c.8-3.2 3.6-5 7-5s6.2 1.8 7 5`
    static let perfil = GhostyStrokeIcon(viewBox: 22) { p in
        p.addEllipse(in: CGRect(x: 11 - 3.8, y: 7.2 - 3.8, width: 7.6, height: 7.6))
        p.move(to: CGPoint(x: 4, y: 18.5))
        p.addCurve(to: CGPoint(x: 11, y: 13.5), control1: CGPoint(x: 4.8, y: 15.3), control2: CGPoint(x: 7.6, y: 13.5))
        p.addCurve(to: CGPoint(x: 18, y: 18.5), control1: CGPoint(x: 14.4, y: 13.5), control2: CGPoint(x: 17.2, y: 15.3))
    }

    /// Historial (tres renglones, el último corto): `M3 6h14M3 10h14M3 14h9`, viewBox 20.
    static let historial = GhostyStrokeIcon(viewBox: 20) { p in
        p.move(to: CGPoint(x: 3, y: 6)); p.addLine(to: CGPoint(x: 17, y: 6))
        p.move(to: CGPoint(x: 3, y: 10)); p.addLine(to: CGPoint(x: 17, y: 10))
        p.move(to: CGPoint(x: 3, y: 14)); p.addLine(to: CGPoint(x: 12, y: 14))
    }

    /// Chevron hacia abajo de la píldora del agente: `M2 3.5l3 3 3-3`, viewBox 10.
    static let chevronAbajo = GhostyStrokeIcon(viewBox: 10) { p in
        p.move(to: CGPoint(x: 2, y: 3.5))
        p.addLine(to: CGPoint(x: 5, y: 6.5))
        p.addLine(to: CGPoint(x: 8, y: 3.5))
    }
}

/// La palomita del seleccionado: `M4 9.5l3.2 3L14 5.5`, viewBox 18.
struct CheckIcon: Shape {
    func path(in rect: CGRect) -> Path {
        GhostyStrokeIcon(viewBox: 18) { p in
            p.move(to: CGPoint(x: 4, y: 9.5))
            p.addLine(to: CGPoint(x: 7.2, y: 12.5))
            p.addLine(to: CGPoint(x: 14, y: 5.5))
        }.path(in: rect)
    }
}

extension GhostyStrokeIcon {
    /// El icono pintado como en el prototipo: trazo escalado al tamaño pedido.
    func dibujo(_ color: Color, size: CGFloat, ancho: CGFloat = 1.8) -> some View {
        // El grosor se da en puntos del viewBox, así que se escala igual que el trazo.
        stroke(color, style: .ghosty(ancho * size / viewBox))
            .frame(width: size, height: size)
    }
}
