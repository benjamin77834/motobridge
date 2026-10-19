import SwiftUI

/// Tarjeta de MODO RESCATE para la pantalla "Estado de dispositivos".
///
/// Pensada para localizar a una persona atrapada SIN GPS (terremoto, derrumbe,
/// cueva). Muestra, de cada persona detectada por la malla:
///  - Señal (caliente/frío) por cercanía de la malla.
///  - Diferencia de PISOS estimada con el altímetro barométrico.
///  - Batería del otro teléfono (para priorizar el rescate).
///  - Rumbo de brújula del rescatista (para anotar dónde sube la señal).
struct RescueCard: View {
    @ObservedObject var controller = NetworkBridgeController.shared
    @ObservedObject private var sensors = NetworkBridgeController.shared.rescueSensors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { controller.rescueMode },
                set: { controller.updateRescueMode($0) }
            )) {
                Label("Modo Rescate", systemImage: "cross.case.fill")
                    .font(.headline)
            }
            .tint(.red)

            Text("Localiza a una persona atrapada cuando no hay GPS (terremoto, derrumbe, cueva). Usa el altímetro para estimar en qué piso está y la señal para orientar la búsqueda.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if controller.rescueMode {
                Divider()
                sensorStatusRow

                if !controller.isRunning {
                    Label("Inicia el bridge (modo Apple) para empezar a buscar.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                } else if controller.riderSignals.isEmpty {
                    Label("Buscando señales de personas con la app…",
                          systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(controller.riderSignals) { sig in
                        rescueRow(sig)
                    }
                }

                Divider()
                Text("Aviso: estima pisos y cercanía de forma aproximada; el concreto y el clima afectan la medición. Es apoyo al rescate, NO reemplaza al 911 ni a Protección Civil.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    // Estado de los sensores del propio teléfono.
    private var sensorStatusRow: some View {
        HStack(spacing: 16) {
            Label(sensors.hasBarometer
                  ? (sensors.relativeAltitudeMeters != nil ? "Altímetro OK" : "Altímetro…")
                  : "Sin altímetro",
                  systemImage: "barometer")
                .font(.caption)
                .foregroundStyle(sensors.hasBarometer ? .green : .secondary)
            if let h = sensors.headingDegrees {
                Label("\(compass(h)) \(Int(h))°", systemImage: "location.north.line")
                    .font(.caption).foregroundStyle(.blue)
            } else {
                Label("Brújula…", systemImage: "location.north.line")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // Fila de una persona detectada.
    private func rescueRow(_ sig: NetworkBridgeController.RiderSignal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle().fill(signalColor(sig.level))
                    .frame(width: 14, height: 14)
                Text(sig.name).font(.subheadline.weight(.bold))
                Spacer()
                Text(signalLabel(sig.level))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(signalColor(sig.level))
            }
            HStack(spacing: 14) {
                // Diferencia de altura: metros + pisos (altímetro).
                if let meters = controller.metersTo(sig) {
                    let floors = controller.floorsTo(sig) ?? 0
                    Label(altitudeText(meters: meters, floors: floors),
                          systemImage: directionIcon(meters))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(abs(meters) < 1 ? .green : .orange)
                } else {
                    Label("Altura: sin dato", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Batería del otro teléfono.
                if let bat = sig.batteryPercent {
                    Label("\(bat)%", systemImage: batteryIcon(bat))
                        .font(.caption)
                        .foregroundStyle(bat <= 15 ? .red : .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers de presentación

    /// Texto de altura: metros exactos + estimación de pisos y dirección vertical.
    /// Ej.: "≈ 6 m ABAJO (2 pisos)". Si están casi al mismo nivel, lo indica.
    private func altitudeText(meters: Double, floors: Int) -> String {
        let m = abs(meters)
        if m < 1 { return "Mismo nivel que tú (±1 m)" }
        let dir = meters > 0 ? "ARRIBA" : "ABAJO"
        let mText = String(format: "%.0f m", m)
        if floors == 0 {
            return "≈ \(mText) \(dir)"
        }
        let n = abs(floors)
        let piso = n == 1 ? "piso" : "pisos"
        return "≈ \(mText) \(dir) (\(n) \(piso))"
    }

    /// Flecha según la dirección vertical (arriba / abajo / mismo nivel).
    private func directionIcon(_ meters: Double) -> String {
        if abs(meters) < 1 { return "equal.circle" }
        return meters > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    }

    private func signalColor(_ level: NetworkBridgeController.RiderSignal.Level) -> Color {
        switch level {
        case .near: return .green
        case .far: return .yellow
        case .lost: return .red
        }
    }

    private func signalLabel(_ level: NetworkBridgeController.RiderSignal.Level) -> String {
        switch level {
        case .near: return "🔥 señal fuerte"
        case .far: return "señal débil"
        case .lost: return "sin señal"
        }
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<70: return "battery.50percent"
        default: return "battery.100percent"
        }
    }

    private func compass(_ deg: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
        let idx = Int((deg / 45.0).rounded()) % 8
        return dirs[(idx + 8) % 8]
    }
}
