package com.motobridge.android.net

import org.junit.Assert.*
import org.junit.Test

class RiderNameTest {
    private val uidA = "3f9a1c22b7d04e11"
    private val uidB = "7b01d5e9aa00c3f2"

    private class MapStore : KeyValueStore {
        val m = mutableMapOf<String, Any>()
        override fun getString(key: String) = m[key] as? String
        override fun getInt(key: String) = m[key] as? Int ?: 0
        override fun getBoolean(key: String) = m[key] as? Boolean ?: false
        override fun putString(key: String, value: String) { m[key] = value }
        override fun putInt(key: String, value: Int) { m[key] = value }
        override fun putBoolean(key: String, value: Boolean) { m[key] = value }
    }

    // --- generación ---
    @Test fun suffixIsFourUppercaseAlphanumerics() {
        assertEquals("3F9A", RiderName.suffix(uidA))
        assertEquals("ABCD", RiderName.suffix("ab-cd-ef"))
        assertEquals("A000", RiderName.suffix("a"))
    }
    @Test fun automaticNameDiffersPerDevice() {
        assertEquals("Android-3F9A", RiderName.automatic("Android", uidA))
        assertNotEquals(RiderName.effective(null, "Android", uidA, false),
                        RiderName.effective("", "Android", uidB, false))
    }
    @Test fun savedNameWinsAndIsTruncated() {
        assertEquals("Ben", RiderName.effective(" Ben ", "Android", uidA, false))
        assertEquals(30, RiderName.effective("x".repeat(80), "Android", uidA, false).length)
    }
    @Test fun uniqueNamesGiveDifferentPrivateIds() {
        assertNotEquals(VoiceChannel.idFor(RiderName.automatic("Android", uidA)),
                        VoiceChannel.idFor(RiderName.automatic("Android", uidB)))
    }

    // --- colisiones ---
    @Test fun collisionDetectionAndSuffix() {
        assertTrue(RiderName.collides("Ben", listOf("Ana", "Ben")))
        assertFalse(RiderName.collides("Ben", listOf("Ana")))
        assertEquals("Ben-3F9A", RiderName.effective("Ben", "Android", uidA, true))
        assertEquals("Ben-3F9A", RiderName.effective("Ben-3F9A", "Android", uidA, true))
        assertEquals("Android-3F9A1C22", RiderName.effective(null, "Android", uidA, true))
    }

    // --- pregunta de primer arranque ---
    @Test fun promptsWhenNoOwnName() {
        val p = RiderNamePromptPolicy(MapStore())
        assertTrue(p.shouldPrompt(RiderNamePromptPolicy.Trigger.APP_OPEN))
        assertTrue(p.shouldPrompt(RiderNamePromptPolicy.Trigger.BRIDGE_START))
    }
    @Test fun neverPromptsWithSavedName() {
        val s = MapStore(); val p = RiderNamePromptPolicy(s)
        assertTrue(p.save("Ben"))
        assertFalse(p.shouldPrompt(RiderNamePromptPolicy.Trigger.APP_OPEN))
        assertFalse(p.shouldPrompt(RiderNamePromptPolicy.Trigger.BRIDGE_START))
        s.putString(RiderName.KEY_NAME, "Piloto 1")  // nombre de versión anterior
        assertFalse(RiderNamePromptPolicy(s).shouldPrompt(RiderNamePromptPolicy.Trigger.APP_OPEN))
    }
    @Test fun blankIsSkippedNotSaved() {
        val p = RiderNamePromptPolicy(MapStore())
        assertFalse(p.save("   "))
        assertFalse(p.hasOwnName)
    }
    @Test fun skippedOnceRemindsOnlyAtBridgeStart() {
        val p = RiderNamePromptPolicy(MapStore())
        p.markShown()
        assertFalse(p.shouldPrompt(RiderNamePromptPolicy.Trigger.APP_OPEN))
        assertTrue(p.shouldPrompt(RiderNamePromptPolicy.Trigger.BRIDGE_START))
    }
    @Test fun maximumTwoPrompts() {
        val p = RiderNamePromptPolicy(MapStore())
        p.markShown(); p.markShown()
        assertEquals(2, p.promptCount)
        assertFalse(p.shouldPrompt(RiderNamePromptPolicy.Trigger.APP_OPEN))
        assertFalse(p.shouldPrompt(RiderNamePromptPolicy.Trigger.BRIDGE_START))
    }
}
