import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Puente de conectividad con el Apple Watch (lado iPhone).
///
/// El Apple Watch NO transporta audio del bridge (watchOS no lo permite, ver
/// KNOWN_LIMITATIONS L11). Su rol es ser un **botón de push-to-talk remoto**:
/// cuando el piloto mantiene el botón en la muñeca, el Watch envía un mensaje
/// y el iPhone activa/desactiva la transmisión. El audio sigue en el iPhone.
final class WatchBridge: NSObject, ObservableObject {

    /// Se invoca cuando el Watch pide transmitir (true) o soltar (false).
    var onPTTChange: ((Bool) -> Void)?

    @Published private(set) var isReachable = false

    private let log = Logger.shared

    override init() {
        super.init()
        activate()
    }

    private func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else {
            log.info(.general, "WatchConnectivity no soportado en este dispositivo")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        log.info(.general, "WatchConnectivity activándose (iPhone)")
        #endif
    }

    /// Envía el estado actual al Watch (para reflejar conexión, etc.).
    func sendStateToWatch(connected: Bool) {
        #if canImport(WatchConnectivity)
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let payload: [String: Any] = ["connected": connected]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            try? session.updateApplicationContext(payload)
        }
        #endif
    }
}

#if canImport(WatchConnectivity)
extension WatchBridge: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.isReachable = session.isReachable }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isReachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Comando de PTT desde el Watch.
        if let ptt = message["ptt"] as? Bool {
            log.info(.bridge, "Watch PTT: \(ptt ? "ON" : "OFF")")
            DispatchQueue.main.async { self.onPTTChange?(ptt) }
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // Reactivar para futuros emparejamientos de Watch.
        WCSession.default.activate()
    }
    #endif
}
#endif
