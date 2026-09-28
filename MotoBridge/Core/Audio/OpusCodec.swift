import Foundation
import AVFoundation
import Opus

/// Códec Opus para iOS (usa swift-opus). Comprime la voz ~10x respecto a PCM,
/// mejorando calidad y reduciendo ancho de banda — clave para grupos y para el
/// enlace por Internet.
///
/// Trabaja con el formato de red: PCM Int16 mono a `sampleRate`. Internamente
/// convierte a Float32 (lo que espera Opus) y de vuelta.
final class OpusCodec: AudioCodec {
    let codecId: UInt8 = AudioCodecId.opus.rawValue

    private let sampleRate: Double
    private let format: AVAudioFormat
    private var encoder: Opus.Encoder?
    private var decoder: Opus.Decoder?
    private let log = Logger.shared

    /// frameSize: muestras por paquete (20 ms). A 16 kHz = 320.
    private let frameSize: AVAudioFrameCount

    init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
        // Opus requiere un AVAudioFormat con sample rate soportado (8/12/16/24/48k).
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )!
        self.frameSize = AVAudioFrameCount(sampleRate * 0.02) // 20 ms
        do {
            self.encoder = try Opus.Encoder(format: format, application: .voip)
            self.decoder = try Opus.Decoder(format: format)
        } catch {
            log.error(.audioSession, "Opus init falló: \(error.localizedDescription)")
        }
    }

    func encode(_ pcm: Data) -> Data {
        guard let encoder,
              let inBuffer = Self.buffer(from: pcm, format: format) else { return pcm }
        do {
            // Salida comprimida (buffer generoso).
            var out = Data(count: 1500)
            let bytes = try out.withUnsafeMutableBytes { raw -> Int in
                try encoder.encode(inBuffer, to: raw.bindMemory(to: UInt8.self))
            }
            return out.prefix(bytes)
        } catch {
            return pcm // si falla, no romper el audio
        }
    }

    func decode(_ bytes: Data) -> Data? {
        guard let decoder else { return nil }
        // Guardas defensivas: un paquete Opus válido no está vacío ni es enorme.
        // Datos fuera de rango pueden hacer crashear a opus_decode (C), así que
        // los descartamos antes de pasar al decodificador.
        guard bytes.count >= 1, bytes.count <= 4000 else { return nil }
        do {
            let outBuffer = try decoder.decode(bytes)
            return Self.data(from: outBuffer)
        } catch {
            return nil
        }
    }

    // MARK: - PCM <-> AVAudioPCMBuffer (Int16 mono)

    private static func buffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch = buffer.int16ChannelData else { return nil }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Int16.self).baseAddress {
                ch[0].update(from: base, count: Int(frames))
            }
        }
        return buffer
    }

    private static func data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let ch = buffer.int16ChannelData else { return nil }
        let count = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: ch[0], count: count)
    }
}
