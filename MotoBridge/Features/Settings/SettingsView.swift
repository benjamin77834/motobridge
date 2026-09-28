import SwiftUI

/// Pantalla Settings (sección 13). Esqueleto honesto: expone las secciones
/// previstas; el detalle de cada una se implementará en fases posteriores.
struct SettingsView: View {
    @EnvironmentObject private var logger: Logger

    var body: some View {
        List {
            Section("Device Management") {
                Text("FreedConn T-COM VB")
                Text("Hysnox")
                Text("La conexión Bluetooth se gestiona en Ajustes de iOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Audio") {
                Text("Configuración de audio (próxima fase)")
                    .foregroundStyle(.secondary)
            }

            Section("Push-to-Talk") {
                Text("Selección de destino: FreedConn / Hysnox / Ambos (próxima fase)")
                    .foregroundStyle(.secondary)
            }

            Section("Latency") {
                Text("Métricas de latencia (próxima fase)")
                    .foregroundStyle(.secondary)
            }

            NavigationLink("Diagnostics") {
                LogView()
            }

            Section("Permissions") {
                Text("Bluetooth y Micrófono se solicitan solo cuando son necesarios.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                infoRow("App", "MotoBridge")
                infoRow("Versión", "0.1.0 (FASE 1 + FASE 3)")
            }
        }
        .navigationTitle("Settings")
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}

/// Vista del log central en vivo.
struct LogView: View {
    @EnvironmentObject private var logger: Logger

    var body: some View {
        List(logger.entries.reversed()) { entry in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.level.rawValue)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(color(for: entry.level))
                    Text(entry.category.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(entry.message).font(.caption)
            }
        }
        .navigationTitle("Logs")
        .toolbar {
            Button("Limpiar") { logger.clear() }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView().environmentObject(Logger.shared)
    }
    .preferredColorScheme(.dark)
}
