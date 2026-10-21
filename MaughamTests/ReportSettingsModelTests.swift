import XCTest
import MaughamCore
@testable import Maugham

/// Report plan 4, Task 8 (R-4-7): what Project Settings' Report section shows,
/// as a value built from the manifest — the Kind row, the Report toggle, the
/// three switches with their effective values and Default resets, and Web
/// access disabled with its note. Screenplays have no section.
@MainActor
final class ReportSettingsModelTests: XCTestCase {

    private func manifest(
        _ type: ProjectType, profile: ProjectProfile? = nil, switches: ProjectSwitches? = nil
    ) -> ProjectManifest {
        var m = ProjectManifest(
            type: type, title: "Book", author: "", created: Date(), modified: Date(),
            structure: [], research: [])
        m.profile = profile
        m.switches = switches
        return m
    }

    private func model(
        _ type: ProjectType, profile: ProjectProfile? = nil, switches: ProjectSwitches? = nil
    ) throws -> ReportSettingsModel {
        try XCTUnwrap(ReportSettingsModel.make(manifest(type, profile: profile, switches: switches)))
    }

    // MARK: - Which projects have the section

    func test_aScreenplayHasNoSection() {
        XCTAssertNil(ReportSettingsModel.make(manifest(.screenplay)))
    }

    func test_everyOtherKindHasTheSection() {
        for type in [ProjectType.shortStory, .novel, .collection, .unknown] {
            XCTAssertNotNil(ReportSettingsModel.make(manifest(type)), "\(type)")
        }
    }

    // MARK: - The Kind row and the Report toggle

    func test_theKindRowAsksProjectKindName() throws {
        XCTAssertEqual(try model(.novel).kindName, "Novel")
        XCTAssertEqual(try model(.shortStory).kindName, "Short Story")
        XCTAssertEqual(try model(.novel, profile: .report).kindName, "Report")
        XCTAssertEqual(try model(.shortStory, profile: .report).kindName, "Report")
        XCTAssertEqual(try model(.collection).kindName, "Collection")
    }

    func test_theReportToggleIsTheProfile() throws {
        XCTAssertEqual(try model(.novel).reportTitle, "Report")
        XCTAssertFalse(try model(.novel).isReport)
        XCTAssertTrue(try model(.novel, profile: .report).isReport)
        XCTAssertTrue(try model(.novel).reportToggleEnabled)
        XCTAssertTrue(try model(.shortStory, profile: .report).reportToggleEnabled)
        XCTAssertNil(try model(.novel).reportToggleRefusal)
    }

    func test_aCollectionCannotTurnTheReportOn() throws {
        let m = try model(.collection)
        XCTAssertFalse(m.reportToggleEnabled)
        XCTAssertEqual(m.reportToggleRefusal, "A Collection can\u{2019}t carry the Report profile.")
    }

    func test_aNewerBuildsProfileIsNotOverwrittenByTheToggle() throws {
        let m = try model(.novel, profile: .unknown("essay"))
        XCTAssertFalse(m.isReport)
        XCTAssertFalse(m.reportToggleEnabled, "turning it on would replace a profile this build can't read")
        XCTAssertNotNil(m.reportToggleRefusal)
        XCTAssertEqual(m.kindName, "Novel")
    }

    // MARK: - The switches

    func test_theThreeSwitchesInOrderAndWebAccessApart() throws {
        let m = try model(.novel)
        XCTAssertEqual(m.switches.map(\.key), [.numberSections, .listOfFigures, .listOfTables])
        XCTAssertEqual(m.switches.map(\.title), ["Number sections", "List of figures", "List of tables"])
        XCTAssertEqual(m.webAccess.key, .webAccess)
        XCTAssertEqual(m.webAccess.title, "Web access")
        XCTAssertEqual(ReportSettingsModel.webAccessNote, "Used by the fact-checker (coming)")
    }

    func test_aReportShowsItsDefaultsOnAndNothingOverridden() throws {
        let m = try model(.novel, profile: .report)
        XCTAssertEqual(m.switches.map(\.isOn), [true, true, true])
        XCTAssertEqual(m.switches.map(\.isOverridden), [false, false, false])
        XCTAssertEqual(m.switches.map(\.defaultValue), [true, true, true])
        XCTAssertTrue(m.webAccess.isOn)
    }

    func test_aPlainNovelShowsEverythingOff() throws {
        let m = try model(.novel)
        XCTAssertEqual(m.switches.map(\.isOn), [false, false, false])
        XCTAssertEqual(m.switches.map(\.defaultValue), [false, false, false])
        XCTAssertEqual(m.switches.map(\.isOverridden), [false, false, false])
    }

    func test_anOverrideShowsItsEffectiveValueAndItsDefault() throws {
        let m = try model(.novel, profile: .report,
                          switches: ProjectSwitches(listOfFigures: false))
        XCTAssertEqual(m.switches.map(\.isOn), [true, false, true])
        XCTAssertEqual(m.switches.map(\.isOverridden), [false, true, false])
        XCTAssertEqual(m.switches[1].defaultValue, true, "Default would put the Report's value back")
    }

    func test_switchesKeptAfterTheProfileIsOffStillShow() throws {
        let m = try model(.novel, switches: ProjectSwitches(numberSections: true))
        XCTAssertFalse(m.isReport)
        XCTAssertEqual(m.switches.map(\.isOn), [true, false, false])
        XCTAssertEqual(m.switches[0].isOverridden, true)
        XCTAssertEqual(m.switches[0].defaultValue, false, "with no profile, the default is off")
    }

    // MARK: - The refusal in words

    func test_aRefusalIsSaidInTheKindsName() {
        XCTAssertEqual(
            ReportSettingsSection.sentence(ProjectFactoryError.profileNotOffered(.report, on: .screenplay)),
            "A Screenplay can\u{2019}t carry the Report profile.")
    }
}
