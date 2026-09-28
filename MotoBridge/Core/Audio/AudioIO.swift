import Foundation
import AVFoundation

/// Captura del micrófono y reproducción de audio en vivo con AVAudioEngine.
///
/// Diseño para baja latencia y bajo ancho de banda:
/// - Formato de transporte: PCM Int16, mono, 16 kHz (voz clara, ~256 kbps).
/// - La captura se convierte al formato de transporte y se entrega como Data.
/// - La reproducción recibe Data, la convierte al formato del engine y la
///   programa en un AVAudioPlayerNode.
///
/// NOTA: en esta versión NO se accede al audio de intercoms Bluetooth Classic
/// (iOS no lo permite, ver FEASIBILITY_REPORT). Usa el micrófono/salida que
/// AVAudioSession tenga como ruta activa (mic del teléfono, AirPods, o el
/// intercom si es la ruta HFP activa).
final class AudioIO {

    /// Formato de red: PCM entero de 16 bits, mono, 16 kHz.
    /// 16 kHz da margen para el realce de voz. Si la fuente es HFP (8 kHz, como
    /// el Hysnox), el conversor la sube y aplicamos filtros de mejora para que
    /// suene más clara e inteligible dentro de su límite (menos "radio AM").
    static let networkSampleRate: Double = 16_000
    static let networkChannels: AVAudioChannelCount = 1

    /// Activa el realce de voz (paso-banda + presencia + gate + normalización).
    var voiceEnhancementEnabled: Bool = true

    /// Umbral del noise gate (delegado al VoiceEnhancer).
    var gateThreshold: Float {
        get { voiceEnhancer.gateThreshold }
        set { voiceEnhancer.gateThreshold = newValue }
    }

    /// Activa/desactiva compresión Opus para el audio enviado.
    var opusEnabled: Bool = false {
        didSet { codec = opusEnabled ? OpusCodec() : PCMCodec() }
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// Formato en el que viaja el audio por la red.
    private let networkFormat: AVAudioFormat

    /// Conversores entre el formato del hardware y el de red.
    private var captureConverter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?

    /// Formato con el que está conectado el playerNode al mixer.
    private var playbackNodeFormat: AVAudioFormat?

    /// Se llama con cada bloque de audio capturado, ya en formato de red (Data).
    var onCapturedAudio: ((Data) -> Void)?

    /// Cuando es false, se captura pero NO se emite (push-to-talk soltado).
    var isTransmitting: Bool = false

    /// Ganancia digital de captura (multiplicador). 1.0 = sin cambio.
    /// Se aplica con protección anti-clipping. Rango útil ~1.0–6.0.
    var captureGain: Float = 3.0

    /// Volumen de reproducción (0.0–1.0 del playerNode, puede subir con gain).
    var playbackVolume: Float = 1.0 {
        didSet { playerNode.volume = min(1.0, playbackVolume) }
    }

    /// Ganancia digital de salida (multiplicador). Amplifica lo que se escucha,
    /// útil para dispositivos de salida "bajos" como las Ray-Ban Meta.
    /// Rango útil ~1.0–6.0, con recorte anti-distorsión.
    var outputGain: Float = 1.0

    private let log = Logger.shared
    private var isRunning = false

    init() {
        self.networkFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.networkSampleRate,
            channels: Self.networkChannels,
            interleaved: true
        )!
    }

    // MARK: - Ciclo de vida

    func start() throws {
        guard !isRunning else { return }

        // Cancelación de eco (AEC) nativa de iOS. Permite manos libres
        // bidireccional a la vez sin acoples/eco. Debe activarse antes de tocar
        // los formatos de los nodos.
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
            log.info(.audioSession, "Voice processing (AEC) habilitado")
        } catch {
            log.warning(.audioSession, "No se pudo habilitar AEC: \(error.localizedDescription)")
        }

        engine.attach(playerNode)

