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
