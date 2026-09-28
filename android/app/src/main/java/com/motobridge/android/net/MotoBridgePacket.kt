package com.motobridge.android.net

/**
 * Protocolo neutral de paquetes MotoBridge (ver PROTOCOL.md).
 * Debe ser idéntico al de iOS (MotoBridgePacket en LocalNetworkTransport.swift).
 *
 * Formato del datagrama de audio:
 *   byte 0     : magic 'M' (0x4D)
 *   byte 1     : version (0x01)
 *   byte 2     : tipo (0x01 = audio PCM)
 *   byte 3     : reservado (0x00)
 *   bytes 4..N : PCM Int16 little-endian, mono, 8 kHz
 */
object MotoBridgePacket {
    const val MAGIC: Byte = 0x4D        // 'M'
    const val VERSION: Byte = 0x01
    const val TYPE_AUDIO: Byte = 0x01
    private const val HEADER_SIZE = 4

    /** Envuelve muestras PCM en un datagrama con la cabecera del protocolo. */
    fun encodeAudio(pcm: ByteArray, length: Int = pcm.size): ByteArray {
        val out = ByteArray(HEADER_SIZE + length)
        out[0] = MAGIC
        out[1] = VERSION
        out[2] = TYPE_AUDIO
        out[3] = 0x00
        System.arraycopy(pcm, 0, out, HEADER_SIZE, length)
        return out
    }

    /**
     * Extrae el payload PCM de un datagrama recibido, o null si no es un
     * paquete de audio válido.
     */
    fun decodeAudio(packet: ByteArray, length: Int): ByteArray? {
        if (length <= HEADER_SIZE) return null
        if (packet[0] != MAGIC) return null
        if (packet[2] != TYPE_AUDIO) return null
        return packet.copyOfRange(HEADER_SIZE, length)
    }
}
