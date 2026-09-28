import Foundation
import AVFoundation
import Combine

/// Snapshot inmutable del estado de audio, pensado para mostrarse en la UI de
/// Audio Diagnostics (FASE 3) sin exponer objetos mutables de AVFoundation.
struct AudioRouteSnapshot {
    struct Port: Identifiable {
        let id = UUID()
        let portName: String
        let portType: String
        let channels: Int
        let isBluetooth: Bool
    }

    var currentInputs: [Port] = []
    var currentOutputs: [Port] = []
    var availableInputs: [Port] = []
    var sampleRate: Double = 0
    var inputChannels: Int = 0
    var outputChannels: Int = 0
    var ioBufferDuration: Double = 0
    var category: String = ""
    var mode: String = ""
    var isOtherAudioPlaying: Bool = false

    /// Cuenta de dispositivos Bluetooth presentes como entrada/salida activa.
    var activeBluetoothRouteCount: Int {
        let ins = currentInputs.filter { $0.isBluetooth }.count
        let outs = currentOutputs.filter { $0.isBluetooth }.count
        return ins + outs
    }
}

/// Resultado de la evaluación experimental de rutas simultáneas (sección 7 / FASE 3).
enum SimultaneousRouteVerdict {
    case notEvaluated
    /// Solo una ruta Bluetooth activa a la vez (comportamiento esperado por el FEASIBILITY_REPORT).
    case singleBluetoothRoute(detail: String)
    /// Se observaron dos dispositivos Bluetooth simultáneos en la ruta (inesperado; requiere revisión).
    case multipleBluetoothRoutesObserved(detail: String)

    var displayText: String {
        switch self {
        case .notEvaluated:
            return "Aún no evaluado. Activa el diagnóstico con los dos intercomunicadores conectados."
        case .singleBluetoothRoute(let detail):
            return "iOS expone una sola ruta Bluetooth de audio a la vez.\n\(detail)"
        case .multipleBluetoothRoutesObserved(let detail):
            return "Se observaron múltiples rutas Bluetooth simultáneas.\n\(detail)"
        }
    }
}

/// Gestiona AVAudioSession: configuración, activación, detección de rutas,
/// interrupciones y cambios de ruta (sección 6). Publica estado observable.
final class AudioSessionManager: ObservableObject {

    @Published private(set) var isActive: Bool = false
    @Published private(set) var snapshot = AudioRouteSnapshot()
    @Published private(set) var lastRouteChangeReason: String = "—"
    @Published private(set) var lastInterruption: String = "—"
    @Published private(set) var verdict: SimultaneousRouteVerdict = .notEvaluated

    private let session = AVAudioSession.sharedInstance()
    private let log = Logger.shared
    private var observers: [NSObjectProtocol] = []

