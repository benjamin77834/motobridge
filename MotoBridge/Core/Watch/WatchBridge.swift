import Foundation
import Combine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Puente de conectividad con el Apple Watch (lado iPhone).
///
/// El Apple Watch es solo un control remoto: manda comandos (micrófono, alarma,
/// iniciar/detener) y muestra el estado. NO transporta audio. El iPhone es la
/// fuente de verdad: publica el estado completo cada vez que algo cambia.
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private let log = Logger.shared
    private var handler: WatchCommandHandler?
    private var cancellable: AnyCancellable?
    private var lastContextWarning = Date.distantPast

    private override init() {
        super.init()
    }

    /// Activa la sesión. Barato: no toca micrófono ni audio.
    func activate() {
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

    /// Conecta el controlador (idempotente). Lo llama el `init` del controlador.
    func attach(_ controller: NetworkBridgeController) {
        guard handler == nil else { return }
        handler = WatchCommandHandler(bridge: controller)
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        cancellable = Publishers.CombineLatest4(
            controller.$isRunning, controller.$isTransmitting,
            controller.$alarmActive, controller.$connectedPeers
        )
        .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] _ in self?.publishState() }
        #endif
    }

    #if canImport(WatchConnectivity)
    /// Publica el estado: contexto siempre; más `sendMessage` si el reloj es alcanzable.
    private func publishState() {
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled,
              let handler else { return }
        let payload = handler.makeState().dictionary
        do {
            try session.updateApplicationContext(payload)
        } catch {
            if Date().timeIntervalSince(lastContextWarning) > 60 {
                lastContextWarning = Date()
                log.warning(.general, "Watch: updateApplicationContext falló: \(error.localizedDescription)")
            }
        }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { [weak self] error in
                self?.log.debug(.general, "Watch: sendMessage de estado falló: \(error.localizedDescription)")
            }
        }
    }
    #endif
}

#if canImport(WatchConnectivity)
extension WatchBridge: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            log.error(.general, "Watch: activación fallida: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.async { self.publishState() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.publishState() }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.publishState() }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        log.warning(.bridge, "Watch: mensaje sin replyHandler ignorado")
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            // Si el controlador aún no existe (app lanzada en segundo plano),
            // crearlo aquí lo crea y llama a `attach`.
            if self.handler == nil { _ = NetworkBridgeController.shared }
            guard let handler = self.handler else {
                replyHandler(WatchReply(ok: false, err: .internal, note: nil, state: nil).dictionary)
                return
            }
            handler.handle(message, completion: replyHandler)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Reactivar para futuros emparejamientos de Watch.
        WCSession.default.activate()
    }
}
#endif
