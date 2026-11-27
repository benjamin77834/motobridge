import Foundation
import WatchConnectivity

/// Resultado de una operación iniciada en el reloj.
enum Op: Equatable {
    case idle
    case pending
    case done(String?)
    case failed(String)
}

/// Modelo del reloj: muestra el último estado publicado por el iPhone (fuente
/// de verdad) y envía comandos. Ningún botón escribe `state`: solo `apply`.
@MainActor
final class WatchRemoteModel: NSObject, ObservableObject {
    @Published private(set) var state: WatchState?
    @Published private(set) var reachable = false
    @Published private(set) var controlOp: Op = .idle
    @Published private(set) var alarmOp: Op = .idle
    @Published private(set) var refreshing = false

    private var store = WatchStateStore()
    private let commandTimeout: TimeInterval = 5

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        updateReachable()
    }

    // MARK: - Acciones

    func refresh() {
        guard reachable else { refreshing = false; return }
        refreshing = true
        transmit(WatchCommand(kind: .getState, id: "", open: nil), resetFloor: true) { [weak self] _ in
            self?.refreshing = false
        }
    }

    func setMic(_ open: Bool) {
        runControl(WatchCommand(kind: .setMic, id: UUID().uuidString, open: open))
    }

    func startBridge() { runControl(WatchCommand(kind: .startBridge, id: UUID().uuidString, open: nil)) }
    func stopBridge() { runControl(WatchCommand(kind: .stopBridge, id: UUID().uuidString, open: nil)) }

    /// Alarma: solo `sendMessage`, sin cola ni reintento automático.
    func sendAlarm() {
        guard alarmOp != .pending else { return }
        alarmOp = .pending
        transmit(WatchCommand(kind: .alarm, id: UUID().uuidString, open: nil)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.alarmOp = .done(nil)
                Haptics.success()
                self.scheduleAlarmReset()
            case .failure(let reason):
                self.alarmOp = .failed(reason.text)
                Haptics.failure()
            }
        }
    }

    func dismissAlarmResult() {
        if alarmOp != .pending { alarmOp = .idle }
    }

    private func scheduleAlarmReset() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .done = self?.alarmOp { self?.alarmOp = .idle }
        }
    }

    private func runControl(_ cmd: WatchCommand) {
        guard controlOp != .pending else { return }
        controlOp = .pending
        transmit(cmd) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.controlOp = .done(nil)
                Haptics.success()
            case .failure(let reason):
                self.controlOp = .failed(reason.text)
                Haptics.failure()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if self?.controlOp != .pending { self?.controlOp = .idle }
            }
        }
    }

    // MARK: - Envío

    /// Evita completar dos veces (respuesta vs. temporizador).
    private final class Once { var done = false }

    private func transmit(_ cmd: WatchCommand, resetFloor: Bool = false,
                          completion: @escaping (Result<Void, FailureReason>) -> Void) {
        guard reachable else {
            completion(.failure(FailureReason("iPhone no alcanzable")))
            return
        }
        let once = Once()
        let finish: (Result<Void, FailureReason>) -> Void = { result in
            guard !once.done else { return }
            once.done = true
            completion(result)
        }
        WCSession.default.sendMessage(cmd.message, replyHandler: { [weak self] dict in
            Task { @MainActor in
                guard let self else { return }
                guard let reply = WatchReply.parse(dict) else {
                    finish(.failure(FailureReason("Respuesta inválida")))
                    return
                }
                // Se aplica siempre, aunque la pantalla ya haya dado timeout.
                if let s = reply.state { self.apply(s, resetFloor: resetFloor) }
                if reply.ok {
                    finish(.success(()))
                } else {
                    finish(.failure(FailureReason(Self.message(for: reply.err))))
                }
            }
        }, errorHandler: { error in
            Task { @MainActor in
                finish(.failure(FailureReason(Self.describe(error))))
            }
        })
        Task { @MainActor [commandTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(commandTimeout * 1_000_000_000))
            finish(.failure(FailureReason("Sin confirmación. Revisa el iPhone")))
        }
    }

    struct FailureReason: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    private static func message(for err: WatchErrorCode?) -> String {
        switch err {
        case .notRunning: return "Bridge detenido"
        case .needsPhone: return "Abre Mono Bridge en el iPhone"
        case .badRequest, .unsupportedVersion: return "Actualiza la app del reloj o del iPhone"
        case .internal, .none: return "Error en el iPhone"
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? WCError, e.code == .notReachable { return "iPhone no alcanzable" }
        return "No se pudo enviar"
    }

    // MARK: - Estado

    /// Único punto que escribe `state`.
    private func apply(_ s: WatchState, resetFloor: Bool = false) {
        if store.apply(s, resetFloor: resetFloor) { state = store.current }
    }

    private func updateReachable() {
        let session = WCSession.default
        reachable = session.activationState == .activated && session.isReachable
    }
}

extension WatchRemoteModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let ctx = session.receivedApplicationContext
        Task { @MainActor in
            self.updateReachable()
            if let s = WatchState.parse(ctx) { self.apply(s) }
            self.refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.updateReachable()
            if self.reachable { self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let s = WatchState.parse(applicationContext) else { return }
        Task { @MainActor in self.apply(s) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let s = WatchState.parse(message) else { return }
        Task { @MainActor in self.apply(s) }
    }
}
