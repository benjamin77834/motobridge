package com.motobridge.android.net

/**
 * Nombre efectivo del rider (misma regla que iOS/Mac, ver .kiro/specs/unique-rider-name).
 * Por defecto "Android-XXXX" con XXXX derivado del UID propio de la app
 * (ANDROID_ID o UUID guardado), sin permisos nuevos.
 */
object RiderName {
    const val MAX_LENGTH = 60
    const val MAX_CUSTOM_LENGTH = 30
    const val KEY_NAME = "riderName"
    const val KEY_COLLISION = "riderNameCollision"

    fun suffix(uid: String, length: Int = 4): String {
        val s = uid.uppercase().filter { it.code < 128 && it.isLetterOrDigit() }.take(length)
        return s.padEnd(length, '0')
    }

    fun automatic(prefix: String, uid: String) = "$prefix-${suffix(uid)}"

    fun sanitize(raw: String) = raw.take(MAX_CUSTOM_LENGTH).trim()

    fun effective(saved: String?, prefix: String, uid: String, collision: Boolean): String {
        val custom = sanitize(saved ?: "")
        val sfx = suffix(uid)
        val name = if (custom.isEmpty()) {
            if (collision) "$prefix-${suffix(uid, 8)}" else automatic(prefix, uid)
        } else if (collision && !custom.endsWith("-$sfx")) "$custom-$sfx" else custom
        return name.take(MAX_LENGTH)
    }

    fun collides(local: String, peers: Collection<String>) = peers.contains(local)
}

/** Almacén mínimo (SharedPreferences en la app, un mapa en las pruebas). */
interface KeyValueStore {
    fun getString(key: String): String?
    fun getInt(key: String): Int
    fun getBoolean(key: String): Boolean
    fun putString(key: String, value: String)
    fun putInt(key: String, value: Int)
    fun putBoolean(key: String, value: Boolean)
}

/**
 * Cuándo preguntar "¿Cuál es tu nombre?": solo sin nombre propio guardado y
 * máximo 2 veces en total (al abrir y un recordatorio al iniciar el bridge).
 * Nunca bloquea el audio.
 */
class RiderNamePromptPolicy(private val store: KeyValueStore) {
    enum class Trigger { APP_OPEN, BRIDGE_START }

    val hasOwnName get() = RiderName.sanitize(store.getString(RiderName.KEY_NAME) ?: "").isNotEmpty()
    val promptCount get() = store.getInt(KEY_COUNT)

    fun shouldPrompt(trigger: Trigger): Boolean {
        if (hasOwnName || promptCount >= MAX_PROMPTS) return false
        return when (trigger) {
            Trigger.APP_OPEN -> promptCount == 0
            Trigger.BRIDGE_START -> true
        }
    }

    fun markShown() = store.putInt(KEY_COUNT, promptCount + 1)

    /** Vacío = omitido (no guarda). Devuelve si guardó. */
    fun save(name: String): Boolean {
        val clean = RiderName.sanitize(name)
        if (clean.isEmpty()) return false
        store.putString(RiderName.KEY_NAME, clean)
        return true
    }

    companion object {
        const val MAX_PROMPTS = 2
        const val KEY_COUNT = "riderNamePromptCount"
    }
}
