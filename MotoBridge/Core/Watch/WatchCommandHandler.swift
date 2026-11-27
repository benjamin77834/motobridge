import Foundation
import AVFoundation
import UIKit

/// Lo que el Watch puede pedirle al bridge. `NetworkBridgeController` lo
/// implementa (abajo) y las pruebas usan un doble.
protocol BridgeControlling: AnyObject {
    var isRunning: Bool { get }
    var isTransmitting: Bool { get }
    var alarmActive: Bool { get }
    var connectedPeerNames: [String] { get }
    var canStartRemotely: Bool { get }
    func setMic(_ open: Bool)
    func triggerAlarm()
    func startBridge()
    func stopBridge()
}

/// Valida y ejecuta comandos del reloj sobre el bridge. Se usa siempre en el
/// hilo principal.
final class WatchCommandHandler {
    private let bridge: BridgeControlling
    private let log = Logger.shared
    private var lastSeq = 0
    /// Últimos 16 comandos vistos; `nil` = en ejecución aún sin respuesta.
    private var seen: [(id: String, reply: [String: Any]?)] = []
    private let maxSeen = 16
    private let now: () -> Date

    init(bridge: BridgeControlling, now: @escaping () -> Date = Date.init) {
        self.bridge = bridge
        self.now = now
    }

    /// Estado actual, con `seq` estrictamente creciente dentro del proceso.
    func makeState() -> WatchState {
        let ms = Int(now().timeIntervalSince1970 * 1000)
        lastSeq = max(lastSeq + 1, ms)
        let names = bridge.connectedPeerNames
        return WatchState(seq: lastSeq,
                          running: bridge.isRunning,
                          mic: bridge.isTransmitting,
                          alarm: bridge.alarmActive,
                          peerCount: names.count,
                          peerNames: names,
                          canStart: bridge.canStartRemotely)
    }

    /// Procesa un mensaje. `completion` se llama en el hilo principal, en un
    /// salto de cola posterior a la acción para que el estado incluya su efecto
    /// (`setTransmitting` actualiza `isTransmitting` con su propio `main.async`).
    func handle(_ message: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        let cmd: WatchCommand
        switch WatchCommand.parse(message) {
        case .failure(let code):
            let name = (message[WatchKey.cmd] as? String) ?? "?"
            log.warning(.bridge, "Watch: comando inválido (\(name)): \(code.rawValue)")
            completion(WatchReply(ok: false, err: code, note: nil, state: makeState()).dictionary)
            return
        case .success(let c):
            cmd = c
        }

        if cmd.kind != .getState {
            if let idx = seen.firstIndex(where: { $0.id == cmd.id }) {
                log.debug(.bridge, "Watch: comando duplicado \(cmd.kind.rawValue)")
                let saved = seen[idx].reply
                    ?? WatchReply(ok: true, err: nil, note: .noChange, state: makeState()).dictionary
                completion(saved)
                return
            }
            seen.append((cmd.id, nil))
            if seen.count > maxSeen { seen.removeFirst() }
        }

        var err: WatchErrorCode?
        var note: WatchNote?
        switch cmd.kind {
        case .getState:
            break
        case .setMic:
            let open = cmd.open ?? false
            if open && !bridge.isRunning {
                err = .notRunning
            } else if bridge.isTransmitting == open {
                note = .noChange
            } else {
                bridge.setMic(open)
            }
        case .alarm:
            if !bridge.isRunning {
                err = .notRunning
            } else if bridge.alarmActive {
                note = .alreadyActive
            } else {
                bridge.triggerAlarm()
            }
        case .startBridge:
            if bridge.isRunning {
                note = .noChange
            } else if !bridge.canStartRemotely {
                err = .needsPhone
            } else {
                bridge.startBridge()
            }
        case .stopBridge:
            if !bridge.isRunning {
                note = .noChange
            } else {
                bridge.stopBridge()
            }
        }
        if let err { log.info(.bridge, "Watch: \(cmd.kind.rawValue) rechazado: \(err.rawValue)") }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let reply = WatchReply(ok: err == nil, err: err, note: note, state: self.makeState()).dictionary
            if cmd.kind != .getState, let idx = self.seen.firstIndex(where: { $0.id == cmd.id }) {
                self.seen[idx].reply = reply
            }
            completion(reply)
        }
    }
}

extension NetworkBridgeController: BridgeControlling {
    var connectedPeerNames: [String] { connectedPeers.map(\.name) }

    /// Iniciar desde el reloj solo es seguro con permiso de micrófono concedido
    /// y la app en primer plano activa (el diálogo de permiso solo se contesta
    /// en el iPhone y el audio no debe arrancar en frío en segundo plano).
    var canStartRemotely: Bool {
        AVAudioApplication.shared.recordPermission == .granted
            && UIApplication.shared.applicationState == .active
    }

    func setMic(_ open: Bool) { setTransmitting(open) }
    func triggerAlarm() { sendAlarm() }
    func startBridge() { start() }
    func stopBridge() { stop() }
}
