import Foundation

/// Encabezado de aplicación que envuelve el audio/texto para soportar canales.
///
/// Lleva un byte MAGIC al inicio para distinguir un canal real de datos crudos o
/// de paquetes mal alineados. Si el magic no coincide, el paquete NO se trata
/// como canal (evita que ruido/paquetes raros se interpreten como alarma).
///
/// Formato clásico (6 bytes) para group/privateWhisper/alarm/text/presence:
///   byte 0     : magic (0x56 'V')
///   byte 1     : tipo
///   bytes 2..5 : targetId (UInt32 big-endian); 0 = grupo
///   bytes 6..N : payload
///
/// Formato subgroup:
///   byte 0     : magic
///   byte 1     : tipo (4)
///   byte 2     : subtipo (0 = audio, 1 = texto)
///   byte 3     : count
///   bytes 4..  : count × 4 bytes targetIds
///   resto      : payload
enum VoiceChannelType: UInt8 {
    case group = 0
    case privateWhisper = 1
    case alarm = 2
    case text = 3
    case subgroup = 4
    case presence = 5
    case ack = 6              // acuse de recibo de un mensaje de texto (targetId = nameId del receptor)
    /// "Pickup": aviso corto "X quiere conectarse". targetId = nameId del
    /// destinatario (0 = desconocido); payload = nombre del emisor en UTF-8.
    /// Apps viejas no conocen el tipo y lo descartan (ver PROTOCOL.md §9).
    case pickup = 7
}

enum VoiceChannel {
    static let magic: UInt8 = 0x56   // 'V'
    static let headerSize = 6        // magic + tipo + 4 targetId

    static func wrap(_ audio: Data, type: VoiceChannelType, targetId: UInt32) -> Data {
        var out = Data(capacity: headerSize + audio.count)
        out.append(magic)
        out.append(type.rawValue)
        var t = targetId.bigEndian
        withUnsafeBytes(of: &t) { out.append(contentsOf: $0) }
        out.append(audio)
        return out
    }

    /// Paquete pickup de `sender` hacia `targetName` (nil = destinatario sin nombre).
    static func wrapPickup(from sender: String, to targetId: UInt32) -> Data {
        wrap(Data(sender.utf8), type: .pickup, targetId: targetId)
    }

    /// Si `data` es un pickup válido, devuelve (targetId, nombre del emisor).
    static func parsePickup(_ data: Data) -> (targetId: UInt32, sender: String)? {
        guard let m = unwrap(data), m.type == .pickup,
              let name = String(data: m.audio, encoding: .utf8), !name.isEmpty else { return nil }
        return (m.targetId, name)
    }

    static func wrapSubgroup(_ payload: Data, targets: [UInt32], isText: Bool) -> Data {
        var out = Data(capacity: 4 + targets.count * 4 + payload.count)
        out.append(magic)
        out.append(VoiceChannelType.subgroup.rawValue)
        out.append(isText ? 1 : 0)
        out.append(UInt8(min(targets.count, 255)))
        for id in targets.prefix(255) {
            var t = id.bigEndian
            withUnsafeBytes(of: &t) { out.append(contentsOf: $0) }
        }
        out.append(payload)
        return out
    }

    struct Unwrapped {
        let type: VoiceChannelType
        let targetId: UInt32
        let audio: Data
        let targets: [UInt32]
        let isText: Bool
    }

    static func unwrap(_ data: Data) -> Unwrapped? {
        let b = [UInt8](data)
        // Sin magic válido NO es un canal (se tratará como audio crudo de grupo).
        guard b.count >= 2, b[0] == magic, let type = VoiceChannelType(rawValue: b[1]) else { return nil }

        if type == .subgroup {
            guard b.count > 4 else { return nil }
            let isText = b[2] == 1
            let count = Int(b[3])
            let idsStart = 4
            let payloadStart = idsStart + count * 4
            guard b.count > payloadStart else { return nil }
            var ids: [UInt32] = []
            ids.reserveCapacity(count)
            var i = idsStart
            for _ in 0..<count {
                let id = (UInt32(b[i]) << 24) | (UInt32(b[i+1]) << 16) | (UInt32(b[i+2]) << 8) | UInt32(b[i+3])
                ids.append(id); i += 4
            }
            let payload = data.subdata(in: (data.startIndex + payloadStart)..<data.endIndex)
            return Unwrapped(type: type, targetId: 0, audio: payload, targets: ids, isText: isText)
        }

        // Formato clásico (6 bytes).
        guard b.count > headerSize else { return nil }
        let target = (UInt32(b[2]) << 24) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 8) | UInt32(b[5])
        let audio = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        return Unwrapped(type: type, targetId: target, audio: audio, targets: [], isText: false)
    }
}

/// Sintetiza por código los sonidos de aviso (sin assets): devuelve un WAV PCM
/// 16-bit mono en memoria que se reproduce con AVAudioPlayer. Compartido por
/// iOS y Mac. Solo Foundation.
enum ChimeSynth {
    enum Kind {
        /// Timbre de conexión: 2 notas ascendentes suaves (~0.8 s).
        case connected
        /// Aviso de pickup: dos toques cortos tipo timbre de llamada (~0.6 s).
        case pickup
    }

    private struct Note { let freq: Double; let start: Double; let length: Double }

    static func wav(_ kind: Kind) -> Data {
        let rate = 22050.0
        let notes: [Note]
        switch kind {
        case .connected: notes = [Note(freq: 659.25, start: 0.0, length: 0.35),   // Mi5
                                  Note(freq: 987.77, start: 0.16, length: 0.6)]   // Si5
        case .pickup:    notes = [Note(freq: 783.99, start: 0.0, length: 0.25),   // Sol5
                                  Note(freq: 783.99, start: 0.28, length: 0.3)]
        }
        let total = Int((notes.map { $0.start + $0.length }.max() ?? 0.5) * rate)
        var mix = [Double](repeating: 0, count: total)
        for n in notes {
            let first = Int(n.start * rate), count = Int(n.length * rate)
            for i in 0..<count where first + i < total {
                let t = Double(i) / rate
                let attack = min(1.0, t / 0.012)                 // entrada suave (sin clic)
                let decay = exp(-t * (4.0 / n.length))           // caída natural
                let tail = min(1.0, Double(count - i) / (0.02 * rate))   // cierre sin clic
                let tone = sin(2 * .pi * n.freq * t) + 0.25 * sin(2 * .pi * n.freq * 2 * t)
                mix[first + i] += tone * attack * decay * tail * 0.45
            }
        }
        var pcm = Data(capacity: total * 2)
        for v in mix {
            let s = Int16(max(-1, min(1, v)) * 32000)
            withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var out = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        out.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        out.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }
}
