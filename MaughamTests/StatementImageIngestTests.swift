import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// Visual language takes pictures (M1A Task 12, spec §7; umbrella §3.2 —
/// visual language is *mixed: images, references and prose*).
///
/// **Driven through the real delivery path**, like every other statement mount
/// test: the production `StatementPane` is hosted in an `NSHostingView`, an
/// image is put on the general pasteboard, and `MaughamTextView.paste(_:)` — the
/// production override — is what runs. Nothing here hand-calls the store's
/// ingest and then asserts the store did what it was told.
///
/// **The ref must reach the OP LOG.** A statement's `.md` is derived output
/// (hard invariant); a ref written into the file would be discarded on the next
/// re-materialize, and a test asserting against the `.md` would not notice. So
/// every assertion below reads `derivedText(forDocId:)`, which walks
/// `.maugham/ops/`.
@MainActor
final class StatementImageIngestTests: XCTestCase {

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.tearDown() }
        fixtures.removeAll()
        NSPasteboard.general.clearContents()
        try await super.tearDown()
    }

    private func fixture(named name: String) async throws -> StatementMountFixture {
        let made = try await StatementMountFixture.novel(named: name)
        fixtures.append(made)
        return made
    }

    private func makeImage(_ side: Int = 12) throws -> NSImage {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    /// Put a picture where `MaughamTextView.paste(_:)` will find one. The
    /// production override reads `NSPasteboard.general` directly, so this is the
    /// pasteboard the writer's own ⌘V uses.
    private func putImageOnTheClipboard() throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([try makeImage()])
    }

    /// The well beside a statement, **derived from the statement's own path**
    /// rather than spelled — `ImagePasteHandler.destination` builds
    /// `<slug>_assets` from the note's filename, which is why `visual-language.md`
    /// yields its well with no literal anywhere in production code.
    private func well(beside statement: Statement, in projectURL: URL) -> URL {
        let file = projectURL.appendingPathComponent(statement.path)
        return file
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(file.deletingPathExtension().lastPathComponent)_assets")
    }

    private func files(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    // MARK: - The picture lands, and the ref lands in the op log

    /// **⌘V of a picture into visual language puts the file in the statement's
    /// own well and the ref in its op log.**
    ///
    /// Both halves matter and they fail differently: a ref with no file behind it
    /// renders an empty box, and a file with no ref is an orphan the writer never
    /// sees. The op-log half is contract 7 — a statement is a `Document`, so the
    /// ref goes in through the same `setFullText` binding a keystroke takes, and a
    /// direct `.md` write would be discarded on re-materialize.
    func test_anImagePastedIntoVisualLanguageLandsInItsOwnWell() async throws {
        let fixture = try await fixture(named: "VisualLanguagePaste")
        let statement = try await fixture.store.createStatement(
            kind: .visualLanguage, scope: .project)
        let assets = well(beside: statement, in: fixture.projectURL)

        let window = await fixture.host(kind: .visualLanguage, activeDocumentId: nil)
        let textView = try fixture.textView(in: window)

        // Control: nothing is in the well and nothing is in the op log, so the
        // assertions below cannot pass on something that was already there.
        XCTAssertTrue(files(in: assets).isEmpty)
        XCTAssertTrue(fixture.ops(forDocId: statement.id).isEmpty)

        try putImageOnTheClipboard()
        textView.paste(nil)
        await fixture.pumpUntil(deadline: 5) { !self.files(in: assets).isEmpty }
        try await fixture.settle(window, expectingOpsFor: statement.id)

        let landed = files(in: assets)
        XCTAssertEqual(landed.count, 1,
                       "the picture belongs in the statement's own well "
                       + "(\(assets.lastPathComponent)); found \(landed)")
        let filename = try XCTUnwrap(landed.first)
        XCTAssertTrue(filename.hasSuffix(".png"), "got \(filename)")

        let text = fixture.derivedText(forDocId: statement.id)
        XCTAssertTrue(text.contains("![](./\(assets.lastPathComponent)/\(filename))"),
                      "the ref must reach the OP LOG — a statement's .md is "
                      + "derived and an out-of-band write to it is discarded. "
                      + "The log derives to: \"\(text)\"")
        XCTAssertEqual(Set(fixture.ops(forDocId: statement.id).map(\.kind)), [.typingBurst],
                       "a ref is text in a Document; it needs no new OpKind")
    }

    /// **The first thing a writer does with an empty mood board may well be to
    /// paste a picture into it**, and that must mint the statement rather than
    /// quietly doing nothing.
    ///
    /// The well cannot be known before the file exists —
    /// `vacantStatementPath` steers around an occupied `visual-language.md`, so
    /// the path is find-or-create's answer and not a constant. That is why this
    /// route creates the statement first and appends the ref through the pane's
    /// own unbound-write mint, rather than inserting at the caret.
    func test_pastingIntoAVisualLanguageThatDoesNotExistYetMintsIt() async throws {
        let fixture = try await fixture(named: "VisualLanguageMint")
        XCTAssertNil(fixture.store.statement(kind: .visualLanguage, scope: .project),
                     "precondition: absence is valid and the pane mints nothing "
                     + "just because it was looked at (§4.3)")

        let window = await fixture.host(kind: .visualLanguage, activeDocumentId: nil)
        let textView = try fixture.textView(in: window)

        try putImageOnTheClipboard()
        textView.paste(nil)
        await fixture.pumpUntil(deadline: 5) {
            fixture.store.statement(kind: .visualLanguage, scope: .project) != nil
        }

        let statement = try XCTUnwrap(
            fixture.store.statement(kind: .visualLanguage, scope: .project),
            "pasting a picture is an act, and an act mints the statement")
        let assets = well(beside: statement, in: fixture.projectURL)
        await fixture.pumpUntil(deadline: 5) { !self.files(in: assets).isEmpty }
        try await fixture.settle(window, expectingOpsFor: statement.id)

        XCTAssertEqual(files(in: assets).count, 1, "the picture is in the well")
        let text = fixture.derivedText(forDocId: statement.id)
        XCTAssertTrue(text.contains("![](./\(assets.lastPathComponent)/"),
                      "and the ref reached the op log: \"\(text)\"")
    }

    /// **Intent takes no pictures**, and this is the control that the wiring is
    /// scoped by kind rather than hung on every statement pane. Without it, a
    /// handler wired unconditionally would pass every test above.
    func test_intentTakesNoPicturesAtAll() async throws {
        let fixture = try await fixture(named: "IntentNoPictures")
        let statement = try await fixture.store.createStatement(
            kind: .intent, scope: .project)
        let assets = well(beside: statement, in: fixture.projectURL)

        let window = await fixture.host(kind: .intent, activeDocumentId: nil)
        let textView = try fixture.textView(in: window)

        try putImageOnTheClipboard()
        textView.paste(nil)
        await fixture.waitOut(0.5)
        try await fixture.settle(window)

        XCTAssertTrue(files(in: assets).isEmpty,
                      "an intent is prose about the writing; \(files(in: assets))")
        XCTAssertFalse(fixture.derivedText(forDocId: statement.id).contains("!["),
                       "and nothing was inserted into it")
    }

    // MARK: - When the well is on screen

    /// **The well is visual language's, and only while the editor is mounted.**
    ///
    /// Asked over the product of its inputs rather than the one path this task
    /// happened to drive — the shape that found both of `ProjectWindow`'s
    /// routing bugs.
    ///
    /// The unmounted half is the one with a defect behind it. `reconcile`
    /// releases the outgoing target and then suspends at `Document.load`; a drop
    /// landing in that window writes its ref into `draft`, and the
    /// `bind(carryingDraft: false)` waiting at the end of `reconcile` clears the
    /// draft without carrying it. The picture is in the well and the ref is gone
    /// — an orphan file and a writer who saw a drop accepted.
    func test_theWellIsVisualLanguagesAndOnlyWhileTheEditorIsMounted() {
        let key = "visual_language|project"
        for kind: Statement.Kind in [.intent, .visualLanguage, .unknown("newer")] {
            for resolved: String? in [nil, key, "intent|project"] {
                let shown = StatementEditorHost.showsPictureWell(
                    kind: kind, resolvedScope: resolved, scopeKey: key)
                let expected = StatementEditorHost.takesPictures(kind) && resolved == key
                XCTAssertEqual(shown, expected,
                               "kind=\(kind) resolvedScope=\(resolved ?? "nil")")
            }
        }

        // Controls: both halves of the conjunction are load-bearing.
        XCTAssertTrue(StatementEditorHost.showsPictureWell(
            kind: .visualLanguage, resolvedScope: key, scopeKey: key))
        XCTAssertFalse(StatementEditorHost.showsPictureWell(
            kind: .visualLanguage, resolvedScope: nil, scopeKey: key),
            "mid-reconcile, there is no target to write a ref into")
        XCTAssertFalse(StatementEditorHost.showsPictureWell(
            kind: .intent, resolvedScope: key, scopeKey: key),
            "an intent is prose about the writing")
    }

    // MARK: - What visual language refuses

    /// **A text file is refused on its way into visual language**, through the
    /// same saver guard every other well now has. Asserted at the store seam the
    /// pane's drop calls, because SwiftUI's drop delivery has no seam a test can
    /// post a drag session into.
    ///
    /// **Control, in the same test:** a real picture through the same call lands.
    func test_aTextFileIsRefusedOnItsWayIntoVisualLanguage() async throws {
        let fixture = try await fixture(named: "VisualLanguageRefusal")
        let notes = fixture.projectURL.appendingPathComponent("notes.txt")
        try Data("not a picture".utf8).write(to: notes)

        do {
            _ = try await fixture.store.addImage(
                toStatement: .visualLanguage, scope: .project, fileURL: notes)
            XCTFail("a text file is not a picture")
        } catch let error as ImagePasteHandler.ImagePasteError {
            guard case .notAnImage(let filename) = error else {
                return XCTFail("expected .notAnImage, got \(error)")
            }
            XCTAssertEqual(filename, "notes.txt")
        }

        XCTAssertNil(fixture.store.statement(kind: .visualLanguage, scope: .project),
                     "a refused picture leaves nothing behind — not even the "
                     + "statement it would have gone into")

        // Control.
        let png = fixture.projectURL.appendingPathComponent("real.png")
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        let ref = try await fixture.store.addImage(
            toStatement: .visualLanguage, scope: .project, fileURL: png)
        let statement = try XCTUnwrap(
            fixture.store.statement(kind: .visualLanguage, scope: .project))
        XCTAssertTrue(ref.contains("\(well(beside: statement, in: fixture.projectURL).lastPathComponent)/"),
                      "control: a real picture lands in the derived well; got \(ref)")
    }
}
