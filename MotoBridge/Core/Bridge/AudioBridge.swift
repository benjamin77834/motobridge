import Foundation
import Combine

/// Estados del puente de audio (sección 8).
enum BridgeState: String {
    case idle = "Inactivo"
    case initializing = "Inicializando"
    case ready = "Listo"
    case bridging = "Puenteando"
    case paused = "Pausado"
    case error = "Error"
}

/// Motivo por el que el bridge directo Bluetooth↔Bluetooth no está disponible.
/// Refleja la conclusión del FEASIBILITY_REPORT (RED para BT↔BT en un solo iPhone).
enum BridgeUnavailabilityReason {
    case none
    case iosDoesNotAllowDualBluetoothRoutes
    case routeUnavailable
    case deviceDisconnected

    var userMessage: String? {
        switch self {
        case .none:
            return nil
        case .iosDoesNotAllowDualBluetoothRoutes:
            return "El sistema operativo no permite esta configuración de audio Bluetooth."
        case .routeUnavailable:
            return "Ruta de audio no disponible."
        case .deviceDisconnected:
            return "Dispositivo desconectado."
        }
    }
}

/// Abstracción del puente de audio (sección 8).
///
/// NOTA HONESTA (FASE 0/1): el bridge directo Bluetooth↔Bluetooth en un solo
/// iPhone NO es viable con APIs públicas (ver FEASIBILITY_REPORT). Esta clase
/// mantiene la máquina de estados y expone la limitación de forma explícita en
/// lugar de simular un bridge que no existe. La implementación real del bridge
/// se hará por red entre dos iPhones (Alternativa A) en una fase posterior.
final class AudioBridge: ObservableObject {
    @Published private(set) var state: BridgeState = .idle
    @Published private(set) var unavailabilityReason: BridgeUnavailabilityReason = .none

    private let log = Logger.shared

    func prepare() {
        state = .initializing
        log.info(.bridge, "Preparando bridge…")

        // Con el hardware objetivo (dos intercoms Bluetooth Classic) y un solo
        // iPhone, iOS no permite dos rutas de audio BT simultáneas. No simulamos
        // un estado "ready" falso.
        state = .error
        unavailabilityReason = .iosDoesNotAllowDualBluetoothRoutes
        log.warning(.bridge, "Bridge BT↔BT no disponible: iOS no permite dos rutas Bluetooth de audio simultáneas.")
    }

    func stop() {
        state = .idle
        unavailabilityReason = .none
        log.info(.bridge, "Bridge detenido.")
    }
}
