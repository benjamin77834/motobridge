import Foundation
import Combine

/// Estado global de la app, inyectado en el entorno de SwiftUI.
/// Orquesta los managers de audio, dispositivos y bridge.
final class AppState: ObservableObject {
    let audioSession: AudioSessionManager
    let bridge: AudioBridge
    let logger: Logger

    @Published var freedConn: FreedConnDevice
    @Published var hysnox: HysnoxDevice

    @Published var micEnabled: Bool = false
    @Published var pttActive: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        self.audioSession = AudioSessionManager()
        self.bridge = AudioBridge()
        self.logger = Logger.shared
        self.freedConn = FreedConnDevice()
        self.hysnox = HysnoxDevice()

        logger.info(.general, "MotoBridge iniciado (FASE 1 + FASE 3).")

        // Sincroniza el estado de los dispositivos con la ruta de audio activa.
        audioSession.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in
                self?.updateDeviceStates(from: snap)
            }
            .store(in: &cancellables)
    }

    /// Actualiza el estado de los dispositivos según los puertos Bluetooth
    /// presentes en la ruta activa. Es una heurística por nombre: iOS no nos
    /// dice "esto es FreedConn", así que hacemos match por substring del nombre.
    private func updateDeviceStates(from snap: AudioRouteSnapshot) {
        let activeNames = (snap.currentInputs + snap.currentOutputs)
            .filter { $0.isBluetooth }
            .map { $0.portName.lowercased() }

        let freedConnPresent = activeNames.contains { $0.contains("freedconn") || $0.contains("t-com") }
        let hysnoxPresent = activeNames.contains { $0.contains("hysnox") }

        freedConn.updateFromAudioRoute(isPresentInRoute: freedConnPresent)
        hysnox.updateFromAudioRoute(isPresentInRoute: hysnoxPresent)
    }

    func startDiagnostics() {
        audioSession.configureForVoice()
        audioSession.activate()
        audioSession.refreshSnapshot()
    }
}
