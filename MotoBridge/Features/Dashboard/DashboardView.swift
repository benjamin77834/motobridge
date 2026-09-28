import SwiftUI

/// Pantalla principal (secciones 4 y 12). Botones grandes, alto contraste, dark mode.
struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var audioSession: AudioSessionManager

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                deviceStatusSection
                bridgeSection
                micSection
                pttSection
                audioRouteSection
            }
            .padding()
        }
        .navigationTitle("Estado de dispositivos")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Secciones

    private var deviceStatusSection: some View {
        VStack(spacing: 12) {
            DeviceStatusRow(name: appState.freedConn.name,
                            model: appState.freedConn.model,
                            state: appState.freedConn.connectionState)
            DeviceStatusRow(name: appState.hysnox.name,
                            model: appState.hysnox.model,
                            state: appState.hysnox.connectionState)
        }
        .cardStyle()
    }

    private var bridgeSection: some View {
        VStack(spacing: 8) {
            Text("BRIDGE")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // El bridge BT↔BT no es viable (FEASIBILITY_REPORT). Mostramos la
            // limitación honestamente en lugar de un toggle que no hace nada.
            if let reason = appState.bridge.unavailabilityReason.userMessage {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                appState.bridge.prepare()
            } label: {
                Text("PROBAR BRIDGE")
                    .bigButtonLabel()
            }
            .buttonStyle(.borderedProminent)
            .tint(.gray)

            Text("Bridge directo Bluetooth↔Bluetooth no soportado por iOS.\nDiseño objetivo: bridge por red entre dos iPhones (fase futura).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle()
    }

    private var micSection: some View {
        VStack(spacing: 8) {
            Text("MIC")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: $appState.micEnabled) {
                Text(appState.micEnabled ? "ON" : "OFF")
                    .font(.title3.weight(.bold))
            }
            .toggleStyle(.switch)
        }
        .cardStyle()
    }

    private var pttSection: some View {
        VStack(spacing: 8) {
            Text("PUSH TO TALK")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(appState.pttActive ? "TRANSMITIENDO" : "MANTÉN PARA HABLAR")
                .font(.title2.weight(.heavy))
                .foregroundStyle(appState.pttActive ? .green : .primary)
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(appState.pttActive ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !appState.pttActive { appState.pttActive = true }
                        }
                        .onEnded { _ in
                            appState.pttActive = false
                        }
                )
                .accessibilityLabel("Push to talk. Mantén presionado para transmitir.")
        }
        .cardStyle()
    }

    private var audioRouteSection: some View {
        VStack(spacing: 6) {
            Text("Audio")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            let route = routeSummary
            Text(route)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle()
    }

    private var routeSummary: String {
        let inputs = audioSession.snapshot.currentInputs.map { $0.portName }.joined(separator: ", ")
        let outputs = audioSession.snapshot.currentOutputs.map { $0.portName }.joined(separator: ", ")
        return "In: \(inputs.isEmpty ? "—" : inputs)\nOut: \(outputs.isEmpty ? "—" : outputs)"
    }

    private var navigationSection: some View {
        VStack(spacing: 12) {
            NavigationLink {
                AudioDiagnosticsView()
            } label: {
                Text("Diagnostics").bigButtonLabel()
            }
            .buttonStyle(.bordered)

            NavigationLink {
                SettingsView()
            } label: {
                Text("Settings").bigButtonLabel()
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Subvistas

struct DeviceStatusRow: View {
    let name: String
    let model: String
    let state: ConnectionState

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading) {
                Text(name).font(.headline)
                Text(model).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(state.rawValue.uppercased())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected, .unavailable: return .red
        }
    }
}

// MARK: - Estilos reutilizables

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
    func bigButtonLabel() -> some View {
        self.font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 54)
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
        .environmentObject(AudioSessionManager())
        .environmentObject(Logger.shared)
        .preferredColorScheme(.dark)
}
