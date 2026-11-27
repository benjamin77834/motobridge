import XCTest
@testable import MotoBridge

private final class FakeBridge: BridgeControlling {
    var isRunning = true
    var isTransmitting = false
    var alarmActive = false
    var connectedPeerNames: [String] = []
    var canStartRemotely = true
    var calls: [String] = []

    func setMic(_ open: Bool) {
        calls.append("setMic(\(open))")
        // Igual que setTransmitting: el estado cambia en un salto de cola posterior.
        DispatchQueue.main.async { self.isTransmitting = open }
    }
    func triggerAlarm() { calls.append("alarm"); alarmActive = true }
    func startBridge() { calls.append("start"); isRunning = true }
    func stopBridge() { calls.append("stop"); isRunning = false }
}

final class WatchCommandHandlerTests: XCTestCase {
    private var bridge: FakeBridge!
    private var handler: WatchCommandHandler!

    override func setUp() {
        bridge = FakeBridge()
        handler = WatchCommandHandler(bridge: bridge)
    }

    private func send(_ m: [String: Any]) -> WatchReply {
        let e = expectation(description: "reply")
        var out: WatchReply?
        handler.handle(m) { out = WatchReply.parse($0); e.fulfill() }
        wait(for: [e], timeout: 2)
        return out!
    }

    private func cmd(_ name: String, id: String = UUID().uuidString, open: Bool? = nil) -> [String: Any] {
        var m: [String: Any] = ["v": 1, "cmd": name, "id": id]
        if let open { m["open"] = open }
        return m
    }

    func testGetState() {
        bridge.connectedPeerNames = ["Ana", "Luis"]
        let r = send(["v": 1, "cmd": "getState"])
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.state?.peerCount, 2)
        XCTAssertEqual(r.state?.peers, ["Ana", "Luis"])
        XCTAssertEqual(r.state?.running, true)
    }

    func testVersionAndBadRequest() {
        XCTAssertEqual(send(["v": 9, "cmd": "alarm", "id": "1"]).err, .unsupportedVersion)
        XCTAssertEqual(send(["v": 1, "cmd": "nope", "id": "1"]).err, .badRequest)
        XCTAssertEqual(send(["v": 1, "cmd": "setMic", "id": "1"]).err, .badRequest)
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testSetMicOpenWhenStopped() {
        bridge.isRunning = false
        XCTAssertEqual(send(cmd("setMic", open: true)).err, .notRunning)
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testSetMicCloseWhenStoppedIsOk() {
        bridge.isRunning = false
        let r = send(cmd("setMic", open: false))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.note, .noChange)
    }

    func testSetMicRepliesWithStateAfterAction() {
        let r = send(cmd("setMic", open: true))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(bridge.calls, ["setMic(true)"])
        XCTAssertEqual(r.state?.mic, true)
        let again = send(cmd("setMic", open: true))
        XCTAssertEqual(again.note, .noChange)
        XCTAssertEqual(bridge.calls.count, 1)
    }

    func testAlarmRules() {
        bridge.isRunning = false
        XCTAssertEqual(send(cmd("alarm")).err, .notRunning)
        bridge.isRunning = true
        XCTAssertTrue(send(cmd("alarm")).ok)
        XCTAssertEqual(bridge.calls, ["alarm"])
        let r = send(cmd("alarm"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.note, .alreadyActive)
        XCTAssertEqual(bridge.calls, ["alarm"])
    }

    func testDuplicateIdExecutesOnce() {
        let m = cmd("alarm", id: "same")
        let first = send(m)
        bridge.alarmActive = false   // aunque el estado cambie, no se vuelve a ejecutar
        let second = send(m)
        XCTAssertEqual(bridge.calls, ["alarm"])
        XCTAssertEqual(first, second)
    }

    func testStartRules() {
        bridge.isRunning = false
        bridge.canStartRemotely = false
        XCTAssertEqual(send(cmd("startBridge")).err, .needsPhone)
        XCTAssertTrue(bridge.calls.isEmpty)
        bridge.canStartRemotely = true
        XCTAssertTrue(send(cmd("startBridge")).ok)
        XCTAssertEqual(bridge.calls, ["start"])
        XCTAssertEqual(send(cmd("startBridge")).note, .noChange)
        XCTAssertEqual(bridge.calls, ["start"])
    }

    func testStopRules() {
        XCTAssertTrue(send(cmd("stopBridge")).ok)
        XCTAssertEqual(bridge.calls, ["stop"])
        XCTAssertEqual(send(cmd("stopBridge")).note, .noChange)
        XCTAssertEqual(bridge.calls, ["stop"])
    }

    func testSeqStrictlyIncreasing() {
        let fixed = Date(timeIntervalSince1970: 1000)
        let h = WatchCommandHandler(bridge: bridge, now: { fixed })
        let a = h.makeState().seq, b = h.makeState().seq
        XCTAssertGreaterThan(b, a)
    }
}
