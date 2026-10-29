import Foundation
import AVFoundation

/// Motor de audio para la app de macOS: captura el micrófono y reproduce el
/// audio entrante, con el MISMO formato de red que iOS (PCM Int16 16 kHz mono).
/// Permite que la Mac sea un participante de voz más ("puesto base").
///
/// Diferencias con iOS: en macOS NO existe AVAudioSession; AVAudioEngine usa el
/// dispositivo de audio por defecto del sistema directamente. Usamos
/// setVoiceProcessingEnabled para que el cancelador de eco del sistema evite el
/// acople altavoz↔micrófono (la Mac típicamente usa bocinas + mic abiertos).
final class RelayAudio {

    static let networkSampleRate: Double = 16_000
    static let networkChannels: AVAudioChannelCount = 1

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let networkFormat: AVAudioFormat
    private var captureConverter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?
    private var isRunning = false

    /// Se llama con cada bloque capturado, ya en formato de red (1 byte codec + PCM).
    var onCapturedAudio: ((Data) -> Void)?
    /// Si es false, se captura pero NO se emite (micrófono "en silencio").
    var isTransmitting = false

    /// Jitter buffer acotado para que la latencia no crezca.
    private var pendingPlaybackBuffers = 0
    private let maxPendingPlaybackBuffers = 6

    private let codec: AudioCodec = PCMCodec()

    init() {
        self.networkFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.networkSampleRate,
            channels: Self.networkChannels,
            interleaved: true
        )!
    }

    func start() throws {
        guard !isRunning else { return }

        // Cancelación de eco del sistema (evita acople bocinas↔micrófono).
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
        } catch {
            // Si no se puede, seguimos: habrá más riesgo de eco (turnarse para hablar).
        }

        engine.attach(playerNode)
        let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.networkSampleRate,
            channels: Self.networkChannels,
            interleaved: false
        )!
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        playbackConverter = AVAudioConverter(from: networkFormat, to: playbackFormat)

        // Tap del micrófono. format nil = formato real del dispositivo; se
        // convierte a 16 kHz en el handler.
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.handleCaptured(buffer)
        }

        engine.prepare()
        try engine.start()
        playerNode.play()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        captureConverter = nil
        pendingPlaybackBuffers = 0
        isRunning = false
    }

    // MARK: - Captura

    private func handleCaptured(_ buffer: AVAudioPCMBuffer) {
        guard isTransmitting else { return }
        if captureConverter == nil || captureConverter?.inputFormat != buffer.format {
            captureConverter = AVAudioConverter(from: buffer.format, to: networkFormat)
        }
        guard let converter = captureConverter else { return }
        let ratio = Self.networkSampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: networkFormat, frameCapacity: cap) else { return }
        var consumed = false
        let status = converter.convert(to: out, error: nil) { _, s in
            if consumed { s.pointee = .noDataNow; return nil }
            consumed = true; s.pointee = .haveData; return buffer
        }
        guard status != .error, out.frameLength > 0, let data = Self.data(from: out) else { return }
        var packet = Data([codec.codecId])
        packet.append(codec.encode(data))
        onCapturedAudio?(packet)
    }

    // MARK: - Reproducción

    /// Reproduce un paquete de audio entrante (1 byte codec + PCM). Solo PCM:
    /// si llega Opus (codec 1) se ignora (la Mac no incluye el decodificador Opus).
    func play(_ packet: Data) {
        guard isRunning, packet.count > 1 else { return }
        if pendingPlaybackBuffers >= maxPendingPlaybackBuffers { return }
        let codecByte = packet[packet.startIndex]
        guard codecByte == AudioCodecId.pcm.rawValue else { return }
        let payload = packet.subdata(in: (packet.startIndex + 1)..<packet.endIndex)
        guard let inBuffer = Self.buffer(from: payload, format: networkFormat),
              let converter = playbackConverter else { return }
        let targetFormat = converter.outputFormat
        let ratio = targetFormat.sampleRate / networkFormat.sampleRate
        let cap = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return }
        var consumed = false
        let status = converter.convert(to: out, error: nil) { _, s in
            if consumed { s.pointee = .noDataNow; return nil }
            consumed = true; s.pointee = .haveData; return inBuffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        pendingPlaybackBuffers += 1
        playerNode.scheduleBuffer(out) { [weak self] in
            DispatchQueue.main.async { self?.pendingPlaybackBuffers -= 1 }
        }
    }

    // MARK: - Serialización PCM Int16 <-> Data

    private static func data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let ch = buffer.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    private static func buffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch = buf.int16ChannelData else { return nil }
        buf.frameLength = frames
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Int16.self).baseAddress {
                ch[0].update(from: base, count: Int(frames))
            }
        }
        return buf
    }

    /// Pide permiso de micrófono (macOS). Llama a completion con el resultado.
    static func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default: completion(false)
        }
    }
}
