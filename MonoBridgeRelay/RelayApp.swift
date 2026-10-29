import SwiftUI

/// Mono Bridge Relay (macOS): nodo de malla fijo. La Mac se une a la red de los
/// iPhones como un peer más, repite la malla para extender el alcance, y muestra
/// el radar de quién está conectado. Pensado como nodo de respaldo en
/// emergencias (no captura audio ni usa sensores).
@main
struct RelayApp: App {
    @StateObject private var relay = RelaySession()

    var body: some Scene {
        WindowGroup {
            RelayView()
                .environmentObject(relay)
                .frame(minWidth: 420, minHeight: 520)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

struct RelayView: View {
    @EnvironmentObject private var relay: RelaySession
    /// Modo de voz: push-to-talk (mantener) o manos libres (toggle).
    @State private var pushToTalk = true
    /// Texto del mensaje a enviar al grupo.
    @State private var messageText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Button {
                relay.toggle()
            } label: {
                Text(relay.running ? "DETENER NODO" : "ACTIVAR NODO")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(relay.running ? .red : .green)

            // Mensajes y alarma: paquetes cortos, confiables (no audio continuo).
            if relay.running {
                messageControls

                // Audio en vivo: APAGADO por defecto (desestabiliza la conexión).
                // Solo enciéndelo si de verdad quieres hablar/oír en vivo.
                Button {
                    relay.toggleAudio()
                } label: {
                    Label(relay.audioReady ? "APAGAR AUDIO EN VIVO" : "ACTIVAR AUDIO EN VIVO",
                          systemImage: relay.audioReady ? "speaker.wave.2.fill" : "speaker.slash")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(relay.audioReady ? .orange : .secondary)

                if relay.audioReady {
                    talkControls
                } else {
                    Text("Audio en vivo apagado. La alarma y los mensajes sí funcionan (más estables). Enciende el audio solo si quieres voz en vivo (puede desconectar).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            radarVisual
            radarCard
            statsRow
            eventsCard
            Spacer()
            Text("Nodo de malla: radar, alarma y mensajes son estables. El audio en vivo es EXPERIMENTAL y puede desconectarse (límite de la conexión directa Mac↔iPhone). El audio no se graba. No reemplaza a servicios de emergencia.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        // Barra espaciadora = push-to-talk mientras se mantiene (solo en modo PTT).
        .focusable()
        .onKeyPress(phases: .down) { press in
            if pushToTalk, relay.running, press.key == .space, !relay.talking {
                relay.setTalking(true); return .handled
            }
            return .ignored
        }
        .onKeyPress(phases: .up) { press in
            if pushToTalk, press.key == .space, relay.talking {
                relay.setTalking(false); return .handled
            }
            return .ignored
        }
    }

    // Alarma + mensajes: confiables (paquetes cortos, no audio continuo).
    private var messageControls: some View {
        VStack(spacing: 8) {
            // Botón de ALARMA de emergencia.
            Button {
                relay.sendAlarm()
            } label: {
                Label("ALARMA DE EMERGENCIA", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.heavy))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            // Mensaje de texto al grupo (el iPhone lo lee por voz).
            HStack(spacing: 8) {
                TextField("Mensaje al grupo…", text: $messageText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { enviarMensaje() }
                Button("Enviar") { enviarMensaje() }
                    .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("La alarma y los mensajes son avisos cortos: el teléfono los lee por voz. Más confiables que el audio en vivo.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func enviarMensaje() {
        let t = messageText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        relay.sendMessage(t)
        messageText = ""
    }

    // Control de voz: selector PTT/manos libres + botón de hablar.
    private var talkControls: some View {
        VStack(spacing: 8) {
            Picker("", selection: $pushToTalk) {
                Text("Mantener para hablar").tag(true)
                Text("Manos libres").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: pushToTalk) { _, _ in
                // Al cambiar de modo, cerrar el micrófono por seguridad.
                relay.setTalking(false)
            }

            if pushToTalk {
                // Push-to-talk: abre el mic SOLO mientras mantienes presionado.
                // Es lo que evita el eco (mic abierto solo al hablar).
                Text(relay.talking ? "🎙️ HABLANDO…" : "MANTÉN PARA HABLAR")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(relay.talking ? Color.orange : Color.gray.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in if !relay.talking { relay.setTalking(true) } }
                            .onEnded { _ in relay.setTalking(false) }
                    )
                    .disabled(!relay.audioReady)
                Text("Mantén presionado (o la barra espaciadora) mientras hablas. Recomendado: evita el eco.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                // Manos libres: toggle (mic continuo). Puede meter eco sin audífonos.
                Button {
                    relay.toggleTalk()
                } label: {
                    Label(relay.talking ? "HABLANDO — toca para silenciar" : "HABLAR (manos libres)",
                          systemImage: relay.talking ? "mic.fill" : "mic")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(relay.talking ? .orange : .gray)
                .disabled(!relay.audioReady)
                Text("Micrófono siempre abierto. Usa audífonos en la Mac para evitar eco.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 28)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mono Bridge Relay").font(.title2.weight(.heavy))
                Text(relay.localName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(relay.running ? Color.green : Color.gray)
                .frame(width: 12, height: 12)
                .shadow(color: relay.running ? .green.opacity(0.8) : .clear, radius: 5)
        }
    }

    // Radar visual tipo pantalla de radar.
    private var radarVisual: some View {
        RadarView()
            .frame(height: 260)
            .padding(10)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var radarCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NODOS DETECTADOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if relay.riders.isEmpty {
                Text(relay.running ? "Buscando nodos en la malla…" : "Activa el nodo para empezar.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(relay.riders) { r in
                    HStack(spacing: 10) {
                        Circle().fill(color(r.level)).frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(r.name).font(.body.weight(.medium))
                                trendBadge(r.trend)
                            }
                            if let d = detail(r) {
                                Text(d).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        // Rastro (mini-gráfica de proximidad en el tiempo).
                        TrailSparkline(trail: r.trail, color: color(r.level))
                            .frame(width: 70, height: 24)
                        Text(label(r.level, hops: r.hops))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Insignia de tendencia del rastro: acercándose / alejándose / estable.
    @ViewBuilder
    private func trendBadge(_ trend: Int) -> some View {
        switch trend {
        case 1:
            Label("se acerca", systemImage: "arrow.up.right")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
        case -1:
            Label("se aleja", systemImage: "arrow.down.right")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    /// Detalle de altura/pisos + batería de un nodo (Modo Rescate).
    private func detail(_ node: RelaySession.RiderNode) -> String? {
        var parts: [String] = []
        if let m = relay.metersDelta(for: node) {
            let am = abs(m)
            if am < 1 { parts.append("Mismo nivel") }
            else {
                let dir = m > 0 ? "ARRIBA" : "ABAJO"
                let f = abs(relay.floors(for: node) ?? 0)
                parts.append(f == 0 ? "≈\(Int(am)) m \(dir)" : "≈\(Int(am)) m \(dir) (\(f) pisos)")
            }
        }
        if let b = node.batteryPercent { parts.append("🔋 \(b)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var statsRow: some View {
        HStack(spacing: 16) {
            stat("Conectados", "\(relay.connectedPeers.count)")
            stat("Nodos vistos", "\(relay.riders.count)")
            stat("Relevados", "\(relay.relayedPackets)")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.title3.weight(.bold)).foregroundStyle(.green)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ACTIVIDAD").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(relay.events.enumerated()), id: \.offset) { _, e in
                        Text(e).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
        .padding(14)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func color(_ l: RelaySession.RiderNode.Level) -> Color {
        switch l { case .near: return .green; case .far: return .yellow; case .lost: return .red }
    }
    private func label(_ l: RelaySession.RiderNode.Level, hops: Int) -> String {
        switch l {
        case .near: return "cerca"
        case .far: return "lejos (\(hops) saltos)"
        case .lost: return "sin señal"
        }
    }
}
