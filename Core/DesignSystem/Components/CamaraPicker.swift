import SwiftUI
import UIKit

/// La cámara del sistema, envuelta para SwiftUI.
///
/// No hay equivalente nativo en SwiftUI: `PhotosPicker` abre el carrete, no la cámara. Es
/// el envoltorio mínimo — una foto y se cierra.
struct CamaraPicker: UIViewControllerRepresentable {
    var alTomar: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        // ⚠️ En el simulador NO hay cámara: sin esta caída, el picker sale en negro y no
        // hay forma de salir más que matando la app. Y probar en el simulador es
        // exactamente lo que se hace aquí todo el día.
        c.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let padre: CamaraPicker
        init(_ padre: CamaraPicker) { self.padre = padre }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // JPEG al 0.85 y no PNG: una foto de 12 Mpx en PNG son ~20 MB y el tope de la
            // caja son 12. La diferencia no se ve y el turno sí.
            if let img = info[.originalImage] as? UIImage, let d = img.jpegData(compressionQuality: 0.85) {
                padre.alTomar(d)
            }
            padre.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            padre.dismiss()
        }
    }
}
