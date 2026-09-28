import Foundation

/// Relay de malla (mesh) multi-salto: cada dispositivo reenvía a sus vecinos el
/// audio que recibe de otros, extendiendo el alcance encadenando motos.
///
/// Cabecera de mesh (se antepone al payload de audio):
///   bytes 0..3 : originId  (UInt32, identifica al emisor original)
///   bytes 4..7 : packetId  (UInt32, único por paquete de ese origen)
///   byte  8    : ttl       (saltos restantes; 0 = no reenviar)
///   bytes 9..N : payload   (paquete de audio: cabecera de códec + datos)
///
/// Deduplicación: cada (originId, packetId) se procesa una sola vez, evitando
/// bucles y reenvíos duplicados en la malla.
final class MeshRelay {
    static let headerSize = 9
    static let defaultTTL: UInt8 = 3

    /// ID de este dispositivo (aleatorio por sesión).
    let localOriginId: UInt32 = UInt32.random(in: 1...UInt32.max)
    private var nextPacketId: UInt32 = 0

    /// Cache de paquetes ya vistos (origin<<32 | packet) para deduplicar.
    private var seen = Set<UInt64>()
    private var seenOrder: [UInt64] = []
    private let maxSeen = 2048
    private let lock = NSLock()

    /// Envuelve un payload propio con cabecera de mesh nueva (para enviar).
    func wrapOutgoing(_ payload: Data, ttl: UInt8 = MeshRelay.defaultTTL) -> Data {
        lock.lock(); defer { lock.unlock() }
        nextPacketId &+= 1
        markSeen(origin: localOriginId, packet: nextPacketId) // no reprocesar lo propio
        return Self.pack(origin: localOriginId, packet: nextPacketId, ttl: ttl, payload: payload)
    }

    /// Resultado de procesar un paquete entrante.
    struct Incoming {
        let payload: Data          // audio a reproducir (si isNew)
        let isNew: Bool            // ¿procesar/reproducir?
        let relay: Data?           // paquete a reenviar a otros vecinos (o nil)
    }

    /// Procesa un paquete recibido: decide si reproducirlo y si reenviarlo.
    func processIncoming(_ data: Data) -> Incoming? {
        guard data.count > Self.headerSize else { return nil }
        let (origin, packet, ttl, payload) = Self.unpack(data)

        lock.lock(); defer { lock.unlock() }
        let key = (UInt64(origin) << 32) | UInt64(packet)
        if seen.contains(key) {
            return Incoming(payload: payload, isNew: false, relay: nil) // ya visto
        }
        markSeen(origin: origin, packet: packet)

        // Reenviar si aún quedan saltos.
        var relay: Data? = nil
        if ttl > 1 {
            relay = Self.pack(origin: origin, packet: packet, ttl: ttl - 1, payload: payload)
        }
        return Incoming(payload: payload, isNew: true, relay: relay)
    }

    private func markSeen(origin: UInt32, packet: UInt32) {
        let key = (UInt64(origin) << 32) | UInt64(packet)
        seen.insert(key)
        seenOrder.append(key)
        if seenOrder.count > maxSeen {
            let old = seenOrder.removeFirst()
            seen.remove(old)
        }
    }

    // MARK: - Serialización

    private static func pack(origin: UInt32, packet: UInt32, ttl: UInt8, payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        var o = origin.bigEndian, p = packet.bigEndian
        withUnsafeBytes(of: &o) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &p) { out.append(contentsOf: $0) }
        out.append(ttl)
        out.append(payload)
        return out
    }

    private static func unpack(_ data: Data) -> (UInt32, UInt32, UInt8, Data) {
        let b = [UInt8](data)
        let origin = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        let packet = (UInt32(b[4]) << 24) | (UInt32(b[5]) << 16) | (UInt32(b[6]) << 8) | UInt32(b[7])
        let ttl = b[8]
        let payload = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        return (origin, packet, ttl, payload)
    }
}
