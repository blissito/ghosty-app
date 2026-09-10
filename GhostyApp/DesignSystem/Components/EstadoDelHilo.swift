import SwiftUI

/// En qué anda una conversación, en una línea.
///
/// ⚠️ «4 mensajes» no es lo que uno quiere saber de una conversación que dejó trabajando:
/// quiere saber **si ya contestó**. Con varias a la vez es lo único que deja decidir a
/// cuál volver, y era justo lo que la lista no decía.
struct EstadoDelHilo: View {
    let hilo: Hilo
    /// El reloj se repinta solo: sin esto, «hace 2 min» se queda congelado en «ahora».
    @State private var tic = Date()

    var body: some View {
        Group {
            if hilo.permisoPendiente != nil {
                etiqueta("Espera tu visto bueno", .gDangerInk)
            } else {
                switch hilo.estado {
                case .trabajando(let reloj):
                    // ⚠️ Lo que está HACIENDO, no la palabra «Trabajando». El detalle ya
                    // rota con el tiempo y lo sustituye el nombre de la herramienta en
                    // cuanto la caja manda una; poner aquí una palabra fija tiraba todo
                    // eso y tres conversaciones a la vez decían lo mismo durante minutos.
                    HStack(spacing: 5) {
                        Text(hilo.turno?.detail ?? "Trabajando")
                            .gMeta().foregroundStyle(Color.gPrimary).lineLimit(1)
                        Text(reloj).gMono(size: 13, weight: .regular)
                            .foregroundStyle(Color.gInk4)
                    }
                case .fallo(let motivo):
                    // En rojo y con su triángulo: es la única fila de la lista que pide
                    // que vuelvas a entrar.
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.gDangerInk)
                        Text(motivo).gMeta().foregroundStyle(Color.gDangerInk)
                    }
                case .listo(let cuando):
                    // Verde y con palomita: es una respuesta que TE ESPERA.
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.gGreenInk)
                        Text("Contestó · \(cuando)").gMeta().foregroundStyle(Color.gGreenInk)
                    }
                case .sinEstrenar:
                    etiqueta("Sin mensajes todavía", .gInk3)
                case .enReposo(let cuantos):
                    etiqueta(cuantos, .gInk3)
                }
            }
        }
        .id(tic)
        .task {
            // Un minuto es suficiente: lo que cambia es «hace 2 min» → «hace 3 min».
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                tic = Date()
            }
        }
    }

    private func etiqueta(_ t: String, _ color: Color) -> some View {
        Text(t).gMeta().foregroundStyle(color)
    }
}
