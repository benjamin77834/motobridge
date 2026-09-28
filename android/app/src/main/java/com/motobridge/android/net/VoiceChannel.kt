package com.motobridge.android.net

/**
 * Encabezado de canal de voz (compatible con iOS VoiceChannel).
 * Formato: tipo(1) + targetId(4, big-endian) + audio.
 *   tipo: 0=grupo, 1=privado, 2=alarma
 */
object VoiceChannel {
    const val HEADER = 5
    const val GROUP: Byte = 0
    const val PRIVATE: Byte = 1
    const val ALARM: Byte = 2
    const val TEXT: Byte = 3   // mensaje escrito: el receptor lo lee por voz (TTS)

    fun wrap(audio: ByteArray, type: Byte, targetId: Int): ByteArray {
        val out = ByteArray(HEADER + audio.size)
        out[0] = type
        out[1] = ((targetId shr 24) and 0xFF).toByte()
        out[2] = ((targetId shr 16) and 0xFF).toByte()
        out[3] = ((targetId shr 8) and 0xFF).toByte()
        out[4] = (targetId and 0xFF).toByte()
        System.arraycopy(audio, 0, out, HEADER, audio.size)
        return out
    }

    data class Msg(val type: Byte, val targetId: Int, val audio: ByteArray)

    fun unwrap(data: ByteArray): Msg? {
        if (data.size <= HEADER) return null
        val type = data[0]
        val target = ((data[1].toInt() and 0xFF) shl 24) or
                     ((data[2].toInt() and 0xFF) shl 16) or
                     ((data[3].toInt() and 0xFF) shl 8) or
                     (data[4].toInt() and 0xFF)
        return Msg(type, target, data.copyOfRange(HEADER, data.size))
    }

    /** ID estable derivado del nombre (mismo algoritmo FNV-1a que iOS). */
    fun idFor(name: String): Int {
        var hash = 2166136261L
        for (b in name.toByteArray(Charsets.UTF_8)) {
            hash = (hash xor (b.toLong() and 0xFF)) * 16777619L
            hash = hash and 0xFFFFFFFFL
        }
        return hash.toInt()
    }
}
