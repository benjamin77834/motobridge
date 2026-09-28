import Foundation

/// Abstracción de códec de audio para el transporte. Permite enviar PCM crudo
/// (passthrough) o comprimido (Opus) sin cambiar el resto del pipeline.
///
/// El paquete de red lleva 1 byte de cabecera de códec para que el receptor
/// sepa cómo decodificar, así conviven dispositivos con y sin Opus durante una
/// transición.
protocol AudioCodec: AnyObject {
    /// Identificador del códec (va en la cabecera del paquete).
    var codecId: UInt8 { get }
    /// Comprime un bloque PCM Int16 mono (al sample rate de red) -> bytes.
    func encode(_ pcm: Data) -> Data
    /// Descomprime bytes -> PCM Int16 mono. Devuelve nil si falla.
    func decode(_ bytes: Data) -> Data?
}

enum AudioCodecId: UInt8 {
    case pcm = 0x00
    case opus = 0x01
}

/// Códec passthrough: no comprime, envía el PCM tal cual. Es el que se usa por
/// defecto y garantiza que el pipeline funcione siempre. Cuando la librería
/// Opus esté integrada y validada, se cambia por OpusCodec.
final class PCMCodec: AudioCodec {
    let codecId: UInt8 = AudioCodecId.pcm.rawValue
    func encode(_ pcm: Data) -> Data { pcm }
    func decode(_ bytes: Data) -> Data? { bytes }
}
