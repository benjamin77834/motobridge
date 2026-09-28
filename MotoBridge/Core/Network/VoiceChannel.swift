import Foundation

/// Encabezado de aplicación que envuelve el audio para soportar canales:
/// grupo (todos), privado (solo un rider) y alarma (emergencia, todos con
/// prioridad). Se antepone al paquete de audio (que ya lleva su cabecera de
/// códec) ANTES de pasar por el mesh.
///
/// Formato:
///   byte 0     : tipo (0=grupo, 1=privado, 2=alarma)
///   bytes 1..4 : targetId (UInt32) — solo relevante en privado; 0 si no aplica
///   bytes 5..N : payload de audio (cabecera de códec + datos)
enum VoiceChannelType: UInt8 {
    case group = 0
    case privateWhisper = 1   // solo llega al destinatario; tú sigues oyendo al grupo
    case alarm = 2            // emergencia: todos lo reproducen con prioridad
}

enum VoiceChannel {
    static let headerSize = 5

    static func wrap(_ audio: Data, type: VoiceChannelType, targetId: UInt32) -> Data {
        var out = Data(capacity: headerSize + audio.count)
        out.append(type.rawValue)
        var t = targetId.bigEndian
        withUnsafeBytes(of: &t) { out.append(contentsOf: $0) }
        out.append(audio)
        return out
    }

    struct Unwrapped {
        let type: VoiceChannelType
        let targetId: UInt32
        let audio: Data
    }

    static func unwrap(_ data: Data) -> Unwrapped? {
        guard data.count > headerSize else { return nil }
        let b = [UInt8](data.prefix(headerSize))
        guard let type = VoiceChannelType(rawValue: b[0]) else { return nil }
        let target = (UInt32(b[1]) << 24) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 8) | UInt32(b[4])
        let audio = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        return Unwrapped(type: type, targetId: target, audio: audio)
    }
}
