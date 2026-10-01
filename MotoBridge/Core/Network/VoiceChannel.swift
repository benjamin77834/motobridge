import Foundation

/// Encabezado de aplicación que envuelve el audio/texto para soportar canales:
/// grupo (todos), privado (un rider), alarma (emergencia), texto (leído por voz)
/// y subgrupo (varios riders elegidos). Se antepone al payload ANTES del mesh.
///
/// Formato para group/privateWhisper/alarm/text (5 bytes, compatible histórico):
///   byte 0     : tipo
///   bytes 1..4 : targetId (UInt32 big-endian) — destinatario único; 0 = grupo
///   bytes 5..N : payload (audio con cabecera de códec, o texto UTF-8)
///
/// Formato para subgroup (lista de destinatarios):
///   byte 0     : tipo (4)
///   byte 1     : subtipo (0 = audio, 1 = texto)  ← qué es el payload
///   byte 2     : count (número de targetIds, 1..N)
///   bytes 3..  : count × 4 bytes (targetIds UInt32 big-endian)
///   resto      : payload
enum VoiceChannelType: UInt8 {
    case group = 0
    case privateWhisper = 1   // solo llega al destinatario; tú sigues oyendo al grupo
    case alarm = 2            // emergencia: todos lo reproducen con prioridad
    case text = 3             // mensaje escrito: el receptor lo lee por voz (TTS)
    case subgroup = 4         // varios riders elegidos (voz o texto)
    case presence = 5         // latido: el payload es el nombre del rider (para el radar)
}

enum VoiceChannel {
    static let headerSize = 5   // formato clásico (1 target)

    // MARK: - Formato clásico (1 destinatario)

    static func wrap(_ audio: Data, type: VoiceChannelType, targetId: UInt32) -> Data {
        var out = Data(capacity: headerSize + audio.count)
        out.append(type.rawValue)
        var t = targetId.bigEndian
        withUnsafeBytes(of: &t) { out.append(contentsOf: $0) }
        out.append(audio)
        return out
    }

    // MARK: - Formato subgrupo (varios destinatarios)

    /// Envuelve un payload para un subgrupo de riders.
    ///  - isText: true si el payload es texto UTF-8; false si es audio.
    static func wrapSubgroup(_ payload: Data, targets: [UInt32], isText: Bool) -> Data {
        var out = Data(capacity: 3 + targets.count * 4 + payload.count)
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
        let targetId: UInt32     // clásico: destinatario único (0 = grupo)
        let audio: Data          // payload (audio o texto)
        // Subgrupo:
        let targets: [UInt32]    // lista de destinatarios (vacía si no es subgrupo)
        let isText: Bool         // en subgrupo: ¿el payload es texto?
    }

    static func unwrap(_ data: Data) -> Unwrapped? {
        guard let first = data.first, let type = VoiceChannelType(rawValue: first) else { return nil }

        if type == .subgroup {
            guard data.count > 3 else { return nil }
            let b = [UInt8](data)
            let isText = b[1] == 1
            let count = Int(b[2])
            let idsStart = 3
            let payloadStart = idsStart + count * 4
            guard data.count > payloadStart else { return nil }
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

        // Formato clásico (5 bytes).
        guard data.count > headerSize else { return nil }
        let b = [UInt8](data.prefix(headerSize))
        let target = (UInt32(b[1]) << 24) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 8) | UInt32(b[4])
        let audio = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        return Unwrapped(type: type, targetId: target, audio: audio, targets: [], isText: false)
    }
}
