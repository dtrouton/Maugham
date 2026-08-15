import XCTest
@testable import Maugham

/// Pins the properties that make skipping on a failed canary honest rather
/// than a way to hide red. See `TectonicProbe`'s "LOAD-BEARING PROPERTY".
final class TectonicProbeTests: XCTestCase {

    // MARK: - the canary cannot be broken by this project's own output

    func test_theCanaryDependsOnNothingThisProjectEmits() {
        let source = TectonicProbe.canarySource
        // If any of these ever appear, the canary can fail because a template,
        // a style file or a body emitter regressed — and every real compile
        // suite would then SKIP on what is actually a code defect.
        for forbidden in ["\\input", "\\include", "\\usepackage",
                          "template", "maugham", "Maugham"] {
            XCTAssertFalse(
                source.contains(forbidden),
                "the canary must depend on nothing this project writes, but it "
                + "references '\(forbidden)': \(source)")
        }
        XCTAssertTrue(source.contains("\\documentclass{article}"),
                      "the canary should be a bare standalone document")
    }

    // MARK: - the two failure arms are told apart

    func test_aMissingBinaryIsNamedAsSuchRatherThanBlamedOnTheBundle() async {
        let answer = await TectonicProbe.runCanary(
            binary: nil, cacheDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(answer, .notBundled)
    }

    func test_aNonZeroExitReportsTheBundleUnusable_carryingTheTailNotTheHead() async throws {
        // A stand-in for tectonic that reproduces the shape of the run this
        // probe exists for: thousands of characters of download chatter, then
        // the one line that says what actually went wrong, then a non-zero
        // exit. The head of that log is useless; the tail is the diagnosis.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProbeFake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("fake-tectonic")
        try """
            #!/bin/sh
            i=0
            while [ $i -lt 400 ]; do echo "note: downloading hyph-$i.tex"; i=$((i+1)); done
            echo "error: connection closed by the bundle host"
            exit 1
            """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let answer = await TectonicProbe.runCanary(
            binary: fake, cacheDirectory: dir)

        guard case .bundleUnavailable(let tail) = answer else {
            return XCTFail("expected .bundleUnavailable, got \(answer)")
        }
        XCTAssertTrue(tail.contains("connection closed by the bundle host"),
                      "the tail must carry the diagnosis; got: \(tail)")
        XCTAssertFalse(tail.contains("hyph-0.tex"),
                       "the tail must NOT be the head of the download chatter; got: \(tail)")
    }

    func test_anExitZeroThatWroteNoPdfIsStillNotReady() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProbeFake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("silent-tectonic")
        try "#!/bin/sh\nexit 0\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let answer = await TectonicProbe.runCanary(binary: fake, cacheDirectory: dir)

        guard case .bundleUnavailable(let why) = answer else {
            return XCTFail("expected .bundleUnavailable, got \(answer)")
        }
        XCTAssertTrue(why.contains("wrote no PDF"),
                      "the reason should say what was missing; got: \(why)")
    }

    // MARK: - the tail helper

    func test_tailKeepsTheEndAndMarksTheCut() {
        let log = (0..<500).map { "line \($0)" }.joined(separator: "\n")
        let tail = TectonicProbe.tail(of: log, limit: 40)
        XCTAssertTrue(tail.hasPrefix("…"), "a truncated tail should say so")
        XCTAssertTrue(tail.hasSuffix("line 499"))
        XCTAssertFalse(tail.contains("line 0\n"))
    }

    func test_aShortLogIsCarriedWhole() {
        XCTAssertEqual(TectonicProbe.tail(of: "  boom  ", limit: 40), "boom")
    }

    // MARK: - one canary per process

    func test_theCanaryRunsAtMostOncePerProcess() async {
        _ = await TectonicProbe.readiness()
        let after = await TectonicProbe.Memo.shared.runs
        _ = await TectonicProbe.readiness()
        _ = await TectonicProbe.readiness()
        let later = await TectonicProbe.Memo.shared.runs
        XCTAssertEqual(after, later,
                       "the answer is memoized for the process — two suites in "
                       + "one worker must not race two bundle fetches into one "
                       + "cache directory")
    }
}
