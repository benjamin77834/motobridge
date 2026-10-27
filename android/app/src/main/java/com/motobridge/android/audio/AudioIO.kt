package com.motobridge.android.audio

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.util.Log
import kotlin.concurrent.thread

/**
 * Captura y reproducción de audio en 8 kHz mono PCM16, según PROTOCOL.md.
 * Usa VOICE_COMMUNICATION + AEC/NS para minimizar eco (equivalente al voice
 * processing del iOS).
 */
class AudioIO {
    companion object {
        const val SAMPLE_RATE = 16000 // voz de banda ancha (HD), debe coincidir con iOS
        private const val TAG = "MotoBridgeAudio"
    }

    /** Bloque PCM capturado listo para enviar. */
    var onCaptured: ((ByteArray, Int) -> Unit)? = null

    /** Nivel de entrada 0.0–1.0 para el medidor visual. */
    var onLevel: ((Float) -> Unit)? = null

    /** Ganancias digitales (equivalentes a iOS). Captura baja por defecto para
     *  no saturar el micrófono (micrófonos de gama baja meten gis al amplificar). */
    @Volatile var captureGain: Float = 1.5f
    @Volatile var outputGain: Float = 1.0f

    /** Push-to-talk: solo se envía si está en true. */
    @Volatile var isTransmitting: Boolean = false

    /** Códec de envío. PCM por defecto; Opus si el dispositivo lo soporta. */
    @Volatile var codec: AudioCodec = PcmCodec()
    private val opusDecoder: AudioCodec? by lazy { runCatching { OpusCodec() }.getOrNull() }

    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var running = false
    private var captureThread: Thread? = null

    private val inBufSize = AudioRecord.getMinBufferSize(
        SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
    ).coerceAtLeast(1024)

    private val outBufSize = AudioTrack.getMinBufferSize(
        SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
    ).coerceAtLeast(1024)

    /** Sample rate REAL que el hardware concedió a la captura. Puede diferir de
     *  SAMPLE_RATE (16 kHz) en equipos de gama baja: VOICE_COMMUNICATION suele
     *  entregar 8 kHz, o el chip cae a 48 kHz. Si no es 16 kHz, resampleamos a
     *  16 kHz ANTES de enviar, porque el receptor (iOS/Android) asume 16 kHz
     *  fijos; si no, la voz se oye "borracha" (grave/lenta) y con retardo. */
    private var captureRate = SAMPLE_RATE

    @SuppressLint("MissingPermission") // el permiso RECORD_AUDIO se pide en la UI antes de start()
    fun start() {
        if (running) return

        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            inBufSize
        )
        record = rec
        // Tasa real concedida por el hardware (puede no ser 16 kHz).
        captureRate = rec.sampleRate.takeIf { it > 0 } ?: SAMPLE_RATE
        if (captureRate != SAMPLE_RATE) {
            Log.w(TAG, "Captura a $captureRate Hz (pedido $SAMPLE_RATE); se resampleará a $SAMPLE_RATE")
        }

        // Cancelación de eco y supresión de ruido si el dispositivo las soporta.
        if (AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(rec.audioSessionId)?.apply { enabled = true }
        }
        if (NoiseSuppressor.isAvailable()) {
            ns = NoiseSuppressor.create(rec.audioSessionId)?.apply { enabled = true }
        }

