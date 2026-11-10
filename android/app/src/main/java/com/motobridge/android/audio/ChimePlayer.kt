package com.motobridge.android.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.sin

/**
 * Timbres de aviso sintetizados por código (sin assets), a volumen bajo.
 * Usan los mismos AudioAttributes que el intercom (voz de comunicación) para
 * salir por la ruta de audio activa; no piden foco de audio ni abren el micrófono.
 */
object ChimePlayer {
    enum class Kind { CONNECTED, PICKUP }

    private const val RATE = 22050
    private val main = Handler(Looper.getMainLooper())

    private class Note(val freq: Double, val start: Double, val length: Double)

    /** PCM 16-bit mono: 2 notas suaves con ataque corto y caída natural. */
    fun synth(kind: Kind): ShortArray {
        val notes = when (kind) {
            Kind.CONNECTED -> listOf(Note(659.25, 0.0, 0.35), Note(987.77, 0.16, 0.6))  // Mi5 -> Si5
            Kind.PICKUP -> listOf(Note(783.99, 0.0, 0.25), Note(783.99, 0.28, 0.3))     // dos toques
        }
        val total = (notes.maxOf { it.start + it.length } * RATE).toInt()
        val mix = DoubleArray(total)
        for (n in notes) {
            val first = (n.start * RATE).toInt()
            val count = (n.length * RATE).toInt()
            for (i in 0 until count) {
                if (first + i >= total) break
                val t = i.toDouble() / RATE
                val attack = min(1.0, t / 0.012)
                val decay = exp(-t * (4.0 / n.length))
                val tail = min(1.0, (count - i).toDouble() / (0.02 * RATE))
                val tone = sin(2 * PI * n.freq * t) + 0.25 * sin(2 * PI * n.freq * 2 * t)
                mix[first + i] += tone * attack * decay * tail * 0.45
            }
        }
        return ShortArray(total) { (mix[it].coerceIn(-1.0, 1.0) * 32000).toInt().toShort() }
    }

    /** Reproduce el timbre y libera el AudioTrack al terminar. Nunca lanza. */
    fun play(kind: Kind, volume: Float = 0.3f) {
        try {
            val pcm = synth(kind)
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(pcm.size * 2)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
            track.write(pcm, 0, pcm.size)
            track.setVolume(volume)
            track.play()
            main.postDelayed({ try { track.release() } catch (_: Exception) {} },
                (pcm.size * 1000L / RATE) + 300L)
        } catch (_: Exception) {
            // Un fallo del timbre nunca debe afectar al intercom.
        }
    }
}
