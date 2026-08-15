import Foundation
import XCTest
@testable import Maugham

/// Reads, off the machine the suite is actually running on, whether a real
/// tectonic PDF compile can succeed right now — so a suite whose premise is
/// unattainable skips BY NAME instead of reporting the environment as a code
/// defect.
///
/// WHY (run 31874029028, 2026-08-15). The bundled `tectonic` fetches its TeX
/// Live bundle from a third-party host on a cold cache. Nothing retried that
/// fetch and nothing cached it, so when it died partway through,
/// `PublishingEndToEndTests` produced eight failures whose root was one line:
/// `status: failed` with an EMPTY `errors` array — no LaTeX error at all,
/// because typesetting never began. Eight red assertions that said nothing
/// about the code. (The same gate re-fetched successfully 8.3s later in
/// another suite, which is what a transient fetch failure looks like from the
/// inside; `.github/workflows/ci.yml` now caches the bundle so the common path
/// never touches the network. This probe covers the residual cold miss.)
///
/// THE LOAD-BEARING PROPERTY — read this before changing `canarySource`. The
/// canary is a standalone three-line document that uses NO package, NO
/// `\input`, and nothing the app emits. It therefore cannot fail because a
/// body emitter, a template, a style file or a manuscript regressed — only
/// because tectonic itself cannot run or cannot obtain its bundle. That is
/// what makes skipping on a canary failure honest rather than a way to hide
/// red: break `LaTeXBodyEmitter` and the canary still passes, so every real
/// compile test still runs and still goes red. `TectonicProbeTests` pins it.
///
/// Usage — from a suite that performs a REAL compile:
///
///     override func setUp() async throws {
///         try await TectonicProbe.requireReady()
///         …
///     }
///
/// The canary runs at most once per test-host process (suites run in parallel
/// worker processes, each of which reads the premise for itself), and
/// concurrent callers within a process await the same run rather than racing
/// two downloads into one cache directory.
enum TectonicProbe {

    enum Readiness: Sendable, Equatable {
        /// A canary compile just produced a PDF — real compiles can run.
        case ready
        /// No `tectonic` in the test host's app bundle. In the xctest harness
        /// `Bundle.main` is not the host `.app`, so `TectonicLocator.locate()`
        /// returns nil even when tectonic IS bundled — hence the explicit
        /// host probe in `binaryURL()`. This case means it is genuinely absent.
        case notBundled
        /// tectonic is present but could not produce a PDF for a document that
        /// depends on nothing this project wrote. The payload is the tail of
        /// its log — the tail, not the head, because the head of a cold run is
        /// several thousand characters of `note: downloading …`.
        case bundleUnavailable(String)
    }

    // MARK: - the premise

    /// The tectonic binary inside the test HOST app bundle, or nil.
    static func binaryURL(hostBundlePath: String? = nil) -> URL? {
        let testBundlePath = hostBundlePath
            ?? Bundle(for: BundleAnchor.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        return try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))
    }

    /// The process-wide answer, computed once.
    static func readiness() async -> Readiness {
        await Memo.shared.value()
    }

    /// Skip the calling test by name when a real compile cannot succeed here.
    static func requireReady(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        switch await readiness() {
        case .ready:
            return
        case .notBundled:
            throw XCTSkip(
                "tectonic is not bundled in this test host, so a real compile "
                + "cannot run — every assertion here would be about the build "
                + "product, not the code.",
                file: file, line: line)
        case .bundleUnavailable(let tail):
            throw XCTSkip(
                "tectonic is bundled but could not compile a document that "
                + "depends on nothing this project emits, so its TeX bundle is "
                + "unusable in this process (a cold-cache fetch failure is the "
                + "known cause — see TectonicProbe). Skipping rather than "
                + "reporting the environment as a defect. Canary log tail: "
                + tail,
                file: file, line: line)
        }
    }

    // MARK: - the canary

    /// Deliberately dependency-free — see THE LOAD-BEARING PROPERTY above.
    static let canarySource = """
        \\documentclass{article}
        \\begin{document}
        tectonic canary
        \\end{document}
        """

    /// Generous against the ~12s cold fetch measured on CI, and under the
    /// gate's own 120s per-test allowance so a stuck fetch reports as a skip
    /// with a diagnosis rather than being killed by the harness.
    static let canaryDeadline: TimeInterval = 90

    /// Runs the canary. `binary` and `cacheDirectory` are parameters rather
    /// than lookups so `TectonicProbeTests` can drive both failure arms
    /// without waiting on a real network.
    static func runCanary(binary: URL?, cacheDirectory: URL?) async -> Readiness {
        guard let binary else { return .notBundled }
        guard let cacheDirectory else {
            return .bundleUnavailable("no caches directory on this machine")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TectonicCanary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let tex = dir.appendingPathComponent("canary.tex")
            try canarySource.write(to: tex, atomically: true, encoding: .utf8)
            let outcome = try await spawn(
                binary: binary, tex: tex, workingDirectory: dir,
                cacheDirectory: cacheDirectory)
            guard outcome.exitCode == 0 else {
                return .bundleUnavailable(tail(of: outcome.log))
            }
            let pdf = dir.appendingPathComponent("canary.pdf")
            guard FileManager.default.fileExists(atPath: pdf.path) else {
                return .bundleUnavailable(
                    "tectonic exited 0 but wrote no PDF. " + tail(of: outcome.log))
            }
            return .ready
        } catch {
            return .bundleUnavailable("canary could not be run: \(error)")
        }
    }

    /// The invocation is spelled here rather than through `TectonicInvoker`
    /// because the probe needs the `Process` handle: without it a hung fetch
    /// could not be given a deadline, and a hang is one of the failure shapes
    /// this exists to absorb.
    private static func spawn(
        binary: URL, tex: URL, workingDirectory: URL, cacheDirectory: URL
    ) async throws -> (exitCode: Int32, log: String) {
        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = workingDirectory
        process.arguments = [
            "-X", "compile", "--outdir", workingDirectory.path, tex.path
        ]
        var env = ProcessInfo.processInfo.environment
        env["TECTONIC_CACHE_DIR"] = cacheDirectory.path
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(canaryDeadline * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { proc in
                let out = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let err = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let log = (String(data: out, encoding: .utf8) ?? "")
                    + (String(data: err, encoding: .utf8) ?? "")
                cont.resume(returning: (proc.terminationStatus, log))
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// The TAIL. A cold tectonic run opens with thousands of characters of
    /// `note: downloading …`; the head of that log is what made run
    /// 31874029028 undiagnosable from its own artifact.
    static func tail(of log: String, limit: Int = 1200) -> String {
        let trimmed = log.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…" + String(trimmed.suffix(limit))
    }

    // MARK: - memoization

    /// An actor, not a `static var` + lock, so two suites starting in the same
    /// process await one canary instead of racing two bundle fetches into one
    /// cache directory.
    actor Memo {
        static let shared = Memo()
        private var cached: Readiness?
        /// Counts actual canary runs so `TectonicProbeTests` can pin
        /// once-per-process without inferring it from timing.
        private(set) var runs = 0

        func value() async -> Readiness {
            if let cached { return cached }
            runs += 1
            let answer = await TectonicProbe.runCanary(
                binary: TectonicProbe.binaryURL(),
                cacheDirectory: try? TectonicCache.ensureCacheExists())
            cached = answer
            return answer
        }
    }

    /// Only exists to give `Bundle(for:)` a class in this test bundle.
    private final class BundleAnchor {}
}
