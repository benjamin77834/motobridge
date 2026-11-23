package com.motobridge.android.net

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class PeerCapabilitiesTest {
    private fun parse(s: String) = PresenceCodec.parse(s.toByteArray())
    private fun ok(s: String) = (parse(s) as PresenceCodec.Result.Ok).parsed

    // Casos de .kiro/specs/protocol-capabilities-baseline/vectors/presence-vectors.txt
    @Test fun vectors() {
        assertTrue(ok("Ana").isLegacy)
        val b = ok("Ana\nALT=12.50\nBAT=80\nPV=2\nID=0A1B2C3D\nCAP=HB,SEQ")
        assertEquals(2, b.pv); assertEquals(0x0A1B2C3DL, b.originId)
        assertEquals(setOf("HB", "SEQ"), b.caps); assertEquals(12.5, b.alt!!, 0.0); assertEquals(80, b.bat)
        val c = ok("Ana\nPV=9\nID=ZZZZZZZZ\nCAP=XYZ,HB\nFOO=1")
        assertEquals("Ana", c.name); assertEquals(9, c.pv); assertNull(c.originId); assertEquals(setOf("HB", "XYZ"), c.caps)
        val d = ok("Ana\n\nbasura\nPV=2")
        assertEquals("Ana", d.name); assertEquals(2, d.pv)
        val e = ok("Ana\nPV=x\nID=0A1B2C3D")
        assertTrue(e.isLegacy); assertEquals(0x0A1B2C3DL, e.originId)
        assertTrue(parse("\nPV=2") is PresenceCodec.Result.Invalid)
    }

    @Test fun nonUtf8LaterLineIgnored() {
        val bytes = "Ana\n".toByteArray() + byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + "\nPV=2".toByteArray()
        val p = (PresenceCodec.parse(bytes) as PresenceCodec.Result.Ok).parsed
        assertEquals("Ana", p.name); assertEquals(2, p.pv)
    }

    @Test fun oversizeDiscarded() {
        assertTrue(parse("Ana\n" + "X".repeat(600)) is PresenceCodec.Result.Oversize)
    }

    @Test fun emittedPresenceFits() {
        val text = "a".repeat(24) + "\nALT=1234.56\nBAT=100\n" + PresenceCodec.capabilityLines(0x7BCDEF01)
        assertTrue(text.toByteArray().size <= 200)
        assertTrue(PresenceCodec.capabilityLines(1).length <= 80)
        assertEquals(0x7BCDEF01L, ok(text).originId)
    }

    @Test fun tableLimitsExpiryAndLegacyDefault() {
        var now = 0L
        val t = CapabilityTable { now }
        assertEquals(1, t.protocolVersion("x"))
        assertFalse(t.allNeighborsSupport("HB", listOf("x")))
        for (i in 0 until 40) t.update("n$i", PresenceCodec.Parsed("A", pv = 2, originId = i + 1L), true)
        assertEquals(CapabilityTable.MAX_NEIGHBORS, t.neighborCount())
        assertEquals(CapabilityTable.MAX_ORIGINS, t.originCount())
        t.retainNeighbors(emptySet()); assertEquals(0, t.neighborCount())
        now += 31_000; assertEquals(0, t.originCount())
    }

    @Test fun latestPresenceWins() {
        val t = CapabilityTable()
        t.update("x", PresenceCodec.Parsed("A", pv = 2, originId = 5, caps = setOf("HB")), false)
        t.update("x", PresenceCodec.Parsed("A", pv = 2, originId = 5), false)
        assertFalse(t.originSupports(5, "HB"))
    }

    @Test fun legacyCounterWindow() {
        var now = 0L
        val c = LegacyPeerCounter(clock = { now })
        c.noteLegacy("Dani"); assertEquals(1, c.count())
        now += 13L * 86_400_000; assertEquals(1, c.count())
        now += 2L * 86_400_000; assertEquals(0, c.count())
    }

    @Test fun hotspotStringsHaveNoForbiddenClaims() {
        val xml = File("src/main/res/values/strings.xml").readText()
        val text = Regex("<string name=\"hotspot_[^>]*>(.*?)</string>").findAll(xml).joinToString("\n") { it.groupValues[1] }.lowercase()
        assertTrue(text.isNotEmpty())
        for (w in listOf("garantiza", "hasta ", "metros", "mejora el alcance", "%")) assertFalse(w, text.contains(w))
    }
}
