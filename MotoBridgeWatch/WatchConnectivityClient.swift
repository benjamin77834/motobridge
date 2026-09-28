import Foundation
import WatchConnectivity

/// Cliente de WatchConnectivity en el Apple Watch. Envía comandos de push-to-talk
/// al iPhone y recibe el estado de conexión del bridge.
final class WatchConnectivityClient: NSObject, ObservableObject {

    @Published private(set) var bridgeConnected = false
    @Published private(set) var phoneReachable = false

    override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    /// Envía el estado de push-to-talk al iPhone.
    func sendPTT(_ transmitting: Bool) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let payload: [String: Any] = ["ptt": transmitting]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }
}

extension WatchConnectivityClient: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.phoneReachable = session.isReachable }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.phoneReachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let connected = message["connected"] as? Bool {
            DispatchQueue.main.async { self.bridgeConnected = connected }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let connected = applicationContext["connected"] as? Bool {
            DispatchQueue.main.async { self.bridgeConnected = connected }
        }
    }
}
