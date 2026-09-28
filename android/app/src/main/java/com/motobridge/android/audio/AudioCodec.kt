package com.motobridge.android.audio

/**
 * Códec de audio para el transporte. Igual que en iOS: cada paquete lleva 1 byte
 * de cabecera de códec (0x00 = PCM, 0x01 = Opus) para que el receptor sepa cómo
 * decodificar y convivan dispositivos con/sin Opus.
 */
interface AudioCodec {
    val codecId: Byte
    /** Comprime PCM Int16 mono (bytes LE) -> bytes. */
    fun encode(pcm: ByteArray): ByteArray
    /** Descomprime -> PCM Int16 mono (bytes LE), o null si falla. */
    fun decode(bytes: ByteArray): ByteArray?
}

object CodecId {
    const val PCM: Byte = 0x00
    const val OPUS: Byte = 0x01
}

/** Passthrough PCM: no comprime. Garantiza que el pipeline siempre funcione. */
class PcmCodec : AudioCodec {
    override val codecId = CodecId.PCM
    override fun encode(pcm: ByteArray) = pcm
    override fun decode(bytes: ByteArray) = bytes
}
