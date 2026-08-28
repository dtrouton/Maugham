import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The Exports footer names a book the same way the rest of Publish does**
/// (Task 6 of the imprints-p3 plan, "the naming surfaces"): each row's bare
/// filename gets a secondary line — `PublishPreviewCentre.parts(for:)`,
/// version/imprint/language/compiled-at — whenever the file's path matches a
/// row in the project's own publications catalog.
///
/// **The join is by `outputPath`, never by parsing the filename.** A writer
/// can rename a compiled PDF on disk without touching what the catalog says
/// it is, so `ExportsListView.Model.scan()` must read the record's own field
/// rather than guess an identity from characters that happen to look like one.
///
/// **An unreadable catalog costs entries their secondary line and nothing
/// else.** `PublicationStore.load()` throws `ReadError.unreadableFile`
/// (RULING-54) for a squatted or corrupt device file; this footer is
/// read-only chrome, not one of the write-adjacent consumers RULING-54 was
/// written for, so it tolerates the failure the way the existing scan already
/// tolerates a missing `Exports/` directory — `try?`, never a crash.
///
/// `scan()` became `async` in the same task (it now also awaits the catalog
/// load), which is why every case below is `async throws` where it once was
/// synchronous.
@MainActor
final class ExportsListViewTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func setUp() async throws {
        PublishingStores._resetForTesting()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        PublishingStores._resetForTesting()
    }

    // MARK: - Pre-existing scan() coverage (async since Task 6)

    func testModel_listsExportsContents() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let exports = tmp.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exports, withIntermediateDirectories: true)
        try Data().write(to: exports.appendingPathComponent("Title-v0.1.pdf"))
        try Data().write(to: exports.appendingPathComponent("Title-v0.2.pdf"))

        let model = ExportsListView.Model(projectURL: tmp)
        let entries = await model.scan()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.name).sorted(),
                       ["Title-v0.1.pdf", "Title-v0.2.pdf"])
    }

    func testModel_emptyDirectory_returnsEmpty() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyExports-\(UUID().uuidString)")
        let model = ExportsListView.Model(projectURL: tmp)
        let entries = await model.scan()
        XCTAssertTrue(entries.isEmpty)
    }

    func testModel_missingExportsDir_returnsEmpty() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoExports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Project folder exists but Exports/ does not.
        let model = ExportsListView.Model(projectURL: tmp)
        let entries = await model.scan()
        XCTAssertTrue(entries.isEmpty)
    }

    func testModel_filtersToPDFAndEPUBOnly() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixedExports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let exports = tmp.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exports, withIntermediateDirectories: true)
        try Data().write(to: exports.appendingPathComponent("Title.pdf"))
        try Data().write(to: exports.appendingPathComponent("Title.epub"))
        try Data().write(to: exports.appendingPathComponent("notes.txt"))
        try Data().write(to: exports.appendingPathComponent("README.md"))

        let entries = await ExportsListView.Model(projectURL: tmp).scan()
        XCTAssertEqual(Set(entries.map(\.name)), ["Title.pdf", "Title.epub"])
    }

    func testModel_sortsByModificationDateDescending() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SortExports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let exports = tmp.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exports, withIntermediateDirectories: true)

        // Write three files and stamp explicit modification dates so the
        // expected order is by recency, NOT by filename. Note the newest file
        // (v0.2) sorts lexically BELOW v0.3 — proving we sort by mtime, not name.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func write(_ name: String, ageSeconds: TimeInterval) throws {
            let url = exports.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(ageSeconds)],
                ofItemAtPath: url.path)
        }
        try write("Book-v0.1.pdf", ageSeconds: 0)      // oldest
        try write("Book-v0.3.pdf", ageSeconds: 100)    // middle
        try write("Book-v0.2.pdf", ageSeconds: 200)    // newest

        let entries = await ExportsListView.Model(projectURL: tmp).scan()
        XCTAssertEqual(entries.map(\.name),
                       ["Book-v0.2.pdf", "Book-v0.3.pdf", "Book-v0.1.pdf"],
                       "most recently modified file should be first, regardless of filename")
    }

    // MARK: - Task 6: the catalog join

    /// A file whose path the catalog names carries that row as `entry.record`.
    func test_aFileWithAMatchingRecordCarriesTheRecord() async throws {
        let project = try makeProject()
        try Data().write(to: project.appendingPathComponent("Exports/book.pdf"))
        let pub = publication(version: "1.0", outputPath: "Exports/book.pdf",
                              imprint: "special", language: "en+sr")
        try await PublicationStore(projectURL: project).append(pub)

        let entries = await ExportsListView.Model(projectURL: project).scan()

        let entry = try XCTUnwrap(entries.first { $0.name == "book.pdf" })
        XCTAssertEqual(entry.record?.publicationID, pub.publicationID,
                       "the file's path matches the record's outputPath, so "
                       + "the entry should carry it")
    }

    /// A file the catalog says nothing about carries no record — an unrelated
    /// row in the same catalog must not leak onto it.
    ///
    /// **Disable experiment** (see task report): with the join loosened to
    /// attach the catalog's first row to every entry regardless of path, this
    /// test goes red — `entry.record` becomes non-nil for a file no row
    /// names — which is what proves the assertion below is not vacuously true.
    func test_aFileWithNoRecordCarriesNoRecord() async throws {
        let project = try makeProject()
        try Data().write(to: project.appendingPathComponent("Exports/orphan.pdf"))
        let unrelated = publication(version: "9.0", outputPath: "Exports/elsewhere.pdf",
                                    imprint: "special")
        try await PublicationStore(projectURL: project).append(unrelated)

        let entries = await ExportsListView.Model(projectURL: project).scan()

        let entry = try XCTUnwrap(entries.first { $0.name == "orphan.pdf" })
        XCTAssertNil(entry.record,
                     "no row in the catalog names this file's path, so it "
                     + "must carry no record")
    }

    /// **The filename lies; the catalog tells the truth.** A file named as
    /// though it were v9.9 with a record that actually says v0.1 carries the
    /// v0.1 record — proving the join reads `outputPath`, never the
    /// characters in the name.
    ///
    /// **Disable experiment** (see task report): with the join weakened to
    /// match by file extension alone (any `.pdf` matches any `.pdf` record)
    /// this test goes red, resolving the decoy's v9.9 record instead — the
    /// exact failure mode the second, decoy file in this fixture exists to
    /// catch.
    func test_theJoinIsByOutputPathNotByParsingTheFilename() async throws {
        let project = try makeProject()
        let lyingName = "Title-v9.9-nope.pdf"
        try Data().write(to: project.appendingPathComponent("Exports/\(lyingName)"))
        // A decoy at a DIFFERENT path, so a join that matches "any .pdf" or
        // "the last-written record" rather than the exact path would still be
        // caught reaching for the wrong row.
        try Data().write(to: project.appendingPathComponent("Exports/decoy.pdf"))
        // The decoy is stamped (and so sorts) STRICTLY FIRST, so a join that
        // falls back to "the first .pdf record" rather than an exact
        // `outputPath` match reaches for it instead — proving the assertion
        // below is not merely passing because the real match happened to sort
        // first on its own.
        let now = Date()
        let decoy = publication(version: "9.9", outputPath: "Exports/decoy.pdf",
                                compiledAt: now.addingTimeInterval(-60))
        let pub = publication(version: "0.1", outputPath: "Exports/\(lyingName)",
                              compiledAt: now)
        let store = PublicationStore(projectURL: project)
        try await store.append(decoy)
        try await store.append(pub)

        let entries = await ExportsListView.Model(projectURL: project).scan()

        let entry = try XCTUnwrap(entries.first { $0.name == lyingName })
        XCTAssertEqual(entry.record?.publicationID, pub.publicationID,
                       "expected the record whose outputPath actually matches "
                       + "this file, not the filename's own claim of v9.9")
    }

    // MARK: - Task 6: an unreadable catalog

    /// A catalog that cannot be read costs entries their record and nothing
    /// else — every file still lists, and scanning does not throw or crash.
    func test_anUnreadableCatalogLeavesEntriesWithNoRecordAndDoesNotCrash() async throws {
        let project = try makeProject()
        try Data().write(to: project.appendingPathComponent("Exports/book.pdf"))
        // A directory squatting another device's publications file — the same
        // fixture `PublishPreviewCentreTests` uses to make `load()` throw
        // `ReadError.unreadableFile` for the whole catalog.
        let squatted = PublicationStore.fileURL(
            deviceSlug: DeviceSlug.make(from: "otherdevice"), in: project)
        try FileManager.default.createDirectory(
            at: squatted, withIntermediateDirectories: true)

        let entries = await ExportsListView.Model(projectURL: project).scan()

        let entry = try XCTUnwrap(entries.first { $0.name == "book.pdf" })
        XCTAssertNil(entry.record,
                     "the catalog could not be read, so there is no record to "
                     + "attach — and the scan must still complete rather than "
                     + "throw or crash")
    }

    // MARK: - Task 6: the row actually draws it

    /// **The wiring, mounted.** Data-level coverage above proves the join;
    /// this proves the row's secondary `Text` is actually on screen when a
    /// record exists, and absent when one doesn't — the two facts a writer
    /// looking at the Exports footer would notice.
    func test_theRowDrawsTheRecordsPartsWhenThereIsOneAndNothingWhenThereIsNot() async throws {
        let project = try makeProject()
        try Data().write(to: project.appendingPathComponent("Exports/book.pdf"))
        try Data().write(to: project.appendingPathComponent("Exports/orphan.pdf"))
        let pub = publication(version: "1.0", outputPath: "Exports/book.pdf",
                              imprint: "special", language: "en+sr")
        try await PublicationStore(projectURL: project).append(pub)

        let window = mount(project)
        let expectedParts = PublishPreviewCentre.parts(for: pub).joined(separator: " \u{00B7} ")
        let texts = try await settledTexts(in: window) { $0.contains(expectedParts) }

        XCTAssertTrue(texts.contains { $0.contains("book.pdf") },
                      "premise: the matched file is listed. Texts: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains(expectedParts) },
                      "expected the matching record's identity drawn under "
                      + "its file. Texts: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("orphan.pdf") },
                      "premise: the unmatched file is listed too. Texts: \(texts)")
        XCTAssertFalse(
            texts.contains { $0.contains("orphan.pdf") && $0.contains("\u{00B7}") },
            "the orphan file has no record and must draw no secondary line")
    }

    // MARK: - Fixtures

    private func makeProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportsRecordTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Exports", isDirectory: true),
            withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func publication(version: String, outputPath: String,
                             imprint: String? = nil,
                             language: String? = nil,
                             compiledAt: Date = Date()) -> Publication {
        Publication(
            publicationID: "pub-\(UUID().uuidString.prefix(8))",
            version: version, label: nil, format: .pdf,
            outputPath: outputPath, snapshotID: "snap-\(version)",
            checkpointID: "ckpt-\(version)", republishedFrom: nil,
            compiledAt: compiledAt, maughamVersion: "test",
            tectonicVersion: "test", language: language, imprint: imprint)
    }

    private func mount(_ projectURL: URL) -> NSWindow {
        let window = TestWindow.mount(AnyView(ExportsListView(projectURL: projectURL)),
                                      size: CGSize(width: 400, height: 300),
                                      as: SilentTestWindow.self)
        windows.append(window)
        pump(0.1)
        return window
    }

    /// The window's accessibility text once `satisfied` holds, or the last
    /// read if the deadline passes — `refresh()`'s catalog load is
    /// asynchronous, so the first read after mounting routinely predates it.
    private func settledTexts(
        in window: NSWindow, until satisfied: @escaping (String) -> Bool
    ) async throws -> [String] {
        try requireAssistiveClient()
        var texts = try axTexts(in: window)
        for _ in 0..<30 where !texts.contains(where: satisfied) {
            pump(0.1)
            try? await Task.sleep(for: .milliseconds(20))
            texts = try axTexts(in: window)
        }
        return texts
    }
}
