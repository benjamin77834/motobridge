import Foundation

/// Protocolo entre el iPhone y el Apple Watch (WatchConnectivity).
/// Archivo compartido por los targets MotoBridge (iPhone) y MotoBridgeWatch.
/// Solo usa Foundation. El iPhone es la fuente de verdad del estado.

enum WatchKey {
    static let version = "v"
    static let cmd = "cmd"
    static let id = "id"
    static let open = "open"
    static let ok = "ok"
    static let err = "err"
    static let note = "note"
    static let state = "state"
    static let seq = "seq"
    static let running = "running"
    static let mic = "mic"
    static let alarm = "alarm"
    static let peerCount = "peerCount"
    static let peers = "peers"
    static let canStart = "canStart"
}

enum WatchProtocolInfo {
    static let version = 1
    static let maxPeerNames = 8
    static let maxNameLength = 24
    static let maxIdLength = 64
}

/// Códigos de error de una respuesta (`err`).
enum WatchErrorCode: String, Error {
    case notRunning, needsPhone, badRequest, unsupportedVersion, `internal`
}

/// Notas de una respuesta exitosa (`note`).
enum WatchNote: String {
    case alreadyActive, noChange
}

// MARK: - Comando (reloj -> iPhone)

struct WatchCommand: Equatable {
    enum Kind: String {
        case getState, setMic, alarm, startBridge, stopBridge
    }

    let kind: Kind
    /// Identificador del comando (vacío en `getState`).
    let id: String
    /// Solo en `setMic`.
    let open: Bool?

    /// Valida un mensaje recibido. Las claves desconocidas se ignoran.
    static func parse(_ message: [String: Any]) -> Result<WatchCommand, WatchErrorCode> {
        guard let v = message[WatchKey.version] as? Int, v == WatchProtocolInfo.version else {
            return .failure(.unsupportedVersion)
        }
        guard let raw = message[WatchKey.cmd] as? String, let kind = Kind(rawValue: raw) else {
            return .failure(.badRequest)
        }
        var id = ""
        if kind != .getState {
            guard let s = message[WatchKey.id] as? String,
                  (1...WatchProtocolInfo.maxIdLength).contains(s.count) else {
                return .failure(.badRequest)
            }
            id = s
        }
        var open: Bool?
        if kind == .setMic {
            guard let b = message[WatchKey.open] as? Bool else { return .failure(.badRequest) }
            open = b
        }
        return .success(WatchCommand(kind: kind, id: id, open: open))
    }

    /// Diccionario listo para `sendMessage`.
    var message: [String: Any] {
        var m: [String: Any] = [WatchKey.version: WatchProtocolInfo.version, WatchKey.cmd: kind.rawValue]
        if kind != .getState { m[WatchKey.id] = id }
        if let open { m[WatchKey.open] = open }
        return m
    }
}

// MARK: - Estado (iPhone -> reloj)

struct WatchState: Equatable {
    var seq: Int
    var running: Bool
    var mic: Bool
    var alarm: Bool
    var peerCount: Int
    var peers: [String]
    var canStart: Bool

    /// Saneado de nombres de la red: sin caracteres de control, <= 24 caracteres,
    /// vacío -> "Rider", máximo 8 nombres.
    static func sanitize(names: [String]) -> [String] {
        names.prefix(WatchProtocolInfo.maxPeerNames).map { name in
            let clean = String(String.UnicodeScalarView(name.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            })).trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { return "Rider" }
            return String(clean.prefix(WatchProtocolInfo.maxNameLength))
        }
    }

    init(seq: Int, running: Bool, mic: Bool, alarm: Bool, peerCount: Int, peerNames: [String], canStart: Bool) {
        self.seq = seq
        self.running = running
        self.mic = mic
        self.alarm = alarm
        self.peerCount = peerCount
        self.peers = WatchState.sanitize(names: peerNames)
        self.canStart = canStart
    }

    var dictionary: [String: Any] {
        [
            WatchKey.version: WatchProtocolInfo.version,
            WatchKey.seq: seq,
            WatchKey.running: running,
            WatchKey.mic: mic,
            WatchKey.alarm: alarm,
            WatchKey.peerCount: peerCount,
            WatchKey.peers: peers,
            WatchKey.canStart: canStart,
        ]
    }

    /// Devuelve nil si el diccionario no es un estado válido (se descarta).
    static func parse(_ d: [String: Any]) -> WatchState? {
        guard let v = d[WatchKey.version] as? Int, v == WatchProtocolInfo.version,
              let seq = d[WatchKey.seq] as? Int,
              let running = d[WatchKey.running] as? Bool,
              let mic = d[WatchKey.mic] as? Bool,
              let alarm = d[WatchKey.alarm] as? Bool,
              let count = d[WatchKey.peerCount] as? Int, count >= 0,
              let peers = d[WatchKey.peers] as? [String],
              peers.count <= WatchProtocolInfo.maxPeerNames,
              let canStart = d[WatchKey.canStart] as? Bool else { return nil }
        return WatchState(seq: seq, running: running, mic: mic, alarm: alarm,
                          peerCount: count, peerNames: peers, canStart: canStart)
    }
}

/// Guarda el último estado aplicado y descarta los más viejos.
struct WatchStateStore {
    private(set) var current: WatchState?

    /// Aplica `state` si su `seq` es mayor que el actual. Con `resetFloor`
    /// (respuesta a `getState`) se aplica siempre, para recuperarse si el
    /// iPhone reinició con un `seq` menor. Devuelve si se aplicó.
    @discardableResult
    mutating func apply(_ state: WatchState, resetFloor: Bool = false) -> Bool {
        if !resetFloor, let cur = current, state.seq <= cur.seq { return false }
        current = state
        return true
    }
}

// MARK: - Respuesta (iPhone -> reloj)

struct WatchReply: Equatable {
    var ok: Bool
    var err: WatchErrorCode?
    var note: WatchNote?
    var state: WatchState?

    var dictionary: [String: Any] {
        var d: [String: Any] = [WatchKey.version: WatchProtocolInfo.version, WatchKey.ok: ok]
        if let err { d[WatchKey.err] = err.rawValue }
        if let note { d[WatchKey.note] = note.rawValue }
        if let state { d[WatchKey.state] = state.dictionary }
        return d
    }

    static func parse(_ d: [String: Any]) -> WatchReply? {
        guard let ok = d[WatchKey.ok] as? Bool else { return nil }
        let err = (d[WatchKey.err] as? String).flatMap(WatchErrorCode.init(rawValue:))
        let note = (d[WatchKey.note] as? String).flatMap(WatchNote.init(rawValue:))
        let state = (d[WatchKey.state] as? [String: Any]).flatMap(WatchState.parse)
        return WatchReply(ok: ok, err: err, note: note, state: state)
    }
}