        val trackBuilder = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()
            )
            .setBufferSizeInBytes(outBufSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
        // Modo de baja latencia: pide a Android el camino de audio rápido, para
        // no sumar retardo propio encima del que ya mete el Bluetooth (audífonos
        // como los Redmi ya son lentos en HFP; no empeoremos desde la app).
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            trackBuilder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        val tr = trackBuilder.build()
        track = tr

        rec.startRecording()
        tr.play()
        running = true
        startMixLoop()

        captureThread = thread(isDaemon = true, name = "motobridge-capture") {
            val buffer = ShortArray(inBufSize / 2)
            // Acumulador para ENVIAR en bloques FIJOS de 320 muestras (20 ms a
            // 16 kHz). Enviar bloques de tamaño variable (lo que devuelve read)
            // hace que el receptor oiga voz "robotizada"/entrecortada.
            val sendBlock = 320
            val acc = ShortArray(sendBlock)
            var accLen = 0
            val needResample = captureRate != SAMPLE_RATE
            resetResampler()
            while (running) {
                val n = rec.read(buffer, 0, buffer.size)
                if (n <= 0) continue

                // Nivel (RMS) para el medidor.
                onLevel?.invoke(rms(buffer, n))

                if (!isTransmitting) { accLen = 0; continue }

                // Ganancia de captura con clamp.
                applyGain(buffer, n, captureGain)

                // Resamplear a 16 kHz si el hardware capturó a otra tasa. Así el
                // receptor (que asume 16 kHz) oye la voz a tono/velocidad normal.
                val (samples, count) = if (needResample) resampleTo16k(buffer, n) else Pair(buffer, n)

                // Realce de voz a 16 kHz (los filtros están diseñados a 16 kHz).
                enhance(samples, count)

                // Acumular y emitir en bloques fijos de 320 muestras.
                var idx = 0
                while (idx < count) {
                    val take = minOf(sendBlock - accLen, count - idx)
                    System.arraycopy(samples, idx, acc, accLen, take)
                    accLen += take; idx += take
                    if (accLen == sendBlock) {
                        emitBlock(acc, sendBlock)
                        accLen = 0
                    }
                }
            }
        }
        Log.i(TAG, "AudioIO iniciado (in=$inBufSize out=$outBufSize)")
    }

    /** Empaqueta un bloque PCM fijo (little-endian), lo codifica y lo emite. */
    private fun emitBlock(samples: ShortArray, len: Int) {
        val pcm = ByteArray(len * 2)
        for (i in 0 until len) {
            val v = samples[i].toInt()
            pcm[i * 2] = (v and 0xFF).toByte()
            pcm[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        val payload = codec.encode(pcm)
        val packet = ByteArray(payload.size + 1)
        packet[0] = codec.codecId
        System.arraycopy(payload, 0, packet, 1, payload.size)
        onCaptured?.invoke(packet, packet.size)
    }

    fun stop() {
        if (!running) return
        running = false
        captureThread?.join(500)
        captureThread = null
        mixThread?.join(300)
        mixThread = null
        peerQueues.clear()
        try { record?.stop() } catch (_: Exception) {}
        record?.release(); record = null
        aec?.release(); aec = null
        ns?.release(); ns = null
        try { track?.stop() } catch (_: Exception) {}
        track?.release(); track = null
        Log.i(TAG, "AudioIO detenido")
    }

    // --- Mezcla de grupo ---
    // Cada peer tiene su propia cola de muestras. Un hilo de salida toma un
    // bloque de cada cola, los SUMA (mezcla) y lo escribe al AudioTrack. Así, si
    // varios hablan a la vez, se escuchan mezclados en vez de entrecortados.
    private val peerQueues = java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.ConcurrentLinkedQueue<Short>>()
    private var mixThread: Thread? = null
    private val mixBlock = 320 // 20 ms a 16 kHz

    /** Recibe un paquete (1 byte de códec + payload) de un peer, para mezclar. */
    fun playFrom(peerId: String, packet: ByteArray) {
        if (packet.size <= 1) return
        val codecByte = packet[0]
        val payload = packet.copyOfRange(1, packet.size)
        val bytes: ByteArray = if (codecByte == CodecId.OPUS) {
            opusDecoder?.decode(payload) ?: return  // sin Opus, no reproducir basura
        } else {
            payload
        }
        val n = bytes.size / 2
        if (n == 0) return
        val q = peerQueues.getOrPut(peerId) { java.util.concurrent.ConcurrentLinkedQueue() }
        // Limitar la cola para MINIMIZAR latencia: máx ~3 bloques (60 ms). Si
        // crece más, descartar lo viejo (preferimos audio reciente a bajo retardo).
        val maxQueue = mixBlock * 3
        while (q.size > maxQueue) q.poll()
        for (i in 0 until n) {
            val lo = bytes[i * 2].toInt() and 0xFF
            val hi = bytes[i * 2 + 1].toInt()
            q.add(((hi shl 8) or lo).toShort())
        }
    }

    /** Compatibilidad: un solo stream sin identificar. */
    fun play(bytes: ByteArray) = playFrom("default", bytes)

    private fun startMixLoop() {
        mixThread = thread(isDaemon = true, name = "motobridge-mix") {
            val out = ShortArray(mixBlock)
            val mix = IntArray(mixBlock)
            while (running) {
                java.util.Arrays.fill(mix, 0)
                var anyData = false
                // Sumar un bloque de cada peer, SOLO si tiene un bloque completo.
                // Consumir colas con menos de mixBlock mete silencios → audio
                // entrecortado y "lento". Esperamos a que se acumule el bloque.
                for (q in peerQueues.values) {
                    if (q.size < mixBlock) continue   // aún no hay bloque completo
                    anyData = true
                    for (i in 0 until mixBlock) {
                        val s = q.poll() ?: 0
                        mix[i] += s.toInt()
                    }
                }
                if (anyData) {
                    for (i in 0 until mixBlock) {
                        var v = (mix[i] * outputGain).toInt()
                        if (v > 32767) v = 32767
                        if (v < -32768) v = -32768
                        out[i] = v.toShort()
                    }
                    track?.write(out, 0, mixBlock)
                } else {
                    Thread.sleep(5) // sin datos, esperar un poco
                }
            }
        }
    }

    // --- Resampler lineal a 16 kHz (para captura que no entrega 16 kHz) ---
    // Mantiene estado entre bloques (última muestra + fase) para que la voz no
    // tenga clics ni saltos en las fronteras de bloque. Buffer de salida reusado
    // dimensionado al peor caso (upsampling).
    private var rsLastSample = 0f
    private var rsPhase = 0.0
    private var rsOut = ShortArray(0)

    private fun resetResampler() {
        rsLastSample = 0f
        rsPhase = 0.0
    }

    /** Resamplea `length` muestras de `captureRate` a 16 kHz por interpolación
     *  lineal. Devuelve el buffer de salida y cuántas muestras válidas tiene. */
    private fun resampleTo16k(input: ShortArray, length: Int): Pair<ShortArray, Int> {
        if (length <= 0) return Pair(input, 0)
        val step = captureRate.toDouble() / SAMPLE_RATE.toDouble() // muestras de entrada por cada muestra de salida
        // Cota superior de muestras de salida para este bloque.
        val maxOut = ((length / step) + 2).toInt() + 1
        if (rsOut.size < maxOut) rsOut = ShortArray(maxOut)
        var outCount = 0
        var phase = rsPhase
        // Interpolamos entre prev (muestra anterior, puede venir del bloque pasado)
        // y la muestra actual del input, según la fase fraccionaria.
        while (phase < length) {
            val i = phase.toInt()
            val frac = (phase - i).toFloat()
            val prev = if (i == 0) rsLastSample else input[i - 1].toFloat()
            val cur = input[i].toFloat()
            val v = prev + (cur - prev) * frac
            rsOut[outCount++] = v.toInt().coerceIn(-32768, 32767).toShort()
            phase += step
        }
        // Guardar estado para el siguiente bloque: última muestra y fase sobrante.
        rsLastSample = input[length - 1].toFloat()
        rsPhase = phase - length
        return Pair(rsOut, outCount)
    }

    private fun applyGain(samples: ShortArray, length: Int, gain: Float) {
        if (gain == 1.0f) return
        for (i in 0 until length) {
            val amplified = (samples[i] * gain)
            val clamped = amplified.coerceIn(-32768f, 32767f)
            samples[i] = clamped.toInt().toShort()
        }
    }

    // --- Realce de voz (equivalente al VoiceEnhancer de iOS) ---
    // Filtro paso-banda de voz (300–3400 Hz) + realce + noise gate + normalización.
    @Volatile var voiceEnhancementEnabled: Boolean = true
    /** Umbral del noise gate (0..0.1). Sube para cortar música/ruido de fondo.
     *  Un poco alto por defecto para silenciar el ruido del micrófono entre palabras. */
    @Volatile var gateThreshold: Float = 0.02f

    private var biquads: Array<Biquad>? = null
    private var env = 0f
    private var gateEnv = 0f
    private var gateGain = 0f

    /** Biquad TDF-II con coeficientes normalizados. */
    private class Biquad(
        val b0: Float, val b1: Float, val b2: Float, val a1: Float, val a2: Float
    ) {
        var z1 = 0f; var z2 = 0f
        fun process(x: Float): Float {
            val y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private fun buildFilters() {
        val sr = SAMPLE_RATE.toDouble()
        val hp = highpass(300.0, sr)
        val lp = lowpass(kotlin.math.min(3400.0, sr / 2 - 200), sr)
        val pk = peaking(2000.0, 1.0, 5.0, sr)
        biquads = arrayOf(hp, lp, pk)
    }

    private fun enhance(samples: ShortArray, length: Int) {
        if (!voiceEnhancementEnabled) return
        if (biquads == null) buildFilters()
        val bq = biquads ?: return
        for (i in 0 until length) {
            var s = samples[i] / 32768f
            // Paso-banda de voz + realce.
            s = bq[0].process(s)  // paso-alto 300 Hz
            s = bq[1].process(s)  // paso-bajo 3400 Hz
            s = bq[2].process(s)  // presencia 2 kHz

            // Noise gate sobre la señal filtrada. Ataque rápido, liberación lenta.
            // Corta el ruido de fondo entre palabras (principal fuente de "gis").
            val mag = kotlin.math.abs(s)
            val gc = if (mag > gateEnv) 0.5f else 0.05f
            gateEnv += (mag - gateEnv) * gc
            val target = if (gateEnv > gateThreshold) 1f else 0f
            val sm = if (target > gateGain) 0.3f else 0.08f
            gateGain += (target - gateGain) * sm
            s *= gateGain

            // SIN normalización: amplificar los tramos bajos levantaba el ruido
            // del micrófono y producía "gis"/estática. Dejamos el volumen natural;
            // el usuario sube el "Volumen de escucha" si hace falta más fuerte.

            s = s.coerceIn(-1f, 1f)
            samples[i] = (s * 32767f).toInt().toShort()
        }
    }

    private fun highpass(freq: Double, sr: Double): Biquad {
        val w0 = 2 * Math.PI * freq / sr; val c = Math.cos(w0); val sn = Math.sin(w0)
        val alpha = sn / (2 * 0.707)
        val b0 = (1 + c) / 2; val b1 = -(1 + c); val b2 = (1 + c) / 2
        val a0 = 1 + alpha; val a1 = -2 * c; val a2 = 1 - alpha
        return norm(b0, b1, b2, a0, a1, a2)
    }
    private fun lowpass(freq: Double, sr: Double): Biquad {
        val w0 = 2 * Math.PI * freq / sr; val c = Math.cos(w0); val sn = Math.sin(w0)
        val alpha = sn / (2 * 0.707)
        val b0 = (1 - c) / 2; val b1 = 1 - c; val b2 = (1 - c) / 2
        val a0 = 1 + alpha; val a1 = -2 * c; val a2 = 1 - alpha
        return norm(b0, b1, b2, a0, a1, a2)
    }
    private fun peaking(freq: Double, q: Double, gainDB: Double, sr: Double): Biquad {
        val A = Math.pow(10.0, gainDB / 40.0)
        val w0 = 2 * Math.PI * freq / sr; val c = Math.cos(w0); val sn = Math.sin(w0)
        val alpha = sn / (2 * q)
        val b0 = 1 + alpha * A; val b1 = -2 * c; val b2 = 1 - alpha * A
        val a0 = 1 + alpha / A; val a1 = -2 * c; val a2 = 1 - alpha / A
        return norm(b0, b1, b2, a0, a1, a2)
    }
    private fun norm(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) =
        Biquad((b0 / a0).toFloat(), (b1 / a0).toFloat(), (b2 / a0).toFloat(), (a1 / a0).toFloat(), (a2 / a0).toFloat())

    private fun rms(samples: ShortArray, length: Int): Float {
        if (length == 0) return 0f
        var sum = 0.0
        for (i in 0 until length) {
            val v = samples[i] / 32768.0
            sum += v * v
        }
        val rms = Math.sqrt(sum / length)
        return (rms * 4).coerceAtMost(1.0).toFloat()
    }
}
