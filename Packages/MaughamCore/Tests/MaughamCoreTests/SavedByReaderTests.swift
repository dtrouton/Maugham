import Foundation
import XCTest
@testable import MaughamCore

/// The saved-by reader (your devices are you, plan 2 Task 3; Review Focus 3):
/// it passes iCloud's answer through and never makes one up.
final class SavedByReaderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = TestTemp.root.appendingPathComponent("savedby-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A reader that answers from a table and records every URL it is asked.
    private final class Fake: SavedByReading, @unchecked Sendable {
        var answers: [URL: String] = [:]
        var asked: [URL] = []
        func name(ofFileAt url: URL) -> String? {
            asked.append(url)
            return answers[url.standardizedFileURL]
        }
    }

    // MARK: - The real reader never invents a name

    /// A plain local file — not in iCloud, so nobody iCloud could name —
    /// reads nil. This is the owner's-own-save shape too: the OS answers nil
    /// and the reader adds nothing to it.
    func test_aLocalFileNobodyICloudKnowsReadsNil() throws {
        let url = root.appendingPathComponent("record.json")
        try Data("{}".utf8).write(to: url)
        XCTAssertNil(SavedByReader().name(ofFileAt: url))
    }

    /// A file that does not exist reads nil — it never throws.
    func test_aMissingFileReadsNilAndDoesNotThrow() {
        XCTAssertNil(SavedByReader().name(ofFileAt: root.appendingPathComponent("absent.json")))
    }

    // MARK: - Formatting, both directions

    func test_componentsFormatToTheName() {
        var components = PersonNameComponents()
        components.givenName = "Rebecca"
        components.familyName = "Burgess"
        let name = SavedByReader.formatted(components)
        XCTAssertNotNil(name)
        XCTAssertTrue(name?.contains("Rebecca") == true)
        XCTAssertTrue(name?.contains("Burgess") == true)
    }

    func test_noComponentsOrEmptyComponentsAreNoName() {
        XCTAssertNil(SavedByReader.formatted(nil))
        XCTAssertNil(SavedByReader.formatted(PersonNameComponents()))
        var blank = PersonNameComponents()
        blank.givenName = "   "
        XCTAssertNil(SavedByReader.formatted(blank))
    }

    // MARK: - The device record's own file

    /// It asks at each device record's path, and a device iCloud says nothing
    /// about is ABSENT from the map — never present with an empty name.
    func test_itAsksAtEachDeviceRecordAndOmitsTheUnanswered() {
        let fake = Fake()
        let named = RegistryWriter.url(.devices, fingerprint: "aaaa", in: root)
        let blank = RegistryWriter.url(.devices, fingerprint: "cccc", in: root)
        fake.answers[named.standardizedFileURL] = "Rebecca Burgess"
        fake.answers[blank.standardizedFileURL] = "  "

        let map = fake.savedBy(deviceRecordsOf: ["aaaa", "bbbb", "cccc"], in: root)

        XCTAssertEqual(map, ["aaaa": "Rebecca Burgess"])
        XCTAssertEqual(fake.asked.map(\.lastPathComponent),
                       ["aaaa.json", "bbbb.json", "cccc.json"])
        XCTAssertTrue(fake.asked.allSatisfy {
            $0.deletingLastPathComponent().lastPathComponent == "devices"
        })
    }

    func test_nothingAskedAboutIsAnEmptyMap() {
        let fake = Fake()
        XCTAssertEqual(fake.savedBy(deviceRecordsOf: [], in: root), [:])
        XCTAssertTrue(fake.asked.isEmpty)
    }
}
