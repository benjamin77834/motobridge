import SwiftUI

/// Pantalla "Audio Diagnostics" (FASE 3 / sección 7).
/// Muestra el estado real reportado por AVAudioSession y la respuesta
/// experimental a "¿iOS permite las rutas necesarias?" (no inventada).
struct AudioDiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var audioSession: AudioSessionManager
    @EnvironmentObject private var logger: Logger

    @State private var shareURL: ShareItem?

    var body: some View {
        List {
            Section {
                Button("Iniciar / Refrescar diagnóstico") {
                    appState.startDiagnostics()
                }
                .font(.headline)
            }

            Section("Veredicto experimental") {
                Text(audioSession.verdict.displayText)
                    .font(.callout)
            }

            Section("Sesión") {
                infoRow("Activa", audioSession.isActive ? "Sí" : "No")
                infoRow("Categoría", audioSession.snapshot.category)
                infoRow("Modo", audioSession.snapshot.mode)
                infoRow("Sample rate", String(format: "%.0f Hz", audioSession.snapshot.sampleRate))
                infoRow("Canales in", "\(audioSession.snapshot.inputChannels)")
                infoRow("Canales out", "\(audioSession.snapshot.outputChannels)")
                infoRow("Buffer IO", String(format: "%.1f ms", audioSession.snapshot.ioBufferDuration * 1000))
                infoRow("Otro audio sonando", audioSession.snapshot.isOtherAudioPlaying ? "Sí" : "No")
            }

            Section("Input actual") {
                portList(audioSession.snapshot.currentInputs)
            }

            Section("Output actual") {
                portList(audioSession.snapshot.currentOutputs)
            }

            Section("Available inputs") {
                portList(audioSession.snapshot.availableInputs)
            }

            Section("Eventos") {
                infoRow("Último cambio de ruta", audioSession.lastRouteChangeReason)
                infoRow("Última interrupción", audioSession.lastInterruption)
            }

            Section("Diagnóstico") {
                Button("Exportar diagnóstico") {
                    if let url = logger.exportToFile() {
                        shareURL = ShareItem(url: url)
                    }
                }
            }
        }
        .navigationTitle("Audio Diagnostics")
        .onAppear { audioSession.refreshSnapshot() }
        .sheet(item: $shareURL) { item in
            ShareSheet(items: [item.url])
        }
    }

    @ViewBuilder
    private func portList(_ ports: [AudioRouteSnapshot.Port]) -> some View {
        if ports.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            ForEach(ports) { port in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(port.portName).font(.subheadline.weight(.semibold))
                        if port.isBluetooth {
                            Image(systemName: "wave.3.right")
                                .foregroundStyle(.blue)
                        }
                    }
                    Text("\(port.portType) · \(port.channels) canal(es)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// Wrapper Identifiable para presentar el share sheet.
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Envoltura de UIActivityViewController para exportar el diagnóstico.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        AudioDiagnosticsView()
            .environmentObject(AppState())
            .environmentObject(AudioSessionManager())
            .environmentObject(Logger.shared)
    }
    .preferredColorScheme(.dark)
}
