import Foundation
import XCTest
@testable import MaughamCore

/// **The label the writer chose, kept on this Mac.**
///
/// Decision B2's memory: a fingerprint this writer has already named once is
/// never asked about again, in this book or any other. Two things are pinned
/// here and neither is obvious.
///
/// The first is the SCOPE. This memory is keyed by device fingerprint and by
/// nothing else — no project, no root — because it records the writer's own
/// decision rather than a fact about a folder. A project that goes away takes
/// its registry cache with it (`RegistryCache` prunes); it must not take the
/// writer's answer to *who is this phone*, or the next book asks again.
///
/// The second is the DATE. `labelledAt` is when the writer decided, not when
/// the label was last used. Silent admission at open writes a person record
/// with the remembered label on every project it can — restamping the date each
/// time would turn a decision made in September into one made this morning, and
/// the surface that says *remembered from Playlist* would be lying about when.
final class AdmissionMemoryTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-memory-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func makeMemory(identity: String = "this-mac") -> AdmissionMemory {
        AdmissionMemory(fileURL: fileURL, identity: identity)
    }

    // MARK: - Knowing nothing

    func test_anEmptyMemoryKnowsNobody() {
        XCTAssertNil(makeMemory().label(for: "phone-fingerprint"))
        XCTAssertTrue(makeMemory().remembered.isEmpty)
    }

    func test_anUndecodableFileStartsEmptyRatherThanThrowing() throws {
        try Data("not json".utf8).write(to: fileURL)

        let memory = makeMemory()

        XCTAssertNil(memory.label(for: "phone-fingerprint"),
                     "this is a memory, not a source of truth — an unreadable one remembers nothing")
    }

    // MARK: - Remembering

    func test_aRememberedLabelSurvivesAReopen() {
        makeMemory().remember(
            "phone-fingerprint", label: "Denver", ownName: "Denver's iPhone",
            at: Date(timeIntervalSince1970: 100))

        let reopened = makeMemory()

        let remembered = reopened.label(for: "phone-fingerprint")
        XCTAssertEqual(remembered?.label, "Denver")
        XCTAssertEqual(remembered?.ownName, "Denver's iPhone")
        XCTAssertEqual(remembered?.labelledAt, Date(timeIntervalSince1970: 100))
    }

    func test_theSameLabelAgainKeepsTheDayTheWriterDecidedIt() {
        let memory = makeMemory()
        memory.remember("phone", label: "Denver", ownName: "Denver's iPhone",
                        at: Date(timeIntervalSince1970: 100))

        memory.remember("phone", label: "Denver", ownName: "Denver's iPhone 17",
                        at: Date(timeIntervalSince1970: 900))

        let remembered = memory.label(for: "phone")
        XCTAssertEqual(
            remembered?.labelledAt, Date(timeIntervalSince1970: 100),
            "silent admission uses the label; it does not re-decide it")
        XCTAssertEqual(
            remembered?.ownName, "Denver's iPhone 17",
            "but the device's own name is a fact about the device, and it is current")
    }

    func test_aDifferentLabelIsANewDecisionAndIsStampedNow() {
        let memory = makeMemory()
        memory.remember("phone", label: "Denver", ownName: "Denver's iPhone",
                        at: Date(timeIntervalSince1970: 100))

        memory.remember("phone", label: "The editor", ownName: "Denver's iPhone",
                        at: Date(timeIntervalSince1970: 900))

        XCTAssertEqual(memory.label(for: "phone")?.label, "The editor")
        XCTAssertEqual(memory.label(for: "phone")?.labelledAt,
                       Date(timeIntervalSince1970: 900))
    }

    func test_forgettingADeviceRemovesItAndPersists() {
        makeMemory().remember("phone", label: "Denver", ownName: "Denver's iPhone")

        makeMemory().forget("phone")

        XCTAssertNil(makeMemory().label(for: "phone"))
    }

    func test_everyRememberedDeviceIsEnumerable() {
        let memory = makeMemory()
        memory.remember("phone", label: "Denver", ownName: "Denver's iPhone")
        memory.remember("tablet", label: "Denver", ownName: "Denver's iPad")

        XCTAssertEqual(Set(memory.remembered.keys), ["phone", "tablet"],
                       "People & Devices lists a remembered device whose record is absent")
    }

    // MARK: - Whose memory it is

    func test_aMemoryWrittenByAnotherIdentityIsNotThisDevicesAndStartsEmpty() {
        makeMemory(identity: "another-mac")
            .remember("phone", label: "Somebody else's word", ownName: "phone")

        let mine = makeMemory(identity: "this-mac")

        XCTAssertNil(
            mine.label(for: "phone"),
            "a label is one writer's decision on one machine — another identity's file is not it")
        XCTAssertEqual(mine.identity, "this-mac")
    }

    /// Reading it under the other identity is itself the takeover — the file is
    /// rewritten empty under whoever opened it — so this asserts the stamp on
    /// disk rather than reading back as the identity it displaced.
    func test_takingOverTheFileRewritesItUnderThisIdentity() throws {
        makeMemory(identity: "another-mac").remember("phone", label: "X", ownName: "phone")

        makeMemory(identity: "this-mac").remember("phone", label: "Denver",
                                                  ownName: "Denver's iPhone")

        XCTAssertEqual(makeMemory(identity: "this-mac").label(for: "phone")?.label, "Denver")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: fileURL))
                as? [String: Any])
        XCTAssertEqual(json["identity"] as? String, "this-mac",
                       "the file says whose memory it is, and it is not theirs any more")
    }

    // MARK: - The shape on disk

    func test_theFileIsKeyedByDeviceAndByNothingElse() throws {
        makeMemory().remember("phone", label: "Denver", ownName: "Denver's iPhone")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: fileURL))
                as? [String: Any])

        XCTAssertEqual(
            Set(json.keys), ["identity", "devices"],
            """
            There is no project key here and there must never be one: this \
            memory is a fact about the writer's decision, and pruning it with a \
            project would have the next book ask again.
            """)
        let devices = try XCTUnwrap(json["devices"] as? [String: Any])
        XCTAssertEqual(Set(devices.keys), ["phone"])
    }
}
