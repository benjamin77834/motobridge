import Foundation

/// Versión y capacidades de protocolo anunciadas en la presencia.
/// Spec `protocol-capabilities-baseline`. Foundation puro: se compila también
/// en el target Mac Relay. Mismo formato y mismas reglas que
/// `android/.../net/PeerCapabilities.kt`.
///
/// Payload de presencia (UTF-8, separador "\n"):
///   <nombre>\n[ALT=..]\n[BAT=..]\nPV=<n>\nID=<8 hex>\nCAP=<a,b,c>
/// La primera línea no cambia; los lectores viejos ignoran las demás.
enum PresenceCodec {
    static let protocolVersion = 2
    /// Más de esto se descarta sin error (R2.3).
    static let maxPayloadBytes = 512

    /// Tokens que este build puede anunciar. Vacío salvo `TEST` en depuración (R5.2).
    static var localCapabilities: [String] {
        #if DEBUG
        return ["TEST"]
        #else
        return []
        #endif
    }

    struct Parsed: Equatable {
        var name: String
        var alt: Double?
        var bat: Int?
        /// nil = sin línea `PV` válida (protocolo 1, legacy).
        var pv: Int?
        var originId: UInt32?
        var caps: Set<String>
        var isLegacy: Bool { pv == nil }
    }

    enum ParseResult: Equatable {
        case ok(Parsed)
        case oversize
        case invalid
    }

    static func idString(_ id: UInt32) -> String { String(format: "%08X", id) }

    /// Líneas nuevas (PV, ID, CAP) para añadir tras el nombre y los campos de rescate.
    static func capabilityLines(originId: UInt32, caps: [String] = PresenceCodec.localCapabilities) -> String {
        "PV=\(protocolVersion)\nID=\(idString(originId))\nCAP=\(caps.joined(separator: ","))"
    }

    static func parse(_ payload: Data) -> ParseResult {
        guard payload.count <= maxPayloadBytes else { return .oversize }
        let rows = payload.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard let firstRow = rows.first,
              let name = String(data: Data(firstRow), encoding: .utf8), !name.isEmpty
        else { return .invalid }
        var p = Parsed(name: name, alt: nil, bat: nil, pv: nil, originId: nil, caps: [])
        for row in rows.dropFirst() {
            // Líneas que no son UTF-8 se ignoran (R2.2).
            guard let line = String(data: Data(row), encoding: .utf8) else { continue }
            if line.hasPrefix("ALT=") { p.alt = Double(line.dropFirst(4)) }
            else if line.hasPrefix("BAT=") { p.bat = Int(line.dropFirst(4)) }
            else if line.hasPrefix("PV=") { p.pv = Int(line.dropFirst(3)) }
            else if line.hasPrefix("ID=") {
                let hex = String(line.dropFirst(3))
                if hex.count == 8, let v = UInt32(hex, radix: 16) { p.originId = v }
            } else if line.hasPrefix("CAP=") {
                p.caps = Set(line.dropFirst(4).split(separator: ",").map { String($0) }
                    .filter { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
            }
        }
        return .ok(p)
    }
}

/// Tabla en memoria de capacidades por vecino directo y por origen.
final class CapabilityTable {
    static let maxOrigins = 32
    static let maxNeighbors = 5
    static let originTTL: TimeInterval = 30

    struct Entry: Equatable {
        var pv: Int
        var caps: Set<String>
        var lastSeen: Date
    }

    private var neighbors: [String: Entry] = [:]
    private var origins: [UInt32: Entry] = [:]
    private let lock = NSLock()
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    /// Registra una presencia. `neighborId` es el vecino directo por el que llegó;
    /// solo se enlaza al vecino cuando la presencia es de ese mismo vecino (`direct`).
    func update(neighborId: String, parsed: PresenceCodec.Parsed, direct: Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        let entry = Entry(pv: parsed.pv ?? 1, caps: parsed.caps, lastSeen: now)
        if direct {
            if neighbors[neighborId] != nil || neighbors.count < Self.maxNeighbors {
                neighbors[neighborId] = entry
            }
        }
        if let id = parsed.originId {
            pruneOrigins(now)
            if origins[id] != nil || origins.count < Self.maxOrigins {
                origins[id] = entry   // gana la más reciente (R4.5)
            }
        }
    }

    /// Quita vecinos que ya no están conectados (R4.3).
    func retainNeighbors(_ connectedIds: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        neighbors = neighbors.filter { connectedIds.contains($0.key) }
    }

    func removeNeighbor(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        neighbors[id] = nil
    }

    func protocolVersion(neighbor id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return neighbors[id]?.pv ?? 1
    }

    func neighborSupports(_ id: String, _ cap: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return neighbors[id]?.caps.contains(cap) ?? false
    }

    /// ¿Todos los vecinos conectados soportan `cap`? Un vecino sin presencia cuenta como legacy.
    func allNeighborsSupport(_ cap: String, connected: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return connected.allSatisfy { neighbors[$0]?.caps.contains(cap) ?? false }
    }

    func originSupports(_ id: UInt32, _ cap: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneOrigins(clock())
        return origins[id]?.caps.contains(cap) ?? false
    }

    var neighborCount: Int { lock.lock(); defer { lock.unlock() }; return neighbors.count }
    var originCount: Int {
        lock.lock(); defer { lock.unlock() }
        pruneOrigins(clock())
        return origins.count
    }

    private func pruneOrigins(_ now: Date) {
        origins = origins.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.originTTL }
    }
}

/// Cuenta localmente peers legacy (sin `PV`) vistos en los últimos 14 días (R8.1).
/// Nunca sale del dispositivo. `Legacy*`: se borra al retirar la compatibilidad.
final class LegacyPeerCounter {
    static let windowDays = 14
    /// Instancia local persistida en UserDefaults (nada sale del dispositivo).
    static let shared: LegacyPeerCounter = {
        let key = "legacyPeerSightings"
        let stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: Date]) ?? [:]
        return LegacyPeerCounter(initial: stored) { UserDefaults.standard.set($0, forKey: key) }
    }()
    private var sightings: [String: Date]
    private let clock: () -> Date
    private let save: (([String: Date]) -> Void)?
    private let lock = NSLock()

    init(initial: [String: Date] = [:], clock: @escaping () -> Date = Date.init,
         save: (([String: Date]) -> Void)? = nil) {
        self.sightings = initial
        self.clock = clock
        self.save = save
    }

    func noteLegacy(name: String) {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        sightings[name] = now
        prune(now)
        save?(sightings)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        prune(clock())
        return sightings.count
    }

    private func prune(_ now: Date) {
        let limit = TimeInterval(Self.windowDays * 86_400)
        sightings = sightings.filter { now.timeIntervalSince($0.value) <= limit }
    }
}
