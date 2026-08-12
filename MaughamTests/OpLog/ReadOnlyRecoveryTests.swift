import XCTest
import MaughamCore
@testable import Maugham

/// Recovery spec §4: the read-only partial view can write NOTHING — zero ops
/// appended, `.md` byte-identical, pending file untouched, no checkpoint, no
/// seal — including across close(). This is the load-bearing rung: every
/// other rung is safe only because this one is.
@MainActor
final class ReadOnlyRecoveryTests: XCTestCase {

    /// Full gauntlet: open partial, hit EVERY mutation entry point, close.
    func test_partialView_writesNothing_evenAcrossClose() async throws {
        let (project, docURL) = try makeTestProject(prefix: "ROREC", initialMd: "One.\n\nTwo.\n")
        // A real session first, so the op log + a pending file exist.
        let doc1 = try await Document.load(url: docURL, device: "m", session: "s", presenter: nil)
        let docId = doc1.docId
        doc1.setFullText("One.\n\nTwo.\n\nThree.\n")
        try await doc1.flushBurstNow()
        await doc1.close()

        // Squat a second device's file so the strict load refuses…
        let bad = DeviceSlug.make(from: "bad")
        let badURL = OpLogStore.opLogFileURL(forDocId: docId, deviceSlug: bad, in: project)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)
        do {
            _ = try await Document.load(url: docURL, device: "m", session: "s", presenter: nil)
            XCTFail("precondition: the strict load must refuse")
        } catch {}

