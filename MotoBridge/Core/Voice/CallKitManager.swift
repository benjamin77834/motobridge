import Foundation
import CallKit
import AVFoundation

/// Integra el bridge con CallKit para que iOS trate la sesión como una llamada
/// telefónica real. Esto es lo que activa el micrófono HFP de intercoms (como el
/// FreedConn T-COM VB) que solo lo habilitan en contexto de llamada.
///
/// Flujo:
///  - startCall(): reporta una llamada saliente/activa → iOS activa el audio de
///    llamada y señala HFP al accesorio Bluetooth.
///  - endCall(): termina la llamada.
///
/// El provider notifica cuándo activar/desactivar la AVAudioSession mediante
/// callbacks, para que el motor de audio arranque en el momento correcto.
final class CallKitManager: NSObject {

    static let shared = CallKitManager()

    private let provider: CXProvider
    private let callController = CXCallController()
    private var currentCallID: UUID?

    /// El sistema pide activar el audio (arrancar el engine aquí).
    var onActivateAudio: (() -> Void)?
    /// El sistema pide desactivar el audio.
    var onDeactivateAudio: (() -> Void)?
    /// El usuario terminó la llamada desde la UI de iOS (colgar).
    var onEndedByUser: (() -> Void)?

    private let log = Logger.shared

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Inicia una "llamada" para el bridge. `peerName` aparece en la UI de iOS.
    func startCall(peerName: String) {
        let id = UUID()
        currentCallID = id
        let handle = CXHandle(type: .generic, value: peerName)
        let startAction = CXStartCallAction(call: id, handle: handle)
        let transaction = CXTransaction(action: startAction)
        callController.request(transaction) { [weak self] error in
            if let error {
                self?.log.error(.bridge, "CallKit start error: \(error.localizedDescription)")
            } else {
                self?.log.info(.bridge, "CallKit: llamada iniciada (\(peerName))")
                // Reportar conectada de inmediato (el bridge no "suena").
                self?.provider.reportOutgoingCall(with: id, connectedAt: Date())
            }
        }
    }

    /// Termina la llamada del bridge.
    func endCall() {
        guard let id = currentCallID else { return }
        let endAction = CXEndCallAction(call: id)
        let transaction = CXTransaction(action: endAction)
        callController.request(transaction) { [weak self] error in
            if let error {
                self?.log.error(.bridge, "CallKit end error: \(error.localizedDescription)")
            }
            self?.currentCallID = nil
        }
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        currentCallID = nil
        onDeactivateAudio?()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Configuramos la AVAudioSession ANTES de cumplir, como pide CallKit.
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onEndedByUser?()
        onDeactivateAudio?()
        currentCallID = nil
        action.fulfill()
    }

    // iOS activa la sesión de audio en el momento correcto para la llamada.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        log.info(.audioSession, "CallKit: audio activado por el sistema")
        onActivateAudio?()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        log.info(.audioSession, "CallKit: audio desactivado por el sistema")
        onDeactivateAudio?()
    }
}
