package com.motobridge.android.net

/**
 * Encabezado de canal de voz (compatible con iOS VoiceChannel).
 *
 * Lleva un byte MAGIC al inicio para distinguir un canal real de datos crudos o
 * de paquetes mal alineados. Si el magic no coincide, el paquete NO se trata
 * como canal (evita que ruido se interprete como alarma, etc.).
 *
 * Formato clásico (6 bytes) para group/private/alarm/text/presence:
 *   magic(1=0x56 'V') + tipo(1) + targetId(4, big-endian) + payload
 *
 * Formato subgrupo:
 *   magic(1) + tipo(1=4) + subtipo(1: 0=audio,1=texto) + count(1) + count*4 ids + payload
 */
object VoiceChannel {
    const val MAGIC: Byte = 0x56  // 'V'
    const val HEADER = 6          // magic + tipo + 4 targetId
    const val GROUP: Byte = 0
    const val PRIVATE: Byte = 1
    const val ALARM: Byte = 2
    const val TEXT: Byte = 3
    const val SUBGROUP: Byte = 4
    const val PRESENCE: Byte = 5

    fun wrap(audio: ByteArray, type: Byte, targetId: Int): ByteArray {
        val out = ByteArray(HEADER + audio.size)
        out[0] = MAGIC
        out[1] = type
        out[2] = ((targetId shr 24) and 0xFF).toByte()
        out[3] = ((targetId shr 16) and 0xFF).toByte()
        out[4] = ((targetId shr 8) and 0xFF).toByte()
        out[5] = (targetId and 0xFF).toByte()
        System.arraycopy(audio, 0, out, HEADER, audio.size)
        return out
    }

    fun wrapSubgroup(payload: ByteArray, targets: IntArray, isText: Boolean): ByteArray {
        val count = minOf(targets.size, 255)
        val out = ByteArray(4 + count * 4 + payload.size)
        out[0] = MAGIC
        out[1] = SUBGROUP
        out[2] = if (isText) 1 else 0
        out[3] = count.toByte()
        var i = 4
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
        // Sin magic válido NO es un canal (se tratará como audio crudo de grupo).
        if (data.size < 2 || data[0] != MAGIC) return null
        val type = data[1]

        if (type == SUBGROUP) {
            if (data.size <= 4) return null
            val isText = data[2].toInt() == 1
            val count = data[3].toInt() and 0xFF
            val idsStart = 4
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

        // Formato clásico (6 bytes). Validar que el tipo sea conocido.
        if (data.size <= HEADER) return null
        if (type != GROUP && type != PRIVATE && type != ALARM && type != TEXT && type != PRESENCE) return null
        val target = ((data[2].toInt() and 0xFF) shl 24) or
                     ((data[3].toInt() and 0xFF) shl 16) or
                     ((data[4].toInt() and 0xFF) shl 8) or
                     (data[5].toInt() and 0xFF)
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
