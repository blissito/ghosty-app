import PhotosUI
import SwiftUI

struct ConversationView: View {
    let store: LiveAgentStore
    var onOpenSheet: () -> Void

    @State private var borrador = ""
    @FocusState private var escribiendo: Bool

    // Adjuntos que esperan a que se mande el turno.
    @State private var adjuntos: [Adjunto] = []
    @State private var fotos: [PhotosPickerItem] = []
    @State private var abrirFotos = false
    @State private var abrirArchivos = false
    @State private var abrirCamara = false
    @State private var subiendo = false
    @State private var fallo: String?

    var body: some View {
        VStack(spacing: 0) {
            if let agente = store.selectedAgent {
                AgentHeader(agent: agente, onTap: { escribiendo = false; onOpenSheet() })
                    .padding(.top, 8)
                    .padding(.bottom, 14)
            }

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if store.messages.isEmpty {
                            primeraVez
                                .padding(.top, 90)
                        }
                        ForEach(store.messages) { mensaje in
                            fila(mensaje).id(mensaje.id)
                                // Sólo la entrega se anima al entrar: llega a mitad del
                                // turno, cuando la persona está mirando, y aparecer de
                                // golpe se lee como un salto del texto. Las burbujas no
                                // la llevan a propósito — animar CADA trozo del streaming
                                // haría temblar el hilo entero.
                                .transition(esEntrega(mensaje)
                                            ? .scale(scale: 0.94).combined(with: .opacity)
                                            : .identity)
                        }
                        Color.clear.frame(height: 1).id("fondo")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded { escribiendo = false }
                )
                .onChange(of: store.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { scroll.scrollTo("fondo", anchor: .bottom) }
                }
                // También al crecer el ÚLTIMO mensaje: la respuesta llega en trozos y
                // sin esto el texto nuevo queda fuera de vista mientras se escribe.
                .onChange(of: textoDelUltimo) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) { scroll.scrollTo("fondo", anchor: .bottom) }
                }
            }

            compositor
        }
        .sensoryFeedback(.success, trigger: entregasEnElHilo)
        .sensoryFeedback(.impact(weight: .light), trigger: adjuntos.count)
    }

    /// Ejemplos de lo que se le puede pedir. Al tocarlos se escriben en el campo —no se
    /// envían— para que la persona pueda cambiarlos antes de mandarlos.
    private static let ejemplos = [
        "Resume este PDF",
        "Búscame precios y hazme una tabla",
        "Arma una cotización en PDF",
    ]

    /// El vacío del hilo.
    ///
    /// ⚠️ NO explica cómo funciona por dentro. Decía "este hilo habla con tu caja de verdad
    /// y lo que contesta se pinta como markdown": la caja es vocabulario NUESTRO —nadie de
    /// fuera sabe qué es— y el markdown es un detalle de implementación que no le resuelve
    /// nada a quien abre la app por primera vez. Lo que esa persona necesita saber es qué
    /// pedirle, así que el vacío ES el onboarding. Es lo que hace Muse con su pestaña de
    /// ideas y lo que hacen todos los demás.
    ///
    /// Dónde SÍ se nombra la máquina: en Ajustes, en posesivo y como promesa ("vive en tu
    /// propia computadora en la nube"), que es exactamente el molde de Meta — primero lo
    /// que es tuyo, después, y sólo si hace falta, lo técnico.
    private var primeraVez: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.gInk4)
            Text("¿En qué te ayudo?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.gInk2)

            VStack(spacing: 8) {
                ForEach(Self.ejemplos, id: \.self) { texto in
                    Button {
                        borrador = texto
                        escribiendo = true
                    } label: {
                        Text(texto)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.gInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity)
                            .background(Color.gCard, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity)
    }

    private func esEntrega(_ m: Message) -> Bool {
        if case .entrega = m.kind { return true }
        return false
    }

    /// Cuántas entregas lleva el hilo. Dispara la háptica: es un cambio del MUNDO (te
    /// llegó algo), no de la pantalla, y el teléfono tiene una forma nativa de decirlo.
    private var entregasEnElHilo: Int {
        store.messages.reduce(0) { $0 + (esEntrega($1) ? 1 : 0) }
    }

    private var textoDelUltimo: Int {
        guard case .agent(let t, _, _) = store.messages.last?.kind else { return 0 }
        return t.count
    }

    @ViewBuilder
    private func fila(_ mensaje: Message) -> some View {
        switch mensaje.kind {
        case .user(let t, let adj):
            HStack { Spacer(minLength: 40); UserBubble(text: t, adjuntos: adj) }
        case .agent(let t, let tools, let trailing):
            HStack { AgentBubble(text: t, tools: tools, trailing: trailing); Spacer(minLength: 30) }
        case .entrega(let e):
            HStack { EntregaCard(entrega: e); Spacer(minLength: 30) }
        case .prCard(let card):
            HStack {
                PRCard(card: card,
                       onApprove:        { Task { await store.respondToPR(card, approve: true) } },
                       onRequestChanges: { Task { await store.respondToPR(card, approve: false) } })
                Spacer(minLength: 30)
            }
        case .typing:
            HStack { TypingBubble(); Spacer() }
        }
    }

    /// El compositor sólo trae controles que hacen algo.
    ///
    /// ⚠️ El `+` es SÓLO para adjuntar. Tuvo también "nueva conversación", "cambiar de
    /// agente" y "tu cuenta", y las tres estaban duplicadas: la primera es el botón grande
    /// de la hoja del agente, la segunda ES la pestaña Flota, y la tercera su engrane.
    /// Llegaron ahí cuando eran el único acceso. Con seis entradas había que leerlas todas
    /// para encontrar las tres que hacen lo que un `+` promete en cualquier app.
    ///
    /// Si "nueva conversación" acaba haciendo falta más cerca, la vuelta atrás NO es
    /// devolverla al menú —un menú con dos intenciones ya se probó peor— sino darle su
    /// propio icono aquí.
    private var compositor: some View {
        VStack(spacing: 8) {
            if !adjuntos.isEmpty || fallo != nil { antesDeMandar }
            capsula
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .photosPicker(isPresented: $abrirFotos, selection: $fotos, maxSelectionCount: 4,
                      matching: .images)
        .onChange(of: fotos) { _, nuevas in
            guard !nuevas.isEmpty else { return }
            Task {
                for item in nuevas {
                    let datos = try? await item.loadTransferable(type: Data.self)
                    // El nombre no viaja con la foto: se inventa uno legible, porque es lo
                    // que la persona va a ver en el chip y lo que el agente verá si sube.
                    agregar(datos.map {
                        Adjunto(nombre: "foto-\(adjuntos.count + 1).jpg", mime: "image/jpeg", datos: $0)
                    })
                }
                fotos = []
            }
        }
        .fileImporter(isPresented: $abrirArchivos, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { r in
            switch r {
            case .success(let urls): for u in urls { agregar(Adjunto(url: u)) }
            case .failure: fallo = "No pude abrir ese archivo."
            }
        }
        .fullScreenCover(isPresented: $abrirCamara) {
            CamaraPicker { d in
                agregar(Adjunto(nombre: "foto.jpg", mime: "image/jpeg", datos: d))
            }
            .ignoresSafeArea()
        }
    }

    /// Los adjuntos que esperan, y el aviso si algo falló.
    private var antesDeMandar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !adjuntos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(adjuntos) { a in
                            AdjuntoChip(adjunto: a) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    adjuntos.removeAll { $0.id == a.id }
                                }
                            }
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 52)
            }
            if let fallo {
                Text(fallo).gCaption().foregroundStyle(Color.gDangerInk)
                    .padding(.horizontal, 4)
            }
        }
        .transition(.opacity)
    }

    private var capsula: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Button { abrirFotos = true } label: { Label("Foto", systemImage: "photo") }
                    Button { abrirCamara = true } label: { Label("Cámara", systemImage: "camera") }
                    Button { abrirArchivos = true } label: { Label("Archivo", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.gInk3)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }

                TextField("Mensaje", text: $borrador, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .lineLimit(1...4)
                    .focused($escribiendo)
                    .submitLabel(.send)
                    .onSubmit(enviar)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Listo") { escribiendo = false }
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.gPrimary)
                        }
                    }

                Button(action: enviar) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(hayQueMandar && !subiendo
                                    ? AnyShapeStyle(Theme.primaryGradient)
                                    : AnyShapeStyle(Color.gInk4.opacity(0.45)))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!hayQueMandar || subiendo)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(Color.gCard)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
        }
    }

    private var hayQueMandar: Bool {
        !borrador.trimmingCharacters(in: .whitespaces).isEmpty || !adjuntos.isEmpty
    }

    private func enviar() {
        guard hayQueMandar, !subiendo else { return }
        let texto = borrador
        let envio = adjuntos
        borrador = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { adjuntos = [] }
        fallo = nil
        // ⚠️ `subiendo` gatea el botón mientras los archivos viajan a la máquina del
        // agente. Sin esto se pueden encolar dos turnos con el mismo adjunto.
        subiendo = !envio.filter { !$0.esImagen }.isEmpty
        Task {
            await store.send(texto, adjuntos: envio)
            subiendo = false
            // La subida falla dentro del turno, así que el aviso sale de ahí: el store
            // pinta el error en el hilo. Aquí sólo se devuelven los adjuntos para que la
            // persona pueda reintentar sin volver a elegirlos.
            if store.ultimoEnvioFallo {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    adjuntos = envio
                    borrador = texto
                }
                fallo = "No se pudo mandar. Inténtalo otra vez."
            }
        }
    }

    private func agregar(_ a: Adjunto?) {
        guard let a else { fallo = "No pude leer ese archivo."; return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            adjuntos.append(a)
            fallo = nil
        }
    }
}
