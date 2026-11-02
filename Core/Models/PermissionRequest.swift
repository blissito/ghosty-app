import Foundation

/// Las tres respuestas posibles. El caso de en medio es el que evita la ceguera de
/// banner: sin él la gente aprueba todo con tal de avanzar.
enum PermissionDecision: String, Sendable {
    case allowOnce
    case allowForTask
    case deny
}

/// Un `session/request_permission` de ACP, ya traducido a lo que la pantalla necesita.
struct PermissionRequest: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case email, purchase, push, publish }

    let id: String
    var kind: Kind
    var agentName: String
    var question: String
    var detail: String
    var attachment: Attachment?
    /// El borrador que arma gs (`metadata.preview`): tipo, campos, cuerpo y verbo del botón.
    /// Sin él (ACP, servidores viejos) la tarjeta pinta la pregunta de siempre.
    var preview: ApprovalPreview? = nil
    /// ¿El agente ofrece «no me vuelvas a preguntar en esta plática»? gs no lo ofrece en pagos
    /// ni borrados.
    var allowsAlways: Bool = true

    struct Attachment: Equatable, Sendable {
        var filename: String
        var meta: String
    }
}

/// Una decisión ya tomada, para el historial de la hoja.
struct PermissionRecord: Identifiable, Equatable, Sendable {
    let id: String
    var icon: LogEntry.Icon
    var title: String
    var detail: String
    var outcome: String
}

/// El borrador normalizado de una aprobación (gs `approval-preview.ts`): la misma tarjeta en /c,
/// iOS y Android sin conocer cada herramienta. Todo opcional para no romper con servidores viejos.
struct ApprovalPreview: Equatable, Sendable {
    /// email | message | payment | purchase | publish | delete | schedule | calendar | database | generic
    var kind: String
    /// Encabezado: «Correo», «Link de pago», «Sitio»…
    var label: String
    /// Verbo del botón que aprueba: «Enviar», «Cobrar», «Publicar»…
    var verb: String
    var fields: [Field]
    /// El texto largo (cuerpo del correo, mensaje). La tarjeta lo recorta con «Ver todo».
    var body: String?

    struct Field: Equatable, Sendable, Hashable {
        var label: String
        var value: String
    }

    /// Desde el JSON de `metadata.preview`; nil si no viene o no trae lo mínimo.
    init?(json: Any?) {
        guard let d = json as? [String: Any],
              let label = d["label"] as? String, !label.isEmpty else { return nil }
        kind = d["kind"] as? String ?? "generic"
        self.label = label
        verb = (d["verb"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Aprobar"
        fields = (d["fields"] as? [[String: Any]] ?? []).compactMap { f in
            guard let l = f["label"] as? String, let v = f["value"] as? String, !v.isEmpty else { return nil }
            return Field(label: l, value: v)
        }
        body = (d["body"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    init(kind: String, label: String, verb: String, fields: [Field], body: String? = nil) {
        self.kind = kind; self.label = label; self.verb = verb; self.fields = fields; self.body = body
    }
}
