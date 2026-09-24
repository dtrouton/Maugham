import XCTest
import MaughamCore
@testable import Maugham

/// **`Document.close()` is single-flight** (F7 second fix round, I-A).
///
/// `isClosed` flips only at the end of a close, after a dozen suspensions, so
/// two closers arriving together used to run the whole close twice: the
/// pending burst appended twice, the chain sealed twice, the tail rotated
/// twice. A remote rename of an open piece made that ordinary — the adoption
/// lets go of the Document while `EditorHost`'s path-keyed reload closes it
/// too. The first caller now runs the close; every later one waits for it.
@MainActor
final class DocumentCloseSingleFlightTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_twoConcurrentClosesRunTheCloseOnceAndAppendTheBurstOnce() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "SingleFlight", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let path = try XCTUnwrap(store.manifest.structure[0].path)
        let doc = try await Document.load(
            url: url.appendingPathComponent(path), actor: .author,
            session: "single-flight", presenter: nil)
        let burstsBefore = try await doc.opLog().filter { $0.kind == .typingBurst }.count
        // A pending burst: typed, not yet flushed.
        doc.setFullText(doc.displayText + "\n\nWritten once, closed twice.")

        // Hold the first close open across a real suspension, so the second
        // caller arrives while it is in flight — the remote-rename shape.
        doc.closeBodyWillRun = { try? await Task.sleep(for: .milliseconds(100)) }
        async let first: Void = doc.close()
        async let second: Void = doc.close()
        _ = await (first, second)

        XCTAssertTrue(doc.isClosed)
        XCTAssertEqual(doc.closeBodyRuns, 1, "the close ran once for both callers")

        let reopened = try await Document.load(
            url: url.appendingPathComponent(path), actor: .author,
            session: "single-flight-check", presenter: nil)
        let burstsAfter = try await reopened.opLog().filter { $0.kind == .typingBurst }.count
        XCTAssertEqual(burstsAfter, burstsBefore + 1, "the pending burst reached the op log exactly once")
        XCTAssertEqual(
            reopened.displayText.components(separatedBy: "Written once, closed twice.").count - 1, 1)
        await reopened.close()
    }
}
