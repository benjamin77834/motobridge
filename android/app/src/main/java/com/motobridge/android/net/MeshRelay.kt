package com.motobridge.android.net

import kotlin.random.Random

/**
 * Relay de malla (mesh) multi-salto: cada dispositivo reenvía a sus vecinos el
 * audio recibido de otros, extendiendo el alcance encadenando motos.
 * Debe ser compatible con el MeshRelay de iOS (misma cabecera).
 *
 * Cabecera (big-endian): originId(4) + packetId(4) + ttl(1) + payload.
 */
class MeshRelay {
    companion object {
        const val HEADER_SIZE = 9
        // Saltos máximos del mesh. 6 permite caravanas más largas (hasta ~6 motos
        // encadenadas repitiendo la señal). Debe ser igual en iOS y Android.
        const val DEFAULT_TTL: Int = 6
    }

    val localOriginId: Int = Random.nextInt(1, Int.MAX_VALUE)
    private var nextPacketId = 0

    private val seen = LinkedHashSet<Long>()
    private val maxSeen = 2048

    data class Incoming(val payload: ByteArray, val isNew: Boolean, val relay: ByteArray?)

    @Synchronized
    fun wrapOutgoing(payload: ByteArray, ttl: Int = DEFAULT_TTL): ByteArray {
        nextPacketId++
        markSeen(localOriginId, nextPacketId)
        return pack(localOriginId, nextPacketId, ttl, payload)
    }

    @Synchronized
    fun processIncoming(data: ByteArray): Incoming? {
        if (data.size <= HEADER_SIZE) return null
        val origin = readInt(data, 0)
        val packet = readInt(data, 4)
        val ttl = data[8].toInt() and 0xFF
        val payload = data.copyOfRange(HEADER_SIZE, data.size)

        val key = (origin.toLong() shl 32) or (packet.toLong() and 0xFFFFFFFFL)
        if (seen.contains(key)) return Incoming(payload, false, null)
        markSeen(origin, packet)

        val relay = if (ttl > 1) pack(origin, packet, ttl - 1, payload) else null
        return Incoming(payload, true, relay)
    }

    private fun markSeen(origin: Int, packet: Int) {
        val key = (origin.toLong() shl 32) or (packet.toLong() and 0xFFFFFFFFL)
        seen.add(key)
        if (seen.size > maxSeen) {
            val it = seen.iterator()
            if (it.hasNext()) { it.next(); it.remove() }
        }
    }

    private fun pack(origin: Int, packet: Int, ttl: Int, payload: ByteArray): ByteArray {
        val out = ByteArray(HEADER_SIZE + payload.size)
        writeInt(out, 0, origin)
        writeInt(out, 4, packet)
        out[8] = (ttl and 0xFF).toByte()
        System.arraycopy(payload, 0, out, HEADER_SIZE, payload.size)
        return out
    }

    private fun writeInt(b: ByteArray, off: Int, v: Int) {
        b[off] = ((v shr 24) and 0xFF).toByte()
        b[off + 1] = ((v shr 16) and 0xFF).toByte()
        b[off + 2] = ((v shr 8) and 0xFF).toByte()
        b[off + 3] = (v and 0xFF).toByte()
    }

    private fun readInt(b: ByteArray, off: Int): Int {
        return ((b[off].toInt() and 0xFF) shl 24) or
               ((b[off + 1].toInt() and 0xFF) shl 16) or
               ((b[off + 2].toInt() and 0xFF) shl 8) or
               (b[off + 3].toInt() and 0xFF)
    }
}
