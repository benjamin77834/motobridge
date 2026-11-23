package com.motobridge.android.net

/**
 * Versión y capacidades de protocolo en la presencia (spec protocol-capabilities-baseline).
 * Mismo formato y reglas que MotoBridge/Core/Network/PeerCapabilities.swift.
 *
 * Payload: <nombre>\n[ALT=..]\n[BAT=..]\nPV=<n>\nID=<8 hex>\nCAP=<a,b,c>
 */
object PresenceCodec {
    const val PROTOCOL_VERSION = 2
    const val MAX_PAYLOAD_BYTES = 512

    /** Tokens anunciados por este build. Vacío en este spec (TEST solo en pruebas). */
    val localCapabilities: List<String> = emptyList()

    data class Parsed(
        val name: String,
        val alt: Double? = null,
        val bat: Int? = null,
        /** null = sin línea PV válida (protocolo 1, legacy). */
        val pv: Int? = null,
        val originId: Long? = null,
        val caps: Set<String> = emptySet()
    ) {
        val isLegacy: Boolean get() = pv == null
    }

    sealed class Result {
        data class Ok(val parsed: Parsed) : Result()
        object Oversize : Result()
        object Invalid : Result()
    }

    fun idString(id: Int): String = String.format("%08X", id)

    fun capabilityLines(originId: Int, caps: List<String> = localCapabilities): String =
        "PV=$PROTOCOL_VERSION\nID=${idString(originId)}\nCAP=${caps.joinToString(",")}"

    fun parse(payload: ByteArray): Result {
        if (payload.size > MAX_PAYLOAD_BYTES) return Result.Oversize
        // La decodificación UTF-8 de Java reemplaza bytes inválidos, no lanza excepción.
        val lines = String(payload, Charsets.UTF_8).split("\n")
        val name = lines.firstOrNull()?.trim().orEmpty()
        if (name.isEmpty()) return Result.Invalid
        var p = Parsed(name)
        for (line in lines.drop(1)) {
            when {
                line.startsWith("ALT=") -> p = p.copy(alt = line.removePrefix("ALT=").toDoubleOrNull())
                line.startsWith("BAT=") -> p = p.copy(bat = line.removePrefix("BAT=").toIntOrNull())
                line.startsWith("PV=") -> p = p.copy(pv = line.removePrefix("PV=").toIntOrNull())
                line.startsWith("ID=") -> {
                    val hex = line.removePrefix("ID=")
                    if (hex.length == 8) p = p.copy(originId = hex.toLongOrNull(16) ?: p.originId)
                }
                line.startsWith("CAP=") -> p = p.copy(
                    caps = line.removePrefix("CAP=").split(",")
                        .filter { t -> t.isNotEmpty() && t.all { it.isLetterOrDigit() && it.code < 128 } }
                        .toSet()
                )
            }
        }
        return Result.Ok(p)
    }
}

/** Tabla en memoria de capacidades por vecino directo y por origen. */
class CapabilityTable(private val clock: () -> Long = System::currentTimeMillis) {
    companion object {
        const val MAX_ORIGINS = 32
        const val MAX_NEIGHBORS = 5
        const val ORIGIN_TTL_MS = 30_000L
    }

    private data class Entry(val pv: Int, val caps: Set<String>, val lastSeen: Long)

    private val neighbors = HashMap<String, Entry>()
    private val origins = HashMap<Long, Entry>()

    @Synchronized
    fun update(neighborId: String, parsed: PresenceCodec.Parsed, direct: Boolean) {
        val now = clock()
        val entry = Entry(parsed.pv ?: 1, parsed.caps, now)
        if (direct && (neighbors.containsKey(neighborId) || neighbors.size < MAX_NEIGHBORS)) {
            neighbors[neighborId] = entry
        }
        parsed.originId?.let { id ->
            pruneOrigins(now)
            if (origins.containsKey(id) || origins.size < MAX_ORIGINS) origins[id] = entry
        }
    }

    @Synchronized fun retainNeighbors(connected: Set<String>) { neighbors.keys.retainAll(connected) }
    @Synchronized fun removeNeighbor(id: String) { neighbors.remove(id) }
    @Synchronized fun protocolVersion(neighbor: String): Int = neighbors[neighbor]?.pv ?: 1
    @Synchronized fun neighborSupports(id: String, cap: String): Boolean = neighbors[id]?.caps?.contains(cap) ?: false
    @Synchronized fun allNeighborsSupport(cap: String, connected: List<String>): Boolean =
        connected.all { neighbors[it]?.caps?.contains(cap) ?: false }
    @Synchronized fun originSupports(id: Long, cap: String): Boolean {
        pruneOrigins(clock()); return origins[id]?.caps?.contains(cap) ?: false
    }
    @Synchronized fun neighborCount(): Int = neighbors.size
    @Synchronized fun originCount(): Int { pruneOrigins(clock()); return origins.size }

    private fun pruneOrigins(now: Long) {
        origins.entries.removeAll { now - it.value.lastSeen > ORIGIN_TTL_MS }
    }
}

/** Cuenta localmente peers legacy (sin PV) vistos en 14 días. No sale del dispositivo. */
class LegacyPeerCounter(
    initial: Map<String, Long> = emptyMap(),
    private val clock: () -> Long = System::currentTimeMillis,
    private val save: ((Map<String, Long>) -> Unit)? = null
) {
    companion object { const val WINDOW_MS = 14L * 24 * 60 * 60 * 1000 }

    private val sightings = HashMap(initial)

    @Synchronized
    fun noteLegacy(name: String) {
        val now = clock()
        sightings[name] = now
        prune(now)
        save?.invoke(HashMap(sightings))
    }

    @Synchronized
    fun count(): Int { prune(clock()); return sightings.size }

    private fun prune(now: Long) { sightings.entries.removeAll { now - it.value > WINDOW_MS } }
}
