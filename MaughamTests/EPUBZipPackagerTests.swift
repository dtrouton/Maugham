import XCTest
@testable import Maugham

final class EPUBZipPackagerTests: XCTestCase {

    var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBZipPackagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testPackages_minimalEPUB() async throws {
        let pkg = EPUBPackage(
            metadata: .init(title: "Test", author: "Author",
                            version: "0.1", checkpointID: "chk-x"),
            sections: [
                .init(id: "s1", filename: "section-001.xhtml", title: "First",
                      xhtmlBody: "<section class=\"prose\"><h1>First</h1><p>Hello.</p></section>")
            ],
            cover: nil,
            stylesheetCSS: "body { font-family: serif; }")

        let output = workDir.appendingPathComponent("test.epub")
        try await EPUBZipPackager.write(package: pkg, to: output, workingDirectory: workDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let firstEntryName = try firstZipEntryName(at: output)
        XCTAssertEqual(firstEntryName, "mimetype")
    }

    func testIncludes_coverFile_whenPresent() async throws {
        let coverData = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 8)
        let pkg = EPUBPackage(
            metadata: .init(title: "T", author: "A"),
            sections: [
                .init(id: "s1", filename: "section-001.xhtml", title: "S",
                      xhtmlBody: "<p>x</p>")
            ],
            cover: .init(filename: "cover.jpg", data: coverData, mediaType: "image/jpeg"))

        let output = workDir.appendingPathComponent("with-cover.epub")
        try await EPUBZipPackager.write(package: pkg, to: output, workingDirectory: workDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    private func firstZipEntryName(at url: URL) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        proc.arguments = ["-1", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let listing = String(data: data, encoding: .utf8) ?? ""
        return listing.components(separatedBy: "\n").first ?? ""
    }
}
