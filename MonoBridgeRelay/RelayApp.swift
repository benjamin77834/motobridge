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

            // Botón HABLAR: la Mac como puesto de voz. Solo si el audio está listo.
            if relay.running {
                Button {
                    relay.toggleTalk()
                } label: {
                    Label(relay.talking ? "HABLANDO — toca para silenciar" : "HABLAR (micrófono)",
                          systemImage: relay.talking ? "mic.fill" : "mic")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(relay.talking ? .orange : .gray)
                .disabled(!relay.audioReady)
                if !relay.audioReady {
                    Text("Esperando permiso de micrófono… (Ajustes del sistema → Privacidad → Micrófono)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            radarVisual
            radarCard
            statsRow
            eventsCard
            Spacer()
            Text("Nodo de respaldo para la red malla. No graba ni reproduce audio; solo extiende el alcance y monitorea. No reemplaza a servicios de emergencia.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
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
