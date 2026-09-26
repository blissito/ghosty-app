import SwiftUI

/// La agenda de una conversación: lo que el agente hará solo, y programar más.
///
/// Es lo que hace que «trabaja en esto por días» no dependa de que abras la app: cada
/// fila es un turno futuro que gs dispara aunque el teléfono esté apagado, y el push de
/// «terminó» te trae de vuelta. La caja duerme entre turnos.
@MainActor
@Observable
final class Agenda {
    let agentID: String
    let sessionID: String
    private(set) var turnos: [TurnoProgramado] = []
    private(set) var cargando = false
    var fallo: String?

    init(agentID: String, sessionID: String) {
        self.agentID = agentID
        self.sessionID = sessionID
    }

    func recargar() async {
        cargando = true
        defer { cargando = false }
        do { turnos = try await AgendaGS.listar(agentID: agentID, sessionID: sessionID) }
        catch { fallo = error.localizedDescription }
    }

    func programar(_ prompt: String, cuando: Date, repetirCadaMin: Int?, hasta: Date?) async -> Bool {
        do {
            let t = try await AgendaGS.programar(agentID: agentID, sessionID: sessionID, prompt: prompt,
                                                cuando: cuando, repetirCadaMin: repetirCadaMin, hasta: hasta)
            turnos = (turnos + [t]).sorted { $0.dueAt < $1.dueAt }
            return true
        } catch {
            fallo = error.localizedDescription
            return false
        }
    }

    func cancelar(_ t: TurnoProgramado) async {
        // Se quita primero y se avisa después: si el servidor dice que no, vuelve.
        let antes = turnos
        turnos.removeAll { $0.id == t.id }
        do { try await AgendaGS.cancelar(agentID: agentID, sessionID: sessionID, id: t.id) }
        catch { turnos = antes; fallo = error.localizedDescription }
    }
}

/// La fila sobre el compositor: cuántos hay y cuándo es el siguiente. Tocar abre la agenda.
struct AgendaStrip: View {
    let agenda: Agenda
    let abrir: () -> Void

    // La app habla español; el formateador relativo del sistema no lo sabe y en un
    // simulador en inglés salía «Sigue in 12 minutes».
    private static let es = Locale(identifier: "es_MX")
    private func relativo(_ d: Date) -> String {
        d.formatted(.relative(presentation: .named).locale(Self.es))
    }

    var body: some View {
        if let siguiente = agenda.turnos.first {
            Button(action: abrir) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.gPrimary)
                    Text(agenda.turnos.count == 1
                         ? "Sigue \(relativo(siguiente.dueAt))"
                         : "\(agenda.turnos.count) pendientes · siguiente \(relativo(siguiente.dueAt))")
                        .gMeta().foregroundStyle(Color.gInk2)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gInk3)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.gCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 6)
            .accessibilityIdentifier("agenda-strip")
        }
    }
}

/// La hoja: pendientes arriba, programar abajo.
struct AgendaSheet: View {
    let agenda: Agenda
    @Environment(\.dismiss) private var cerrar

    @State private var prompt = ""
    @State private var cuando = Date().addingTimeInterval(3600)
    @State private var repetir = false
    @State private var cadaMin = 60
    @State private var hasta = Date().addingTimeInterval(3 * 86400)
    @State private var mandando = false

    private static let cadencias: [(String, Int)] = [
        ("15 min", 15), ("30 min", 30), ("1 h", 60), ("2 h", 120), ("4 h", 240),
        ("8 h", 480), ("Diario", 1440),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if !agenda.turnos.isEmpty {
                    Section("Pendientes") {
                        ForEach(agenda.turnos) { t in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.prompt).lineLimit(2)
                                Text(detalle(t)).gMeta()
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await agenda.cancelar(t) }
                                } label: { Label("Cancelar", systemImage: "xmark") }
                            }
                        }
                    }
                }
                Section("Programar") {
                    TextField("Qué debe hacer", text: $prompt, axis: .vertical)
                        .lineLimit(2...5)
                    DatePicker("Cuándo", selection: $cuando, in: Date()...)
                    Toggle("Repetir", isOn: $repetir)
                    if repetir {
                        Picker("Cada", selection: $cadaMin) {
                            ForEach(Self.cadencias, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        DatePicker("Hasta", selection: $hasta, in: cuando...)
                    }
                }
                if let f = agenda.fallo {
                    Section { Text(f).foregroundStyle(Color.gDanger) }
                }
            }
            .navigationTitle("Agenda del agente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { cerrar() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mandando ? "…" : "Programar") { programar() }
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || mandando)
                }
            }
            .task { await agenda.recargar() }
        }
    }

    private func detalle(_ t: TurnoProgramado) -> String {
        var s = t.dueAt.formatted(date: .abbreviated, time: .shortened)
        if let r = t.repeatMin {
            s += " · cada \(Self.cadencias.first { $0.1 == r }?.0 ?? "\(r) min")"
            if let u = t.until { s += " hasta \(u.formatted(date: .abbreviated, time: .omitted))" }
        }
        if t.createdBy == "agent" { s += " · lo programó el agente" }
        return s
    }

    private func programar() {
        mandando = true
        agenda.fallo = nil
        Task {
            let ok = await agenda.programar(prompt, cuando: cuando,
                                            repetirCadaMin: repetir ? cadaMin : nil,
                                            hasta: repetir ? hasta : nil)
            mandando = false
            if ok { prompt = "" }
        }
    }
}
