import XCTest
@testable import MotoBridge

final class AudioBridgeTests: XCTestCase {

    func testBridgeStartsIdle() {
        let bridge = AudioBridge()
        XCTAssertEqual(bridge.state, .idle)
        XCTAssertNil(bridge.unavailabilityReason.userMessage)
    }

    func testPrepareReportsIOSLimitation() {
        // Con el hardware objetivo, prepare() debe reflejar la limitación de iOS
        // (bridge BT↔BT no viable) en lugar de simular un estado listo.
        let bridge = AudioBridge()
        bridge.prepare()
        XCTAssertEqual(bridge.state, .error)
        XCTAssertEqual(
            bridge.unavailabilityReason.userMessage,
            "El sistema operativo no permite esta configuración de audio Bluetooth."
        )
    }

    func testStopReturnsToIdle() {
        let bridge = AudioBridge()
        bridge.prepare()
        bridge.stop()
        XCTAssertEqual(bridge.state, .idle)
        XCTAssertNil(bridge.unavailabilityReason.userMessage)
    }
}

final class LoggerTests: XCTestCase {

    func testExportTextContainsHeader() {
        let text = Logger.shared.exportText()
        XCTAssertTrue(text.contains("MotoBridge — Diagnostic Export"))
    }
}

final class DeviceTests: XCTestCase {

    func testFreedConnIdentity() {
        let d = FreedConnDevice()
        XCTAssertEqual(d.manufacturer, .freedConn)
        XCTAssertEqual(d.model, "T-COM VB")
        XCTAssertFalse(d.capabilities.mfiCertified)
    }

    func testHysnoxIdentity() {
        let d = HysnoxDevice()
        XCTAssertEqual(d.manufacturer, .hysnox)
        XCTAssertEqual(d.connectionState, .disconnected)
    }

    func testUpdateFromAudioRoute() {
        let d = HysnoxDevice()
        d.updateFromAudioRoute(isPresentInRoute: true)
        XCTAssertEqual(d.connectionState, .connected)
        d.updateFromAudioRoute(isPresentInRoute: false)
        XCTAssertEqual(d.connectionState, .disconnected)
    }
}
