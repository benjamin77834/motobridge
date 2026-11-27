import XCTest
@testable import MotoBridge

final class WatchProtocolTests: XCTestCase {
    private func parse(_ m: [String: Any]) -> Result<WatchCommand, WatchErrorCode> { WatchCommand.parse(m) }

    func testParseValidCommands() {
        XCTAssertEqual(try? parse(["v": 1, "cmd": "getState"]).get().kind, .getState)
        let mic = try? parse(["v": 1, "cmd": "setMic", "id": "a", "open": true, "extra": 5]).get()
        XCTAssertEqual(mic, WatchCommand(kind: .setMic, id: "a", open: true))
        XCTAssertEqual(try? parse(["v": 1, "cmd": "alarm", "id": "x"]).get().kind, .alarm)
    }

    func testParseErrors() {
        XCTAssertEqual(parse(["cmd": "alarm", "id": "x"]), .failure(.unsupportedVersion))
        XCTAssertEqual(parse(["v": 2, "cmd": "alarm", "id": "x"]), .failure(.unsupportedVersion))
        XCTAssertEqual(parse(["v": 1, "cmd": "ptt", "id": "x"]), .failure(.badRequest))
        XCTAssertEqual(parse(["v": 1, "cmd": "alarm"]), .failure(.badRequest))
        XCTAssertEqual(parse(["v": 1, "cmd": "alarm", "id": ""]), .failure(.badRequest))
        XCTAssertEqual(parse(["v": 1, "cmd": "alarm", "id": String(repeating: "a", count: 65)]), .failure(.badRequest))
        XCTAssertNotNil(try? parse(["v": 1, "cmd": "alarm", "id": String(repeating: "a", count: 64)]).get())
        XCTAssertEqual(parse(["v": 1, "cmd": "setMic", "id": "x"]), .failure(.badRequest))
        XCTAssertEqual(parse(["v": 1, "cmd": "setMic", "id": "x", "open": "yes"]), .failure(.badRequest))
    }

    func testCommandMessageRoundTrip() {
        let c = WatchCommand(kind: .setMic, id: "id1", open: false)
        XCTAssertEqual(try? parse(c.message).get(), c)
    }

    func testStateRoundTripAndSanitize() {
        let s = WatchState(seq: 10, running: true, mic: false, alarm: true, peerCount: 12,
                           peerNames: ["Ana", "", "A\u{0007}B", String(repeating: "x", count: 40)] + (0..<8).map { "r\($0)" },
                           canStart: false)
        XCTAssertEqual(s.peers.count, 8)
        XCTAssertEqual(s.peers[0], "Ana")
        XCTAssertEqual(s.peers[1], "Rider")
        XCTAssertEqual(s.peers[2], "AB")
        XCTAssertEqual(s.peers[3].count, 24)
        XCTAssertEqual(s.peerCount, 12)
        XCTAssertEqual(WatchState.parse(s.dictionary), s)
    }

    func testStateParseRejectsInvalid() {
        let good = WatchState(seq: 1, running: false, mic: false, alarm: false, peerCount: 0, peerNames: [], canStart: true)
        var d = good.dictionary
        d["v"] = 2
        XCTAssertNil(WatchState.parse(d))
        d = good.dictionary; d["seq"] = "1"
        XCTAssertNil(WatchState.parse(d))
        d = good.dictionary; d["peers"] = (0..<9).map { "r\($0)" }
        XCTAssertNil(WatchState.parse(d))
    }

    func testStateStoreSequence() {
        func st(_ seq: Int) -> WatchState {
            WatchState(seq: seq, running: true, mic: false, alarm: false, peerCount: 0, peerNames: [], canStart: false)
        }
        var store = WatchStateStore()
        XCTAssertTrue(store.apply(st(5)))
        XCTAssertFalse(store.apply(st(5)))
        XCTAssertFalse(store.apply(st(4)))
        XCTAssertTrue(store.apply(st(6)))
        XCTAssertTrue(store.apply(st(2), resetFloor: true))
        XCTAssertEqual(store.current?.seq, 2)
        XCTAssertTrue(store.apply(st(3)))
    }

    func testReplyRoundTrip() {
        let s = WatchState(seq: 1, running: true, mic: true, alarm: false, peerCount: 1, peerNames: ["Ana"], canStart: true)
        let r = WatchReply(ok: false, err: .needsPhone, note: nil, state: s)
        XCTAssertEqual(WatchReply.parse(r.dictionary), r)
    }
}
