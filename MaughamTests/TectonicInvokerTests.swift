import XCTest
@testable import Maugham

final class TectonicInvokerTests: XCTestCase {

    var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TectonicInvokerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testCompiles_simpleDocument() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
        let binary = try XCTUnwrap(TectonicProbe.binaryURL())

        let texPath = workDir.appendingPathComponent("doc.tex")
        try """
        \\documentclass{article}
        \\begin{document}
        Hello, tectonic.
        \\end{document}
        """.write(to: texPath, atomically: true, encoding: .utf8)

        let cacheURL = try TectonicCache.ensureCacheExists()
        let invoker = TectonicInvoker(binaryURL: binary, cacheURL: cacheURL)
        let result = try await invoker.compile(
            texFile: texPath,
            workingDirectory: workDir,
            outputFormat: .pdf
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("doc.pdf").path))
    }

    func testReports_nonZero_onSyntaxError() async throws {
        // Still the right premise: this test asserts a LaTeX error in the log,
        // which a run that never obtained its TeX bundle cannot produce.
        try await TectonicProbe.requireReady()
        let binary = try XCTUnwrap(TectonicProbe.binaryURL())

        let texPath = workDir.appendingPathComponent("bad.tex")
        try """
        \\documentclass{article}
        \\begin{document}
        \\undefined_command
        \\end{document}
        """.write(to: texPath, atomically: true, encoding: .utf8)

        let cacheURL = try TectonicCache.ensureCacheExists()
        let invoker = TectonicInvoker(binaryURL: binary, cacheURL: cacheURL)
        let result = try await invoker.compile(
            texFile: texPath, workingDirectory: workDir, outputFormat: .pdf)

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.combinedLog.contains("Undefined control sequence")
                      || result.combinedLog.contains("undefined"))
    }
}
