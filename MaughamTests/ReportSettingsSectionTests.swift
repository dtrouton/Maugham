import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

/// Report plan 4, Task 8 (R-4-7, review focus 3): Project Settings with its
/// Report section, mounted — read off the AX tree only, never pressed
/// (tripwire 33) — and the schema floor it keeps: opening Settings on a
/// schema-9 Novel and closing it writes nothing.
@MainActor
final class ReportSettingsSectionTests: XCTestCase {
    var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func open(_ url: URL) async throws -> (ProjectStore, DocumentStore) {
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (store, ds)
    }

    /// The whole sheet, as `ProjectWindow` presents it.
    private func mountSettings(_ store: ProjectStore) -> NSWindow {
        let view = ProjectSettingsSheet(store: store)
            .environment(UserPreferences(
                defaults: UserDefaults(suiteName: "ReportSettingsSection-\(UUID())")!))
        let window = TestWindow.mount(AnyView(view), size: CGSize(width: 600, height: 1400))
        windows.append(window)
        return window
    }

    /// Let the sheet appear and run its `.task`s, then tear it down.
    private func openAndClose(_ store: ProjectStore) async throws {
        let window = mountSettings(store)
        try await Task.sleep(for: .milliseconds(600))
        window.contentView = nil
        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(300))
    }

    private func modificationDate(_ url: URL) throws -> Date? {
        try ProjectStoreProfileTests.modificationDate(url)
    }

    private func schema(_ url: URL) -> Int? {
        ProjectManifest.schemaVersion(ofFileAt: url.appendingPathComponent(ProjectManifest.fileName))
    }

    // MARK: - The schema floor (review focus 3)

    func test_openingAndClosingSettingsOnASchema9NovelWritesNothing() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "Floor", in: temp.url)
        try ProjectStoreProfileTests.lowerToSchema9(url)
        let (store, ds) = try await open(url)
        try ProjectStoreProfileTests.backdate(url)

        try await openAndClose(store)
        await ds.close()

        XCTAssertEqual(try modificationDate(url), ProjectStoreProfileTests.past,
                       "opening and closing Settings wrote the manifest")
        XCTAssertEqual(schema(url), 9)
    }

    func test_openingAndClosingSettingsOnAReportWithOverridesWritesNothing() async throws {
        let url = try await ProjectFactory.createReportProject(
            named: "Quarterly", in: temp.url, shape: .sections)
        let (store, ds) = try await open(url)
        try await store.setSwitch(.listOfFigures, false)
        try ProjectStoreProfileTests.backdate(url)

        try await openAndClose(store)
        await ds.close()

        XCTAssertEqual(try modificationDate(url), ProjectStoreProfileTests.past)
    }

    /// A book with its own typography: the sheet's Typography picker is
    /// seeded from the manifest as it appears, and that seeding must not read
    /// as the writer choosing it (an `onChange` firing on the initial value
    /// would re-save the override over itself).
    func test_openingAndClosingSettingsOnABookWithItsOwnTypographyWritesNothing() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "Typed", in: temp.url)
        let (store, ds) = try await open(url)
        var typography = TypographySettings.defaults
        typography.fontSize = 21
        try await store.setProjectTypography(typography)
        try ProjectStoreProfileTests.backdate(url)

        try await openAndClose(store)
        await ds.close()

        XCTAssertEqual(try modificationDate(url), ProjectStoreProfileTests.past)
        XCTAssertEqual(store.manifest.typography, typography, "the override is untouched")
    }

    /// The whole section's file carries no lifecycle hook that could write on
    /// appear: every write is a control's setter. The control is the sheet
    /// file itself, which has an `onChange` and a `task`.
    func test_theSectionHasNoAppearHookThatCouldWrite() throws {
        let hooks = [".onChange(", ".onAppear", ".task", ".onDisappear"]
        let section = try Self.source(of: "Views/ReportSettingsSection.swift")
        XCTAssertEqual(hooks.filter { section.contains($0) }, [])
        let sheet = try Self.source(of: "Views/ProjectSettingsSheet.swift")
        XCTAssertEqual(hooks.filter { sheet.contains($0) }, [".onChange(", ".task", ".onDisappear"],
                       "control: the scan sees the sheet's hooks")
    }

    static func source(of path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Maugham/\(path)"), encoding: .utf8)
    }

    // MARK: - What the section shows (AX tree only)

    func test_aNovelShowsItsKindTheReportToggleAndTheSwitches() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "Plain", in: temp.url)
        let (store, _) = try await open(url)
        let window = mountSettings(store)
        let tree = try await axTree(in: window, containing: "Number sections")

        XCTAssertTrue(texts(in: tree).contains("Novel"), "the Kind row")
        let boxes = checkboxes(in: tree)
        for title in ["Report", "Number sections", "List of figures", "List of tables", "Web access"] {
            XCTAssertNotNil(boxes[title], "\(title) is a toggle")
        }
        XCTAssertEqual(boxes["Report"]?.enabled, true)
        XCTAssertEqual(boxes["Web access"]?.enabled, false, "shown, never pressable")
        XCTAssertTrue(texts(in: tree).contains(ReportSettingsModel.webAccessNote))
        XCTAssertEqual(buttons(labelled: "Default", in: tree), 0, "nothing overridden")
    }

    func test_aReportShowsItsKindAndOneDefaultPerOverride() async throws {
        let url = try await ProjectFactory.createReportProject(
            named: "Quarterly", in: temp.url, shape: .singleDocument)
        let (store, _) = try await open(url)
        try await store.setSwitch(.listOfTables, false)
        let window = mountSettings(store)
        let tree = try await axTree(in: window, containing: "Number sections")

        XCTAssertTrue(texts(in: tree).contains("Report"), "the Kind row")
        let boxes = checkboxes(in: tree)
        XCTAssertEqual(boxes["Report"]?.on, true)
        XCTAssertEqual(boxes["Number sections"]?.on, true)
        XCTAssertEqual(boxes["List of tables"]?.on, false)
        XCTAssertEqual(buttons(labelled: "Default", in: tree), 1)
    }

    func test_aScreenplayHasNoReportSection() async throws {
        let url = try await ProjectFactory.createScreenplayProject(named: "Script", in: temp.url)
        let (store, _) = try await open(url)
        let window = mountSettings(store)
        let tree = try await axTree(in: window, containing: "Show element gutter")
        XCTAssertNil(checkboxes(in: tree)["Number sections"])
        XCTAssertNil(checkboxes(in: tree)["Report"])
    }

    // MARK: - Accessibility readers (`AXReading`)

    private func label(_ element: AnyObject) -> String? {
        axAttribute(element, "accessibilityLabel") as? String
    }

    private func title(_ element: AnyObject) -> String? {
        let raw = axAttribute(element, "accessibilityTitle")
        return (raw as? String) ?? (raw as? NSAttributedString)?.string
    }

    private func role(_ element: AnyObject) -> String? {
        axAttribute(element, "accessibilityRole") as? String
    }

    private func name(_ element: AnyObject) -> String? {
        [label(element), title(element), axReading(element)].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// The tree, once an element named `marker` is in it.
    private func axTree(in window: NSWindow, containing marker: String) async throws -> [AnyObject] {
        let deadline = Date().addingTimeInterval(3)
        var tree: [AnyObject] = []
        while Date() < deadline {
            tree = try axElements(in: window)
            if tree.contains(where: { name($0) == marker }) { return tree }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("no \(marker) in the tree: "
                + tree.map { "\(role($0) ?? "?"):\(name($0) ?? ""):\(axReading($0) ?? "")" }.joined(separator: ", "))
        return tree
    }

    /// Each checkbox by its title. In a grouped `Form` a toggle publishes an
    /// unlabelled `AXCheckBox` after its title's `AXStaticText`, so an
    /// unnamed box takes the text just before it.
    private func checkboxes(in tree: [AnyObject]) -> [String: (on: Bool, enabled: Bool)] {
        var found: [String: (on: Bool, enabled: Bool)] = [:]
        for (index, element) in tree.enumerated() where role(element) == "AXCheckBox" {
            let own = [label(element), title(element)].compactMap { $0 }.first { !$0.isEmpty }
            let preceding = tree[..<index].last { role($0) == "AXStaticText" }.flatMap(axReading)
            guard let title = own ?? preceding else { continue }
            let value = axAttribute(element, "accessibilityValue")
            let on = (value as? NSNumber)?.boolValue ?? ((value as? String) == "1")
            found[title] = (on, axEnabled(element) ?? true)
        }
        return found
    }

    private func texts(in tree: [AnyObject]) -> Set<String> {
        Set(tree.flatMap { element -> [String] in
            [label(element), title(element), axReading(element)].compactMap { $0 }
        })
    }

    private func buttons(labelled title: String, in tree: [AnyObject]) -> Int {
        tree.filter { role($0) == "AXButton" && name($0) == title }.count
    }
}
