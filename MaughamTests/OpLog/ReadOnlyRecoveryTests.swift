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
}
