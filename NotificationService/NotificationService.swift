import Intents
import UIKit
import UserNotifications

/// Convierte el aviso de «tu agente contestó» en un aviso de COMUNICACIÓN: el título es el
/// agente que habla y el icono es SU fantasma, como el remitente en un chat.
///
/// ⚠️ Con varios agentes, todos los avisos decían «Tu agente terminó» con el mismo icono y
/// no se sabía quién hablaba (bliss, 2026-09-28). gs ya manda el nombre como título; esto
/// añade la cara. Los avisos de error y de permiso NO se tocan: su título («Ghosty se
/// atoró», «… necesita permiso») es el mensaje, y el aviso de comunicación lo cambiaría
/// por el nombre a secas.
///
/// El tono de cada agente lo escribe la app en el App Group (`LiveAgentStore`): aquí no hay
/// red ni sesión, y el tono sale de la posición del agente en la lista de la app.
final class NotificationService: UNNotificationServiceExtension {
    private var deliver: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        deliver = contentHandler
        fallback = request.content
        let info = request.content.userInfo
        guard info["kind"] as? String == "reply",
              let agentId = info["agentId"] as? String else {
            contentHandler(request.content)
            return
        }
        let name = (info["agentName"] as? String) ?? request.content.title
        let image = Self.avatar(for: agentId).map { INImage(imageData: $0) }
        let sender = INPerson(personHandle: INPersonHandle(value: agentId, type: .unknown),
                              nameComponents: nil, displayName: name, image: image,
                              contactIdentifier: nil, customIdentifier: agentId)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
                                         content: request.content.body, speakableGroupName: nil,
                                         conversationIdentifier: request.content.threadIdentifier,
                                         serviceName: nil, sender: sender, attachments: nil)
        intent.setImage(image, forParameterNamed: \.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { [weak self] _ in
            let updated = (try? request.content.updating(from: intent)) ?? request.content
            self?.finish(with: updated)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let fallback { finish(with: fallback) }
    }

    private func finish(with content: UNNotificationContent) {
        deliver?(content)
        deliver = nil
    }

    /// El fantasma del tono del agente, redondo y sobre blanco, como `AgentAvatar` en la app.
    private static func avatar(for agentId: String) -> Data? {
        let tones = UserDefaults(suiteName: "group.com.fixtergeek.ghostyapp")?
            .dictionary(forKey: "agentTones") as? [String: String]
        let tone = tones?[agentId] ?? "lila"
        let size = CGSize(width: 180, height: 180)
        let renderer = UIGraphicsImageRenderer(size: size)
        if tone == "lila", let portrait = UIImage(named: "ghosty-avatar") {
            return renderer.pngData { _ in
                UIColor.white.setFill()
                UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
                portrait.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        guard let mascot = UIImage(named: "ghosty-\(tone)") else { return nil }
        return renderer.pngData { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            // Misma proporción que en la app: el fantasma ocupa 2/3 del alto, un poco abajo.
            let height = size.height * 0.66
            let width = height * 120 / 144
            mascot.draw(in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2 + size.height * 0.04,
                                   width: width, height: height))
        }
    }
}
