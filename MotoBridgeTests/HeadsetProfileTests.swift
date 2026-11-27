import XCTest
import AVFoundation
@testable import MotoBridge

final class HeadsetProfileTests: XCTestCase {
    private var suite: UserDefaults!
    private let suiteName = "HeadsetProfileTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        suite = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let a2dp = AVAudioSession.Port.bluetoothA2DP.rawValue
    private let hfp = AVAudioSession.Port.bluetoothHFP.rawValue

    func testKeyNormalizesNameCase() {
        XCTAssertEqual(HeadsetIdentity.key(portName: " AirPods Pro ", portType: hfp),
                       HeadsetIdentity.key(portName: "airpods pro", portType: hfp))
    }
    func testSameHeadsetSharesKeyAcrossA2DPAndHFP() {
        XCTAssertEqual(HeadsetIdentity.key(portName: "AirPods Pro", portType: a2dp),
                       HeadsetIdentity.key(portName: "AirPods Pro", portType: hfp))
    }
    func testDifferentNamesOrFamiliesDiffer() {
        XCTAssertNotEqual(HeadsetIdentity.key(portName: "AirPods Pro", portType: hfp),
                          HeadsetIdentity.key(portName: "Beats Fit", portType: hfp))
        XCTAssertNotEqual(HeadsetIdentity.key(portName: "Headset", portType: hfp),
                          HeadsetIdentity.key(portName: "Headset", portType: AVAudioSession.Port.headsetMic.rawValue))
    }
    func testBuiltInPortsAndEmptyNamesHaveNoKey() {
        XCTAssertNil(HeadsetIdentity.key(portName: "iPhone Microphone", portType: AVAudioSession.Port.builtInMic.rawValue))
        XCTAssertNil(HeadsetIdentity.key(portName: "Speaker", portType: AVAudioSession.Port.builtInSpeaker.rawValue))
        XCTAssertNil(HeadsetIdentity.key(portName: "  ", portType: hfp))
    }
    func testSaveLoadAndPersistAcrossInstances() {
        let p = HeadsetProfile(speakerGain: 3.5, gateThreshold: 0.02, voiceEnhancement: false, micGain: 4.0)
        HeadsetProfileStore(defaults: suite).save(p, for: "k")
        XCTAssertEqual(HeadsetProfileStore(defaults: suite).profile(for: "k"), p)
        XCTAssertNil(HeadsetProfileStore(defaults: suite).profile(for: "otro"))
    }
    func testProfilesAreIndependentAndRemoveOnlyAffectsOne() {
        let store = HeadsetProfileStore(defaults: suite)
        let a = HeadsetProfile(speakerGain: 1, gateThreshold: 0.006, voiceEnhancement: false, micGain: 3)
        let b = HeadsetProfile(speakerGain: 3, gateThreshold: 0.018, voiceEnhancement: true, micGain: 5)
        store.save(a, for: "a"); store.save(b, for: "b")
        store.remove("a")
        XCTAssertNil(store.profile(for: "a"))
        XCTAssertEqual(store.profile(for: "b"), b)
    }
    func testCorruptDataYieldsNoProfile() {
        suite.set(Data([0x00, 0x01]), forKey: HeadsetProfileStore.defaultsKey)
        XCTAssertNil(HeadsetProfileStore(defaults: suite).profile(for: "k"))
    }
}