        // Formato de reproducción del playerNode: Float32 mono al mismo sample
        // rate de red. AVAudioPlayerNode trabaja mejor con float; el mixer se
        // encarga del resample hacia el hardware (altavoz/intercom).
        let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.networkSampleRate,
            channels: Self.networkChannels,
            interleaved: false
        )!
        self.playbackNodeFormat = playbackFormat
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

        // Conversor de reproducción: red (Int16 8k) -> playback (Float32 8k).
        playbackConverter = AVAudioConverter(from: networkFormat, to: playbackFormat)

        // Captura del micrófono.
        // IMPORTANTE: pasamos format: nil al tap. Si pasamos un formato explícito
        // leído antes de que la ruta HFP esté lista (sample rate 0/inválido), el
        // tap no entrega buffers. Con nil, el engine usa el formato real vigente.
        // El conversor de captura se crea perezosamente con el formato real del
        // primer buffer que llega.
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        playerNode.play()
        isRunning = true
        let hwOut = engine.outputNode.inputFormat(forBus: 0)
        let route = AVAudioSession.sharedInstance().currentRoute
        let inNames = route.inputs.map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ",")
        let outNames = route.outputs.map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ",")
        log.info(.audioSession, "AudioIO iniciado. In=\(inNames) Out=\(outNames) HWOutSR=\(hwOut.sampleRate) NetSR=\(Self.networkSampleRate)")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        captureConverter = nil
        isRunning = false
        log.info(.audioSession, "AudioIO detenido")
    }

    /// Reinicia el engine para que tome la nueva ruta de entrada/salida.
    /// Necesario tras cambiar la entrada preferida (setPreferredInput), porque
    /// el inputNode del engine queda ligado a la ruta anterior.
    func restart() throws {
        let wasTransmitting = isTransmitting
        stop()
        try start()
        isTransmitting = wasTransmitting
        log.info(.audioSession, "AudioIO reiniciado tras cambio de entrada")
    }

    // MARK: - Captura

    private var capturedBufferCount = 0

    /// Nivel de entrada 0.0–1.0 (RMS normalizado). Se calcula siempre, aunque no
    /// se transmita, para diagnosticar si el micrófono realmente capta señal.
    var onInputLevel: ((Float) -> Void)?

    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        capturedBufferCount += 1

        // Nivel de entrada (funciona con el formato float del inputNode).
        let level = Self.rmsLevel(buffer)
        onInputLevel?(level)

        if capturedBufferCount % 50 == 1 {
            log.debug(.audioSession, "Mic buffer #\(capturedBufferCount), transmit=\(isTransmitting), nivel=\(String(format: "%.3f", level)), inSR=\(buffer.format.sampleRate), frames=\(buffer.frameLength)")
        }
        guard isTransmitting else { return }

        // Crear/actualizar el conversor con el formato REAL del buffer entrante.
        if captureConverter == nil || captureConverter?.inputFormat != buffer.format {
            captureConverter = AVAudioConverter(from: buffer.format, to: networkFormat)
        }
        guard let converter = captureConverter else { return }

        let ratio = Self.networkSampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: networkFormat, frameCapacity: outCapacity) else { return }

        var consumed = false
        let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, outBuffer.frameLength > 0 else { return }
        applyGain(to: outBuffer, gain: captureGain)
        // Realce de voz: mejora la claridad de las fuentes de banda estrecha (HFP 8k).
        if voiceEnhancementEnabled, let ch = outBuffer.int16ChannelData {
            voiceEnhancer.process(ch[0], count: Int(outBuffer.frameLength), sampleRate: Self.networkSampleRate)
        }
        if let data = Self.data(from: outBuffer) {
            // Codificar (Opus o PCM) y anteponer 1 byte de códec.
            let payload = codec.encode(data)
            var packet = Data([codec.codecId])
            packet.append(payload)
            onCapturedAudio?(packet)
        }
    }

    private let voiceEnhancer = VoiceEnhancer()

    /// Códec de audio (PCM por defecto; Opus si se activa). Ver AudioCodec.
    var codec: AudioCodec = PCMCodec()
    private let opusDecoder = OpusCodec()  // para decodificar paquetes Opus entrantes

    /// Aplica ganancia digital a un buffer Int16 con recorte suave (clamp) para
    /// evitar saturación que distorsione la voz.
    private func applyGain(to buffer: AVAudioPCMBuffer, gain: Float) {
        guard gain != 1.0, let ch = buffer.int16ChannelData else { return }
        let n = Int(buffer.frameLength)
        let ptr = ch[0]
        for i in 0..<n {
            let amplified = Float(ptr[i]) * gain
            // Clamp al rango Int16 para no envolver (wrap) la señal.
            let clamped = max(-32768, min(32767, amplified))
            ptr[i] = Int16(clamped)
        }
    }

    /// Aplica ganancia a un buffer Float32 con recorte a ±1.0 (anti-distorsión).
    private func applyFloatGain(to buffer: AVAudioPCMBuffer, gain: Float) {
        guard gain != 1.0, let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let ptr = ch[0]
        for i in 0..<n {
            let amplified = ptr[i] * gain
            ptr[i] = max(-1.0, min(1.0, amplified))
        }
    }

    // MARK: - Reproducción

    /// Recibe Data (1 byte de códec + payload) y la reproduce.
    func playReceivedAudio(_ packet: Data) {
        guard isRunning, packet.count > 1 else { return }
        // Leer cabecera de códec y decodificar el payload.
        let codecByte = packet[packet.startIndex]
        let payload = packet.subdata(in: (packet.startIndex + 1)..<packet.endIndex)
        let pcm: Data?
        if codecByte == AudioCodecId.opus.rawValue {
            pcm = opusDecoder.decode(payload)
        } else {
            pcm = payload
        }
        guard let data = pcm,
              let inBuffer = Self.buffer(from: data, format: networkFormat),
              let converter = playbackConverter else { return }

        let targetFormat = converter.outputFormat
        let ratio = targetFormat.sampleRate / networkFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var consumed = false
        let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuffer
        }

        guard status != .error, outBuffer.frameLength > 0 else { return }
        applyFloatGain(to: outBuffer, gain: outputGain)
        playerNode.scheduleBuffer(outBuffer, completionHandler: nil)
    }

    // MARK: - Serialización PCM Int16 <-> Data

    /// Calcula el nivel RMS normalizado (0.0–1.0) de un buffer, soportando
    /// formatos float y Int16.
    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        if let fch = buffer.floatChannelData {
            var sum: Float = 0
            let p = fch[0]
            for i in 0..<frames { sum += p[i] * p[i] }
            let rms = (sum / Float(frames)).squareRoot()
            return min(1.0, rms * 4) // escala para que sea visible
        } else if let ich = buffer.int16ChannelData {
            var sum: Float = 0
            let p = ich[0]
            for i in 0..<frames {
                let v = Float(p[i]) / 32768.0
                sum += v * v
            }
            let rms = (sum / Float(frames)).squareRoot()
            return min(1.0, rms * 4)
        }
        return 0
    }

    private static func data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let byteCount = frames * MemoryLayout<Int16>.size // mono
        return Data(bytes: channelData[0], count: byteCount)
    }

    private static func buffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.int16ChannelData else { return nil }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Int16.self).baseAddress {
                channelData[0].update(from: base, count: Int(frameCount))
            }
        }
        return buffer
    }
}
