package com.motobridge.android.net

/**
 * Encabezado de canal de voz (compatible con iOS VoiceChannel).
 *
 * Formato clásico (5 bytes) para group/private/alarm/text:
 *   tipo(1) + targetId(4, big-endian) + payload
 *   tipo: 0=grupo, 1=privado, 2=alarma, 3=texto
 *
 * Formato subgrupo (varios destinatarios):
 *   tipo(1=4) + subtipo(1: 0=audio,1=texto) + count(1) + count*4 targetIds + payload
 */
object VoiceChannel {
    const val HEADER = 5
    const val GROUP: Byte = 0
    const val PRIVATE: Byte = 1
    const val ALARM: Byte = 2
    const val TEXT: Byte = 3
    const val SUBGROUP: Byte = 4

    // MARK: - Formato clásico (1 destinatario)

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

    // MARK: - Formato subgrupo (varios destinatarios)

    fun wrapSubgroup(payload: ByteArray, targets: IntArray, isText: Boolean): ByteArray {
        val count = minOf(targets.size, 255)
        val out = ByteArray(3 + count * 4 + payload.size)
        out[0] = SUBGROUP
        out[1] = if (isText) 1 else 0
        out[2] = count.toByte()
        var i = 3
        for (n in 0 until count) {
            val id = targets[n]
            out[i] = ((id shr 24) and 0xFF).toByte()
            out[i + 1] = ((id shr 16) and 0xFF).toByte()
            out[i + 2] = ((id shr 8) and 0xFF).toByte()
            out[i + 3] = (id and 0xFF).toByte()
            i += 4
        }
        System.arraycopy(payload, 0, out, i, payload.size)
        return out
    }

    data class Msg(
        val type: Byte,
        val targetId: Int,
        val audio: ByteArray,
        val targets: IntArray = IntArray(0),
        val isText: Boolean = false
    )

    fun unwrap(data: ByteArray): Msg? {
        if (data.isEmpty()) return null
        val type = data[0]

        if (type == SUBGROUP) {
            if (data.size <= 3) return null
            val isText = data[1].toInt() == 1
            val count = data[2].toInt() and 0xFF
            val idsStart = 3
            val payloadStart = idsStart + count * 4
            if (data.size <= payloadStart) return null
            val ids = IntArray(count)
            var i = idsStart
            for (n in 0 until count) {
                ids[n] = ((data[i].toInt() and 0xFF) shl 24) or
                         ((data[i + 1].toInt() and 0xFF) shl 16) or
                         ((data[i + 2].toInt() and 0xFF) shl 8) or
                         (data[i + 3].toInt() and 0xFF)
                i += 4
            }
            val payload = data.copyOfRange(payloadStart, data.size)
            return Msg(type, 0, payload, ids, isText)
        }

        // Formato clásico (5 bytes).
        if (data.size <= HEADER) return null
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
