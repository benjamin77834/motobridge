import XCTest
@testable import MotoBridge

final class RiderNameTests: XCTestCase {
    private var suite: UserDefaults!
    private let suiteName = "RiderNameTests"
    private let uidA = "3F9A1C22-0000-4000-8000-000000000001"
    private let uidB = "7B01D5E9-0000-4000-8000-000000000002"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        suite = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: generación
    func testSuffixIsFourUppercaseAlphanumericsFromUID() {
        XCTAssertEqual(RiderName.suffix(uid: uidA), "3F9A")
        XCTAssertEqual(RiderName.suffix(uid: "abcd-ef"), "ABCD")
    }
    func testSuffixPadsShortUID() {
        XCTAssertEqual(RiderName.suffix(uid: "a"), "A000")
    }
    func testAutomaticNameUsesPrefixAndSuffix() {
        XCTAssertEqual(RiderName.automatic(prefix: "iPhone", uid: uidA), "iPhone-3F9A")
        XCTAssertEqual(RiderName.automatic(prefix: "Mac", uid: uidB), "Mac-7B01")
    }
    func testTwoDevicesWithDifferentUIDGetDifferentDefaults() {
        XCTAssertNotEqual(RiderName.effective(saved: nil, prefix: "iPhone", uid: uidA, collision: false),
                          RiderName.effective(saved: "", prefix: "iPhone", uid: uidB, collision: false))
    }
    func testSavedNameWinsOverAutomatic() {
        XCTAssertEqual(RiderName.effective(saved: "  Ben ", prefix: "iPhone", uid: uidA, collision: false), "Ben")
    }
    func testCustomNameIsTruncated() {
        let long = String(repeating: "x", count: 80)
        XCTAssertEqual(RiderName.effective(saved: long, prefix: "iPhone", uid: uidA, collision: false).count, 30)
    }

    // MARK: colisiones
    func testCollisionDetection() {
        XCTAssertTrue(RiderName.collides(local: "Ben", peers: ["Ana", "Ben"]))
        XCTAssertFalse(RiderName.collides(local: "Ben", peers: ["Ana"]))
    }
    func testCollisionAddsUIDSuffixToCustomName() {
        XCTAssertEqual(RiderName.effective(saved: "Ben", prefix: "iPhone", uid: uidA, collision: true), "Ben-3F9A")
    }
    func testCollisionSuffixIsNotAppliedTwice() {
        XCTAssertEqual(RiderName.effective(saved: "Ben-3F9A", prefix: "iPhone", uid: uidA, collision: true), "Ben-3F9A")
    }
    func testCollisionOnAutomaticNameLengthensSuffix() {
        XCTAssertEqual(RiderName.effective(saved: nil, prefix: "iPhone", uid: uidA, collision: true), "iPhone-3F9A1C22")
    }
    func testCurrentReadsSavedNameAndCollisionFlag() {
        suite.set("Ben", forKey: "riderName")
        XCTAssertEqual(RiderName.current(defaults: suite, prefix: "iPhone", uid: uidA), "Ben")
        suite.set(true, forKey: RiderName.collisionKey)
        XCTAssertEqual(RiderName.current(defaults: suite, prefix: "iPhone", uid: uidA), "Ben-3F9A")
    }
    func testUniqueNamesGiveDifferentPrivateIds() {
        let a = NetworkBridgeController.idFor(name: RiderName.automatic(prefix: "iPhone", uid: uidA))
        let b = NetworkBridgeController.idFor(name: RiderName.automatic(prefix: "iPhone", uid: uidB))
        XCTAssertNotEqual(a, b)
    }

    // MARK: pregunta de primer arranque
    private var policy: RiderNamePromptPolicy { RiderNamePromptPolicy(defaults: suite) }

    func testPromptsAtFirstLaunchWithoutOwnName() {
        XCTAssertTrue(policy.shouldPrompt(.appOpen))
        XCTAssertTrue(policy.shouldPrompt(.bridgeStart))
    }
    func testNeverPromptsWithSavedName() {
        XCTAssertTrue(policy.save("Ben"))
        XCTAssertFalse(policy.shouldPrompt(.appOpen))
        XCTAssertFalse(policy.shouldPrompt(.bridgeStart))
    }
    func testExistingSavedNameFromOlderVersionIsNotAsked() {
        suite.set("Piloto 1", forKey: "riderName")
        XCTAssertFalse(policy.shouldPrompt(.appOpen))
    }
    func testBlankNameCountsAsSkippedAndIsNotSaved() {
        XCTAssertFalse(policy.save("   "))
        XCTAssertFalse(policy.hasOwnName)
    }
    func testSkippedOnceRemindsAtBridgeStartButNotAtAppOpen() {
        policy.markShown()   // omitido al abrir
        XCTAssertFalse(policy.shouldPrompt(.appOpen))
        XCTAssertTrue(policy.shouldPrompt(.bridgeStart))
    }
    func testMaximumTwoPromptsInTotal() {
        policy.markShown()
        policy.markShown()
        XCTAssertEqual(policy.promptCount, RiderNamePromptPolicy.maxPrompts)
        XCTAssertFalse(policy.shouldPrompt(.appOpen))
        XCTAssertFalse(policy.shouldPrompt(.bridgeStart))
    }
    func testSavingAfterFirstPromptStopsReminders() {
        policy.markShown()
        policy.save("Ana")
        XCTAssertFalse(policy.shouldPrompt(.bridgeStart))
    }
}
