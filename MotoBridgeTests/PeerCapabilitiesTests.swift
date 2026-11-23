import XCTest
@testable import MotoBridge

final class PeerCapabilitiesTests: XCTestCase {
    private func parse(_ s: String) -> PresenceCodec.ParseResult {
        PresenceCodec.parse(Data(s.utf8))
    }

    // Casos de .kiro/specs/protocol-capabilities-baseline/vectors/presence-vectors.txt
    func testVectors() {
        guard case .ok(let a) = parse("Ana") else { return XCTFail() }
        XCTAssertEqual(a.name, "Ana"); XCTAssertTrue(a.isLegacy)

        guard case .ok(let b) = parse("Ana\nALT=12.50\nBAT=80\nPV=2\nID=0A1B2C3D\nCAP=HB,SEQ") else { return XCTFail() }
        XCTAssertEqual(b.pv, 2); XCTAssertEqual(b.originId, 0x0A1B2C3D)
        XCTAssertEqual(b.caps, ["HB", "SEQ"]); XCTAssertEqual(b.alt, 12.5); XCTAssertEqual(b.bat, 80)

        guard case .ok(let c) = parse("Ana\nPV=9\nID=ZZZZZZZZ\nCAP=XYZ,HB\nFOO=1") else { return XCTFail() }
        XCTAssertEqual(c.name, "Ana"); XCTAssertEqual(c.pv, 9)
        XCTAssertNil(c.originId); XCTAssertEqual(c.caps, ["HB", "XYZ"])

        guard case .ok(let d) = parse("Ana\n\nbasura\nPV=2") else { return XCTFail() }
        XCTAssertEqual(d.name, "Ana"); XCTAssertEqual(d.pv, 2)

        guard case .ok(let e) = parse("Ana\nPV=x\nID=0A1B2C3D") else { return XCTFail() }
        XCTAssertTrue(e.isLegacy); XCTAssertEqual(e.originId, 0x0A1B2C3D)

        XCTAssertEqual(parse("\nPV=2"), .invalid)
    }

    func testNonUTF8LaterLineIgnored() {
        var d = Data("Ana\n".utf8); d.append(contentsOf: [0xFF, 0xFE]); d.append(Data("\nPV=2".utf8))
        guard case .ok(let p) = PresenceCodec.parse(d) else { return XCTFail() }
        XCTAssertEqual(p.name, "Ana"); XCTAssertEqual(p.pv, 2)
    }

    func testOversizeDiscarded() {
        XCTAssertEqual(parse("Ana\n" + String(repeating: "X", count: 600)), .oversize)
    }

    func testEmittedPresenceFitsAndKeepsFirstLine() {
        let name = String(repeating: "a", count: 24)
        let text = name + "\nALT=1234.56\nBAT=100\n" + PresenceCodec.capabilityLines(originId: 0xABCDEF01)
        XCTAssertLessThanOrEqual(text.utf8.count, 200)
        XCTAssertTrue(text.hasPrefix(name + "\n"))
        guard case .ok(let p) = parse(text) else { return XCTFail() }
        XCTAssertEqual(p.originId, 0xABCDEF01); XCTAssertEqual(p.pv, PresenceCodec.protocolVersion)
        XCTAssertLessThanOrEqual(PresenceCodec.capabilityLines(originId: 1).utf8.count, 80)
    }

    func testTableNeighborsAndLegacyDefault() {
        let t = CapabilityTable()
        XCTAssertEqual(t.protocolVersion(neighbor: "x"), 1)
        XCTAssertFalse(t.allNeighborsSupport("HB", connected: ["x"]))
        let p = PresenceCodec.Parsed(name: "A", pv: 2, originId: 7, caps: ["HB"])
        t.update(neighborId: "x", parsed: p, direct: true)
        XCTAssertTrue(t.neighborSupports("x", "HB"))
        XCTAssertTrue(t.allNeighborsSupport("HB", connected: ["x"]))
        XCTAssertFalse(t.allNeighborsSupport("HB", connected: ["x", "y"]))
        t.retainNeighbors([])
        XCTAssertEqual(t.neighborCount, 0)
    }

    func testTableLimitsAndOriginExpiry() {
        var now = Date()
        let t = CapabilityTable(clock: { now })
        for i in 0..<40 {
            t.update(neighborId: "n\(i)", parsed: .init(name: "A", pv: 2, originId: UInt32(i + 1), caps: []), direct: true)
        }
        XCTAssertEqual(t.neighborCount, CapabilityTable.maxNeighbors)
        XCTAssertEqual(t.originCount, CapabilityTable.maxOrigins)
        now = now.addingTimeInterval(31)
        XCTAssertEqual(t.originCount, 0)
    }

    func testLatestPresenceWins() {
        let t = CapabilityTable()
        t.update(neighborId: "x", parsed: .init(name: "A", pv: 2, originId: 5, caps: ["HB"]), direct: false)
        t.update(neighborId: "x", parsed: .init(name: "A", pv: 2, originId: 5, caps: []), direct: false)
        XCTAssertFalse(t.originSupports(5, "HB"))
    }

    func testLegacyCounterWindow() {
        var now = Date()
        let c = LegacyPeerCounter(clock: { now })
        c.noteLegacy(name: "Dani")
        XCTAssertEqual(c.count, 1)
        now = now.addingTimeInterval(13 * 86_400)
        XCTAssertEqual(c.count, 1)
        now = now.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(c.count, 0)
    }
}

private extension PresenceCodec.Parsed {
    init(name: String, pv: Int?, originId: UInt32?, caps: Set<String>) {
        self.init(name: name, alt: nil, bat: nil, pv: pv, originId: originId, caps: caps)
    }
}

final class HotspotGuideContentTests: XCTestCase {
    func testNoForbiddenClaims() {
        let text = HotspotGuideContent.allText.lowercased()
        for banned in ["garantiza", "hasta ", "metros", "mejora el alcance", "%"] {
            XCTAssertFalse(text.contains(banned), banned)
        }
    }
}
