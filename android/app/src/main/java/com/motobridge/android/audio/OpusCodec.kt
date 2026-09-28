package com.motobridge.android.audio

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer

/**
 * Códec Opus para Android usando MediaCodec (nativo, sin dependencias externas).
 *
 * NOTA honesta: el Opus de MediaCodec en tiempo real es delicado y varía entre
 * fabricantes. Este códec intenta inicializar encoder+decoder de Opus; si el
 * dispositivo no los soporta, el constructor lanza y la app cae automáticamente
 * a PCM (ver AudioIO). Para interoperar con iOS (que usa libopus), ambos deben
 * negociar el mismo modo; mientras se valida en hardware, el modo seguro es PCM.
 *
 * Parámetros: 16 kHz mono, igual que el formato de red.
 */
class OpusCodec : AudioCodec {
    override val codecId = CodecId.OPUS

    companion object {
        private const val TAG = "MotoBridgeOpus"
        private const val SAMPLE_RATE = 16000
        private const val MIME = MediaFormat.MIMETYPE_AUDIO_OPUS
        private const val TIMEOUT_US = 5000L
    }

    private val encoder: MediaCodec
    private val decoder: MediaCodec

    init {
        val format = MediaFormat.createAudioFormat(MIME, SAMPLE_RATE, 1).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, 24000)
            setInteger(MediaFormat.KEY_AAC_PROFILE, 0)
        }
        encoder = MediaCodec.createEncoderByType(MIME).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }
        decoder = MediaCodec.createDecoderByType(MIME).apply {
            configure(format, null, null, 0)
            start()
        }
        Log.i(TAG, "Opus MediaCodec inicializado")
    }

    override fun encode(pcm: ByteArray): ByteArray {
        return try {
            process(encoder, pcm)
        } catch (e: Exception) {
            Log.w(TAG, "encode falló: ${e.message}")
            pcm
        }
    }

    override fun decode(bytes: ByteArray): ByteArray? {
        return try {
            process(decoder, bytes)
        } catch (e: Exception) {
            Log.w(TAG, "decode falló: ${e.message}")
            null
        }
    }

    private fun process(codec: MediaCodec, input: ByteArray): ByteArray {
        val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
        if (inIndex >= 0) {
            val inBuf: ByteBuffer? = codec.getInputBuffer(inIndex)
            inBuf?.clear()
            inBuf?.put(input)
            codec.queueInputBuffer(inIndex, 0, input.size, System.nanoTime() / 1000, 0)
        }
        val info = MediaCodec.BufferInfo()
        val out = java.io.ByteArrayOutputStream()
        var outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
        while (outIndex >= 0) {
            val outBuf = codec.getOutputBuffer(outIndex)
            if (outBuf != null && info.size > 0) {
                val chunk = ByteArray(info.size)
                outBuf.get(chunk)
                out.write(chunk)
            }
            codec.releaseOutputBuffer(outIndex, false)
            outIndex = codec.dequeueOutputBuffer(info, 0)
        }
        return out.toByteArray()
    }
}