    init() {
        registerNotifications()
        refreshSnapshot()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Configuración

    /// Configura la categoría de voz. Usamos playAndRecord + .voiceChat + HFP,
    /// que es la combinación soportada por iOS para comunicación bidireccional
    /// con UN dispositivo Bluetooth (ver FEASIBILITY_REPORT sección 3).
    func configureForVoice() {
        do {
            // allowBluetoothHFP habilita HFP (voz bidireccional con UN dispositivo BT).
            // En SDKs previos a iOS 18 el nombre era .allowBluetooth.
            let bluetoothOption: AVAudioSession.CategoryOptions
            if #available(iOS 18.0, *) {
                bluetoothOption = .allowBluetoothHFP
            } else {
                // Valor histórico de .allowBluetooth (rawValue estable) para el
                // fallback en iOS 17 sin usar el símbolo deprecado directamente.
                bluetoothOption = AVAudioSession.CategoryOptions(rawValue: 0x4)
            }
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [bluetoothOption, .defaultToSpeaker, .duckOthers]
            )
            log.info(.audioSession, "Categoría configurada: playAndRecord / voiceChat / allowBluetooth")
            refreshSnapshot()
        } catch {
            log.error(.audioSession, "Error al configurar categoría: \(error.localizedDescription)")
        }
    }

    func activate() {
        do {
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            isActive = true
            log.info(.audioSession, "Sesión de audio activada")
            refreshSnapshot()
        } catch {
            log.error(.audioSession, "Error al activar la sesión: \(error.localizedDescription)")
        }
    }

    func deactivate() {
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            isActive = false
            log.info(.audioSession, "Sesión de audio desactivada")
            refreshSnapshot()
        } catch {
            log.error(.audioSession, "Error al desactivar la sesión: \(error.localizedDescription)")
        }
    }

    // MARK: - Snapshot de rutas

    func refreshSnapshot() {
        var snap = AudioRouteSnapshot()
        let route = session.currentRoute

        snap.currentInputs = route.inputs.map { portDescription($0) }
        snap.currentOutputs = route.outputs.map { portDescription($0) }
        snap.availableInputs = (session.availableInputs ?? []).map { portDescription($0) }
        snap.sampleRate = session.sampleRate
        snap.inputChannels = session.inputNumberOfChannels
        snap.outputChannels = session.outputNumberOfChannels
        snap.ioBufferDuration = session.ioBufferDuration
        snap.category = session.category.rawValue
        snap.mode = session.mode.rawValue
        snap.isOtherAudioPlaying = session.isOtherAudioPlaying

        self.snapshot = snap
        evaluateSimultaneousRoutes(from: snap)
    }

    private func portDescription(_ port: AVAudioSessionPortDescription) -> AudioRouteSnapshot.Port {
        let bt = Self.bluetoothPortTypes.contains(port.portType)
        let channels = port.channels?.count ?? 0
        return AudioRouteSnapshot.Port(
            portName: port.portName,
            portType: port.portType.rawValue,
            channels: channels,
            isBluetooth: bt
        )
    }

    private static let bluetoothPortTypes: Set<AVAudioSession.Port> = [
        .bluetoothHFP, .bluetoothA2DP, .bluetoothLE
    ]

    // MARK: - Evaluación experimental (FASE 3)

    /// Determina, a partir de lo que iOS realmente reporta, cuántas rutas
    /// Bluetooth están activas simultáneamente. No inventa la respuesta:
    /// refleja el estado observado en este dispositivo (regla #24).
    private func evaluateSimultaneousRoutes(from snap: AudioRouteSnapshot) {
        let btInputs = snap.currentInputs.filter { $0.isBluetooth }
        let btOutputs = snap.currentOutputs.filter { $0.isBluetooth }
        let names = Set((btInputs + btOutputs).map { $0.portName })

        let detail = "In BT: \(btInputs.map { $0.portName }.joined(separator: ", ").ifEmpty("ninguno")); " +
                     "Out BT: \(btOutputs.map { $0.portName }.joined(separator: ", ").ifEmpty("ninguno"))"

        if names.count >= 2 {
            verdict = .multipleBluetoothRoutesObserved(detail: detail)
            log.warning(.audioRoute, "Múltiples rutas BT observadas: \(detail)")
        } else if names.count == 1 {
            verdict = .singleBluetoothRoute(detail: detail)
            log.info(.audioRoute, "Ruta BT única: \(detail)")
        } else {
            verdict = .notEvaluated
        }
    }

    // MARK: - Notificaciones

    private func registerNotifications() {
        let nc = NotificationCenter.default

        let routeObs = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }

        let interruptObs = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }

        observers = [routeObs, interruptObs]
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else {
            return
        }
        let text = Self.routeChangeReasonText(reason)
        lastRouteChangeReason = text
        log.info(.audioRoute, "Cambio de ruta: \(text)")
        refreshSnapshot()
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else {
            return
        }
        switch type {
        case .began:
            lastInterruption = "Comenzó (\(Self.now()))"
            log.warning(.interruption, "Interrupción de audio: comenzó")
            isActive = false
        case .ended:
            lastInterruption = "Terminó (\(Self.now()))"
            log.info(.interruption, "Interrupción de audio: terminó")
            // No reactivamos automáticamente aquí; lo decide la capa superior.
        @unknown default:
            break
        }
        refreshSnapshot()
    }

    private static func routeChangeReasonText(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: return "Desconocido"
        case .newDeviceAvailable: return "Nuevo dispositivo disponible"
        case .oldDeviceUnavailable: return "Dispositivo desconectado"
        case .categoryChange: return "Cambio de categoría"
        case .override: return "Override"
        case .wakeFromSleep: return "Despertar"
        case .noSuitableRouteForCategory: return "Sin ruta adecuada para la categoría"
        case .routeConfigurationChange: return "Cambio de configuración de ruta"
        @unknown default: return "Otro"
        }
    }

    private static func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
