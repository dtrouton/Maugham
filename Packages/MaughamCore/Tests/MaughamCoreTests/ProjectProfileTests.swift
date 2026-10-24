import XCTest
@testable import MaughamCore

/// The Report profile, its four switches, and schema 10 (report foundations
/// plan 1, Task 5). The schema half is the data-safety half: an older build
/// that opened a project carrying a profile, switches or citation details
/// would re-save the manifest without them, so such a project must reach disk
/// at 10 — and a project with none of them must NOT.
final class ProjectProfileTests: XCTestCase {

    private func manifest(_ version: Int, research: [ResearchItem] = []) -> ProjectManifest {
        ProjectManifest(
            schemaVersion: version, type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0),
            structure: [], research: research)
    }

    // MARK: - The profile's raw string

    func test_reportDecodesAsReport() throws {
        let decoded = try JSONDecoder().decode([ProjectProfile].self, from: Data(#"["report"]"#.utf8))
        XCTAssertEqual(decoded, [.report])
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([ProjectProfile.report]), as: UTF8.self),
                       #"["report"]"#)
    }

    /// An unknown profile keeps its raw string and re-encodes it VERBATIM, so
    /// a profile a later build added survives this build's save.
    func test_anUnknownProfileReEncodesItsRawStringVerbatim() throws {
        let decoded = try JSONDecoder().decode([ProjectProfile].self, from: Data(#"["essay"]"#.utf8))
        XCTAssertEqual(decoded, [.unknown("essay")])
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self),
                       #"["essay"]"#)
    }

    // MARK: - Effective switches

    func test_noProfileMeansEverySwitchIsOff() {
        let s = manifest(10).effectiveSwitches
        XCTAssertFalse(s.numberSections); XCTAssertFalse(s.listOfFigures)
        XCTAssertFalse(s.listOfTables); XCTAssertFalse(s.webAccess)
    }

    func test_theReportProfileTurnsEverySwitchOn() {
        var m = manifest(10)
        m.profile = .report
        let s = m.effectiveSwitches
        XCTAssertTrue(s.numberSections); XCTAssertTrue(s.listOfFigures)
        XCTAssertTrue(s.listOfTables); XCTAssertTrue(s.webAccess)
    }

    func test_aStoredFalseBeatsTheProfile() {
        var m = manifest(10)
        m.profile = .report
        m.switches = ProjectSwitches(listOfTables: false)
        let s = m.effectiveSwitches
        XCTAssertFalse(s.listOfTables)
        XCTAssertTrue(s.numberSections); XCTAssertTrue(s.listOfFigures); XCTAssertTrue(s.webAccess)
        XCTAssertEqual(m.switches, ProjectSwitches(listOfTables: false),
                       "reading the effective switches writes no defaults back (tripwire 11)")
    }

    func test_anUnknownProfileDefaultsEverySwitchOff() {
        var m = manifest(10)
        m.profile = .unknown("essay")
        m.switches = ProjectSwitches(webAccess: true)
        let s = m.effectiveSwitches
        XCTAssertFalse(s.numberSections); XCTAssertTrue(s.webAccess)
    }

    // MARK: - Review focus 2: an existing book keeps its number

    func test_aSchemaNineManifestWithNoV10ContentStaysAtNine() throws {
        let m = manifest(9, research: [
            ResearchItem(id: "r1", title: "Notes", type: .group, children: [
                ResearchItem(id: "r2", title: "Leaf", type: .asset, kind: .link, url: "https://x")
            ])
        ])
        XCTAssertEqual(m.contentSchemaFloor, 0)
        let bytes = try ProjectManifest.encodeForDisk(m)
        XCTAssertEqual(ProjectManifest.schemaVersion(of: bytes), 9)
        XCTAssertEqual(bytes, try ProjectManifest.makeEncoder().encode(m),
                       "a book with no v10 content is written byte-for-byte as before")
    }

    // MARK: - Review focus 3: v10 content raises the number

    func test_aProfileEncodesAtTen() throws {
        var m = manifest(9)
        m.profile = .report
        XCTAssertEqual(m.contentSchemaFloor, 10)
        XCTAssertEqual(ProjectManifest.schemaVersion(of: try ProjectManifest.encodeForDisk(m)), 10)
    }

    func test_switchesAloneEncodeAtTen() throws {
        var m = manifest(9)
        m.switches = ProjectSwitches(webAccess: false)
        XCTAssertEqual(ProjectManifest.schemaVersion(of: try ProjectManifest.encodeForDisk(m)), 10)
    }

    func test_aCitationOnANestedResearchItemEncodesAtTen() throws {
        let m = manifest(9, research: [
            ResearchItem(id: "g1", title: "Sources", type: .group, children: [
                ResearchItem(id: "g2", title: "Deeper", type: .group, children: [
                    ResearchItem(id: "r1", title: "Paper", type: .asset, kind: .pdf,
                                 citation: CitationInfo(key: "smith2020", authors: ["Jo Smith"], year: 2020))
                ])
            ])
        ])
        XCTAssertEqual(m.contentSchemaFloor, 10)
        let bytes = try ProjectManifest.encodeForDisk(m)
        XCTAssertEqual(ProjectManifest.schemaVersion(of: bytes), 10)
        // And the result is still one this build opens.
        XCTAssertEqual(try ProjectManifest.decodeGuardingSchema(bytes).schemaVersion, 10)
    }

    // MARK: - Report plan 6a Task 5: a book with figures needs schema 10

    private let aFigure = FigureRecord(
        id: "fig-0a1b2c3d", name: "cashflow", kind: .table, piece: nil,
        path: "figures/cashflow.csv")

    func test_aFigureRecordRaisesTheFloorToTen() {
        var m = manifest(9)
        XCTAssertEqual(m.contentSchemaFloor, 0)
        m.figures = [aFigure]
        XCTAssertEqual(m.contentSchemaFloor, 10)
        m.figures = []
        XCTAssertEqual(m.contentSchemaFloor, 0, "an empty registry is no figures")
    }

    func test_aSchemaNineBookThatGainsAFigureEncodesAtTen() throws {
        var m = manifest(9)
        m.figures = [aFigure]
        let bytes = try ProjectManifest.encodeForDisk(m)
        XCTAssertEqual(ProjectManifest.schemaVersion(of: bytes), 10)
        XCTAssertEqual(try ProjectManifest.decodeGuardingSchema(bytes).figures, [aFigure])
    }

    /// There is no seam to lower `currentSchemaVersion`, so this reproduces the
    /// schema-9 build's gate (`decodeGuardingSchema`'s one comparison, against
    /// `narrowingSchemaVersion`, the number a 9 build supports) over the bytes
    /// this build writes for a book with figures.
    func test_aSchemaNineBuildRefusesABookWithFigures() throws {
        var m = manifest(9)
        m.figures = [aFigure]
        let bytes = try ProjectManifest.encodeForDisk(m)
        let found = try XCTUnwrap(ProjectManifest.schemaVersion(of: bytes))
        let nineBuildSupports = ProjectManifest.narrowingSchemaVersion
        XCTAssertEqual(nineBuildSupports, 9)
        XCTAssertGreaterThan(found, nineBuildSupports,
                             "a v9 decoder throws SchemaTooNewError(found: 10, supported: 9)")
        XCTAssertEqual(ProjectManifest.SchemaTooNewError(found: found, supported: nineBuildSupports),
                       ProjectManifest.SchemaTooNewError(found: 10, supported: 9))
    }

    /// The floor raises; it never lowers. A number above the floor is kept.
    func test_encodeForDiskNeverLowersTheNumber() throws {
        let m = manifest(ProjectManifest.currentSchemaVersion)
        XCTAssertEqual(ProjectManifest.schemaVersion(of: try ProjectManifest.encodeForDisk(m)),
                       ProjectManifest.currentSchemaVersion)
    }

    /// A manifest raised by the write door's floor is re-encoded through the
    /// same door, so v10 content can never be written below 10 that way either.
    func test_raisingKeepsTheContentFloor() throws {
        var m = manifest(8)
        m.profile = .report
        let outgoing = try ProjectManifest.makeEncoder().encode(m)  // a pre-door copy at 8
        let raised = ProjectManifest.raising(outgoing, toAtLeast: 9)
        XCTAssertEqual(ProjectManifest.schemaVersion(of: raised), 10)
    }

    // MARK: - The gate and the old files

    func test_currentSchemaIsTen() {
        XCTAssertEqual(ProjectManifest.currentSchemaVersion, 10)
    }

    func test_aSchemaElevenManifestIsRefused() throws {
        let bytes = try ProjectManifest.makeEncoder().encode(manifest(11))
        XCTAssertThrowsError(try ProjectManifest.decodeGuardingSchema(bytes)) { error in
            XCTAssertEqual(error as? ProjectManifest.SchemaTooNewError,
                           .init(found: 11, supported: 10))
        }
    }

    func test_aSchemaNineFixtureDecodesWithNoProfileAndNoSwitches() throws {
        let json = Data("""
        {
          "schemaVersion": 9,
          "type": "novel",
          "title": "Old Book",
          "author": "A",
          "created": "2026-05-07T14:22:00Z",
          "modified": "2026-05-07T14:22:00Z",
          "structure": [],
          "research": []
        }
        """.utf8)
        let m = try ProjectManifest.decodeGuardingSchema(json)
        XCTAssertNil(m.profile)
        XCTAssertNil(m.switches)
        XCTAssertEqual(m.schemaVersion, 9)
    }

    /// The new keys reach disk and come back.
    func test_profileAndSwitchesRoundTripThroughTheManifest() throws {
        var m = manifest(10)
        m.profile = .unknown("essay")
        m.switches = ProjectSwitches(numberSections: true, listOfFigures: false)
        let back = try ProjectManifest.decodeGuardingSchema(try ProjectManifest.encodeForDisk(m))
        XCTAssertEqual(back.profile, .unknown("essay"))
        XCTAssertEqual(back.switches, ProjectSwitches(numberSections: true, listOfFigures: false))
        XCTAssertEqual(back, m)
    }
}