        // …then snapshot every byte the partial view must not change.
        let opsDir = project.appendingPathComponent(".maugham/ops")
        func snapshot() throws -> [String: Data] {
            var out: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: opsDir.path)
            where !name.hasPrefix(".") {
                // The squatting directory has no data; skip it.
                let url = opsDir.appendingPathComponent(name)
                if let d = try? Data(contentsOf: url) { out[name] = d }
            }
            out["__md__"] = try Data(contentsOf: docURL)
            let pendingDir = project.appendingPathComponent(".maugham/pending")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: pendingDir.path)) ?? [] {
                out["pending/\(name)"] = try? Data(contentsOf: pendingDir.appendingPathComponent(name))
            }
            return out
        }
        let before = try snapshot()

        // The partial open succeeds where the strict load refused…
        let doc = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil,
            recovery: .readOnlyPartial)
        XCTAssertTrue(doc.isReadOnlyRecovery)
        XCTAssertEqual(doc.readOnlyRecovery?.unreadableFiles.map(\.name),
                       [badURL.lastPathComponent], "the banner's names ride on the doc")
        XCTAssertTrue(doc.displayText.contains("Three."), "the readable history is all there")

        // …every mutation entry point no-ops…
        doc.setFullText("VANDALISM")
        doc.setParagraph(id: "zzzz", text: "VANDALISM")
        _ = doc.insertParagraph(after: nil, text: "VANDALISM")
        doc.deleteParagraph(id: "zzzz")
        doc.reorder(sequence: [])
        try await doc.flushBurstNow()
        XCTAssertTrue(doc.displayText.contains("Three."), "the view text never took the writes")
        XCTAssertFalse(doc.displayText.contains("VANDALISM"))

        // …and close writes nothing either (no flush, no autosave, no seal,
        // no pending clear).
        await doc.close()
        XCTAssertEqual(try snapshot(), before,
                       "byte-identical durable state after the whole gauntlet")
    }

    /// A clean project refuses the recovery mode: it exists only for the
    /// refusal path, never as a casual lenient open.
    func test_partialView_refusesWhenNothingIsUnreadable() async throws {
        let (_, docURL) = try makeTestProject(prefix: "ROREC2", initialMd: "Fine.\n")
        let doc1 = try await Document.load(url: docURL, device: "m", session: "s", presenter: nil)
        await doc1.close()
        do {
            _ = try await Document.load(
                url: docURL, device: "m", session: "s", presenter: nil,
                recovery: .readOnlyPartial)
            XCTFail("recovery mode on a healthy doc must refuse — use the normal load")
        } catch DocumentRecoveryError.nothingUnreadable {
            // The dedicated refusal: every file read cleanly, so there is no
            // partial view to offer and the normal load is the right door.
        }
    }

    // MARK: - The census

    /// The gauntlet above enumerates today's mutation entry points BY HAND, so
    /// it says nothing about the next one somebody writes. This census is the
    /// standing guard: in `Maugham/OpLog/Document*.swift`, every function that
    /// reaches `opStore.append(` or `pending.recordChange(` must consult the
    /// writability choke point FIRST.
    ///
    /// Tripwire-32 shape — **count the array, not this comment.** The
    /// allowlist below is the whole exemption list, each entry carrying why it
    /// cannot take a guard; a new writer is an offender until it is guarded or
    /// argued into that array in a review.
    func test_everyOpLogWriterConsultsTheWritabilityChokePoint() throws {
        var offenders: [String] = []
        for url in try Self.documentSourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            offenders += Self.unguardedWriters(
                in: source, file: url.lastPathComponent)
        }
        XCTAssertEqual(
            offenders, [],
            """
            Unguarded op-log writer(s). Open the function with \
            `rejectMutationIfNotWritable("name")` (Void) or \
            `try requireWritable("name")` (value-returning) before it writes — \
            or, if it genuinely cannot, add it to `writerAllowlist` with the \
            reason. See recovery spec §4.
            """)
    }

    /// The census is only worth its runtime if it FAILS on an offender. This
    /// plants three: an unguarded writer, one whose guard sits AFTER the write
    /// (the subtle case a substring check would wave through), and one that
    /// records into the pending buffer. The fourth function is properly
    /// guarded and must NOT be reported.
    func test_theCensusFailsOnAPlantedOffender() {
        let planted = """
            extension Document {
                func plantedUnguardedWriter() async throws {
                    try await opStore.append(op)
                }
                func plantedGuardTooLate() async throws {
                    try await opStore.append(op)
                    if rejectMutationIfNotWritable("plantedGuardTooLate") { return }
                }
                func plantedPendingWriter() {
                    pending.recordChange(paragraphId: id, prior: nil, next: t)
                }
                func plantedProperlyGuarded() async throws {
                    if rejectMutationIfNotWritable("plantedProperlyGuarded") { return }
                    try await opStore.append(op)
                }
            }
            """
        let found = Self.unguardedWriters(in: planted, file: "Planted.swift")
        XCTAssertEqual(found.count, 3, "planted offenders missed: \(found)")
        for name in ["plantedUnguardedWriter", "plantedGuardTooLate",
                     "plantedPendingWriter"] {
            XCTAssertTrue(found.contains { $0.contains(name) },
                          "census missed \(name): \(found)")
        }
        XCTAssertFalse(found.contains { $0.contains("plantedProperlyGuarded") },
                       "census reported a correctly guarded function")
    }

    // MARK: - Census machinery

    /// Functions exempt from the census, each with the reason it cannot carry
    /// a guard. Keep this array SHORT and argued.
    private static let writerAllowlist: Set<String> = [
        // `Document.load`'s crash-recovery fold. Static: it runs before the
        // Document exists, so there is no instance to ask about writability —
        // and the recovery load reaches neither, because it skips the fold.
        "load",
    ]

    private static func documentSourceFiles() throws -> [URL] {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()   // OpLog
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
        let opLogDir = repoRoot.appendingPathComponent(
            "Maugham/OpLog", isDirectory: true)
        let all = try FileManager.default.contentsOfDirectory(
            at: opLogDir, includingPropertiesForKeys: nil)
        let documentFiles = all.filter {
            $0.lastPathComponent.hasPrefix("Document")
                && $0.pathExtension == "swift"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(
            documentFiles.isEmpty,
            "census found no Document*.swift to scan — the path is wrong, and a "
                + "census that scans nothing passes vacuously")
        return documentFiles
    }

    /// For every write call in `source`, find the nearest preceding `func`
    /// declaration and require a guard token between the two. Deliberately
    /// text-based and brace-free: "the guard appears before the write, inside
    /// the same declaration" is the property, and matching it this way cannot
    /// be fooled by a guard that sits after the write.
    private static func unguardedWriters(
        in source: String, file: String
    ) -> [String] {
        let writeTokens = ["opStore.append(", "pending.recordChange("]
        // The last two are the narrower recovery-only arm, which four
        // annotation sites take because M5-AN-048 pins their closed-doc
        // behaviour. They still consult the choke point, which is what the
        // census is about.
        let guardTokens = [
            "rejectMutationIfNotWritable(", "requireWritable(",
            "rejectMutationIfReadOnlyRecovery(", "requireNotReadOnlyRecovery(",
        ]

        // Every `func ` declaration, in source order, with its name.
        var funcStarts: [(at: String.Index, name: String)] = []
        var cursor = source.startIndex
        while let r = source.range(of: "func ", range: cursor..<source.endIndex) {
            let afterKeyword = source[r.upperBound...]
            let name = afterKeyword.prefix {
                $0.isLetter || $0.isNumber || $0 == "_"
            }
            funcStarts.append((at: r.lowerBound, name: String(name)))
            cursor = r.upperBound
        }

        var offenders: [String] = []
        for token in writeTokens {
            var searchFrom = source.startIndex
            while let call = source.range(
                of: token, range: searchFrom..<source.endIndex) {
                searchFrom = call.upperBound
                guard let owner = funcStarts.last(
                    where: { $0.at < call.lowerBound }) else { continue }
                if writerAllowlist.contains(owner.name) { continue }
                let body = source[owner.at..<call.lowerBound]
                let guarded = guardTokens.contains { body.contains($0) }
                if !guarded {
                    offenders.append("\(file): \(owner.name) → \(token)")
                }
            }
        }
        return offenders.sorted()
    }
}
