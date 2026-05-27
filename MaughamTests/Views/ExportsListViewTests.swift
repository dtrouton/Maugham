import XCTest
@testable import Maugham

final class ExportsListViewTests: XCTestCase {

    func testModel_listsExportsContents() throws {
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
        let entries = model.scan()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.name).sorted(),
                       ["Title-v0.1.pdf", "Title-v0.2.pdf"])
    }

    func testModel_emptyDirectory_returnsEmpty() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyExports-\(UUID().uuidString)")
        let model = ExportsListView.Model(projectURL: tmp)
        XCTAssertTrue(model.scan().isEmpty)
    }

    func testModel_missingExportsDir_returnsEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoExports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Project folder exists but Exports/ does not.
        let model = ExportsListView.Model(projectURL: tmp)
        XCTAssertTrue(model.scan().isEmpty)
    }

    func testModel_filtersToPDFAndEPUBOnly() throws {
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

        let entries = ExportsListView.Model(projectURL: tmp).scan()
        XCTAssertEqual(Set(entries.map(\.name)), ["Title.pdf", "Title.epub"])
    }

    func testModel_sortsLexicallyDescending() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SortExports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let exports = tmp.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exports, withIntermediateDirectories: true)
        try Data().write(to: exports.appendingPathComponent("Book-v0.1.pdf"))
        try Data().write(to: exports.appendingPathComponent("Book-v0.3.pdf"))
        try Data().write(to: exports.appendingPathComponent("Book-v0.2.pdf"))

        let entries = ExportsListView.Model(projectURL: tmp).scan()
        XCTAssertEqual(entries.map(\.name),
                       ["Book-v0.3.pdf", "Book-v0.2.pdf", "Book-v0.1.pdf"])
    }
}
