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
        well(besideStatementAt: statement.path, in: projectURL)
    }

    /// The same derivation over a path alone, for the failure tests below: they
    /// need to know where the well WILL be before the statement that owns it
    /// exists, and a second spelling of `<slug>_assets` here would be a copy of
    /// the rule `ImagePasteHandler.destination` owns.
    private func well(besideStatementAt path: String, in projectURL: URL) -> URL {
        let file = projectURL.appendingPathComponent(path)
        return file
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(file.deletingPathExtension().lastPathComponent)_assets")
    }

    /// The relative path a fresh novel mints a statement of this kind at, read
    /// off a REAL mint in a sibling project of the same factory.
    ///
    /// `vacantStatementPath` owns that convention — it steers around an occupied
    /// `visual-language.md` — so asking a sibling is how a test learns the path
    /// before minting without spelling one. Both projects come from
    /// `ProjectFactory.createNovelProject` with nothing in the way, so the answer
    /// is the same in each.
    private func conventionalPath(
        of kind: Statement.Kind, named name: String
    ) async throws -> String {
        let sibling = try await fixture(named: name)
        return try await sibling.store.createStatement(kind: kind, scope: .project).path
    }

    /// Put a regular FILE where the statement's assets directory must go, so the
    /// saver's own `createDirectory` throws — a disk that says no *after* the
    /// mint, which is the whole failure ordering S6 is about. Returns the plant,
    /// so a test can remove it and prove the same call then lands.
    private func plantAFileWhereTheWellMustGo(
        forStatementAt path: String, in projectURL: URL
    ) throws -> URL {
        let plant = well(besideStatementAt: path, in: projectURL)
        try FileManager.default.createDirectory(
            at: plant.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a file, where a directory has to be".utf8).write(to: plant)
        return plant
    }

    private func pngBytes(_ side: Int = 8) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
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

        let window = await fixture.host(kind: .visualLanguage, subject: nil)
        let textView = try fixture.textView(in: window)

        // Control: nothing is in the well and nothing is in the op log, so the
        // assertions below cannot pass on something that was already there.
        XCTAssertTrue(files(in: assets).isEmpty)
        XCTAssertTrue(fixture.ops(forDocId: statement.id).isEmpty)

        try putImageOnTheClipboard()
        textView.paste(nil)
        await fixture.pumpUntil(deadline: 5) { !self.files(in: assets).isEmpty }
        try await fixture.settle(window, expectingOpsFor: statement.id, until: {
            fixture.derivedText(forDocId: statement.id)
                .contains("![](./\(assets.lastPathComponent)/")
        })

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

    /// **⌘V into a statement that already exists inserts at the caret, and the
    /// writer sees it.**
    ///
    /// **What this drives, exactly** — because the first version of this comment
    /// claimed otherwise, and the same setup error had already made a sibling
    /// test pass against a live defect. The statement is created up front, so
    /// `makeImagePasteHandler`'s **synchronous** branch runs:
    /// `store.statement` is non-nil → `addImage(to:image:)` → the ref is returned
    /// to `MaughamTextView.paste(_:)` → `insertText` at the caret → the binding →
    /// the `Document`. **`take` and `appendToStatement` are not reached at all.**
    ///
    /// So this is the caret-insertion path's test and nothing more. It is still
    /// worth having: it is the only one that reads the text view SwiftUI's own
    /// mounting produced, and "the words are on disk but the writer is looking at
    /// an empty pane" is exactly what a green op-log test hides.
    ///
    /// **The gap it leaves, named rather than implied:** `take`'s live arm — an
    /// append into a `Document` a pane already has open — has no test from this
    /// host. It is reachable only through the drop well on a bound pane, and
    /// SwiftUI drop delivery has no seam XCTest can post a drag session into
    /// (`CanvasDrop`'s own comment says the same about the canvas). The mechanism
    /// is not unmeasured — `PromotionPerformer` exercises the same arm and
    /// `test_promotingWhileTheIntentPaneIsOpenDoesNotOpenASecondDocument` holds
    /// its outcome — but this file's claim on it rests on that, not on this test.
    func test_pastingIntoAStatementThatExistsInsertsAtTheCaret() async throws {
        let fixture = try await fixture(named: "VisualLanguageVisible")
        let statement = try await fixture.store.createStatement(
            kind: .visualLanguage, scope: .project)
        let assets = well(beside: statement, in: fixture.projectURL)

        let window = await fixture.host(kind: .visualLanguage, subject: nil)
        let textView = try fixture.textView(in: window)
        XCTAssertEqual(textView.string, "", "control: the editor starts empty")

        try putImageOnTheClipboard()
        textView.paste(nil)
        await fixture.pumpUntil(deadline: 5) { textView.string.contains("![](") }

        XCTAssertTrue(
            textView.string.contains("![](./\(assets.lastPathComponent)/"),
            "the writer is looking at an editor that does not show the picture "
            + "they just pasted. The mounted text view says: \"\(textView.string)\"")
        try await fixture.settle(window, expectingOpsFor: statement.id)
    }

    /// **No attachment character reaches the writer's op log** (review round 3).
    ///
    /// Found by probing what the mounted editor actually held, not by a failing
    /// test: pasting into a visual language that had no file yet produced
    /// `![](./visual-language_assets/…png)\n\n￼` — the ref from the handler's own
    /// asynchronous path, and a `U+FFFC` from `super.paste`. `MaughamTextView`
    /// advertises image types in `readablePasteboardTypes` whenever a handler is
    /// set, so when the handler returned nil `super` accepted the image and
    /// inserted an attachment. A junk character in the writer's mood board, in
    /// the op log, on the first picture they ever put there.
    ///
    /// Asserted on the OP LOG rather than the buffer, because that is where it
    /// was durable — and against the whole derived text rather than
    /// `contains("￼")` alone, so a second stray paragraph of any kind fails too.
    func test_pastingAPictureLeavesNoAttachmentCharacterBehind() async throws {
        let fixture = try await fixture(named: "VisualLanguageNoJunk")
        // **No statement up front, and that is the whole test.** With one, the
        // handler answers synchronously and `super.paste` never runs — which is
        // exactly how the first draft of this test passed against the defect.
        XCTAssertNil(fixture.store.statement(kind: .visualLanguage, scope: .project))

        let window = await fixture.host(kind: .visualLanguage, subject: nil)
        let textView = try fixture.textView(in: window)
        try putImageOnTheClipboard()
        textView.paste(nil)
        await fixture.pumpUntil(deadline: 5) {
            fixture.store.statement(kind: .visualLanguage, scope: .project) != nil
        }
        let statement = try XCTUnwrap(
            fixture.store.statement(kind: .visualLanguage, scope: .project))
        let assets = well(beside: statement, in: fixture.projectURL)
        await fixture.pumpUntil(deadline: 5) { !self.files(in: assets).isEmpty }

        // Read BEFORE `settle`, which takes the content view down.
        XCTAssertFalse(textView.string.contains("\u{FFFC}"),
                       "no attachment character in the buffer: "
                       + textView.string.debugDescription)

        // **And the writer's next keystroke MERGES with the picture rather than
        // replacing it.** This pane is still unbound — `reconcile` established
        // there was no statement and nothing re-runs it — so the editor is empty
        // over a document that now has content, and the keystroke goes through
        // `draft` → `mintAndBind` → `bind(carryingDraft: true)`, which appends.
        // A version of this that bound the pane to close the visibility gap made
        // the same keystroke `setFullText("a")` and took the ref with it; it was
        // measured, and removed. See `take`.
        await fixture.type("a", into: textView)
        try await fixture.settle(window, expectingOpsFor: statement.id, until: {
            guard let filename = self.files(in: assets).first else { return false }
            return fixture.derivedText(forDocId: statement.id)
                == "![](./\(assets.lastPathComponent)/\(filename))\n\na"
        })

        let filename = try XCTUnwrap(files(in: assets).first)
        let ref = "![](./\(assets.lastPathComponent)/\(filename))"
        XCTAssertEqual(fixture.derivedText(forDocId: statement.id), "\(ref)\n\na",
                       "the statement must hold the ref, then the writer's "
                       + "character, and nothing else")
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

        let window = await fixture.host(kind: .visualLanguage, subject: nil)
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
        try await fixture.settle(window, expectingOpsFor: statement.id, until: {
            fixture.derivedText(forDocId: statement.id)
                .contains("![](./\(assets.lastPathComponent)/")
        })

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

        let window = await fixture.host(kind: .intent, subject: nil)
        let textView = try fixture.textView(in: window)

        try putImageOnTheClipboard()
        textView.paste(nil)
        // fixed window: asserting nothing happens. Both assertions below prove an
        // ABSENCE — no file in the well, no ref in the log — and an absence is
        // only worth the wall clock given to it. Not to be shortened, and `settle`
        // keeps its fixed window for the same reason (no `until:` here).
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
    /// **This carries no correctness any more, deliberately** (review round 2).
    /// It was written to close a window in which a ref could be lost, which made
    /// it a guard that had to be right about the pane's lifecycle — and it was
    /// not. `take` names its destination outright now, so a drop that starts or
    /// finishes at any moment reaches the right statement whatever this says.
    /// What is left is that a drop target under a "Loading…" placeholder is
    /// nonsense to look at, which is worth one cheap assertion and no more.
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

    // MARK: - Where a finished ingest's ref goes (review I1)

    /// **An ingest outlives the surface that started it, and its ref still lands
    /// in the right statement** (review rounds 1 and 2).
    ///
    /// There is no routing decision left to assert, and that is the fix: round 1
    /// chose between the pane and the statement using `resolvedScope`, which
    /// describes the resolved SCOPE rather than whether the host is mounted — and
    /// `⌘⌥N` is not a scope change on this host at all, because
    /// `DetailPaneToggle.segmentContent` gives the two kinds separate `case` arms
    /// and the visual-language host is torn down. `.onDisappear` leaves
    /// `resolvedScope` naming the scope it just left, so the guard could not see
    /// the case it was written for.
    ///
    /// `take` names its destination outright now and reads no view state after
    /// suspending, so the class is unreachable rather than guarded. What is left
    /// to assert is the property underneath: the destination comes from the
    /// INGEST, and the ref reaches that statement's own op log.
    func test_thePictureNamesItsOwnStatementSoTheDestinationCannotGoStale() async throws {
        let fixture = try await fixture(named: "VisualLanguageDestination")
        let png = fixture.projectURL.appendingPathComponent("named.png")
        try pngBytes().write(to: png)

        let landed = try await fixture.store.addImage(
            toStatement: .visualLanguage, scope: .project, fileURL: png)

        XCTAssertEqual(
            landed.statement.id,
            try XCTUnwrap(fixture.store.statement(kind: .visualLanguage, scope: .project)).id,
            "the ingest returns the statement it saved the picture beside — a "
            + "caller holding only the ref would have to ask the pane, and every "
            + "answer available there is a proxy that can be stale")
        XCTAssertTrue(
            landed.ref.contains(
                "\(well(beside: landed.statement, in: fixture.projectURL).lastPathComponent)/"),
            "and the ref is relative to THAT statement: \(landed.ref)")
    }

    /// **The by-id route is lossless**, driven for real against a statement that
    /// nobody has open — which is what the pane's `target` amounts to once it has
    /// moved to another scope.
    ///
    /// Dropping the ref would have been the easy fix and it is not good enough:
    /// the picture is already in the well, so a dropped ref is an orphan file the
    /// writer can neither see nor clean up.
    func test_theByIdRouteReachesTheStatementsOwnOpLogWithNobodyHoldingIt() async throws {
        let fixture = try await fixture(named: "VisualLanguageById")
        let png = fixture.projectURL.appendingPathComponent("by-id.png")
        try pngBytes().write(to: png)

        let landed = try await fixture.store.addImage(
            toStatement: .visualLanguage, scope: .project, fileURL: png)
        XCTAssertNil(
            fixture.store.openStatementDocument(id: landed.statement.id),
            "precondition: no pane has this statement open, so the append must "
            + "take the transient arm under the open gate")

        try await fixture.store.appendToStatement(
            landed.ref, to: landed.statement, session: "test-\(UUID().uuidString)")
        await fixture.pumpUntil(deadline: 5) {
            fixture.derivedText(forDocId: landed.statement.id) == landed.ref
        }

        XCTAssertEqual(fixture.derivedText(forDocId: landed.statement.id), landed.ref,
                       "the ref reached the statement's OWN op log")
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
        try pngBytes().write(to: png)
        let landed = try await fixture.store.addImage(
            toStatement: .visualLanguage, scope: .project, fileURL: png)
        XCTAssertEqual(
            landed.statement.id,
            try XCTUnwrap(fixture.store.statement(kind: .visualLanguage, scope: .project)).id,
            "the picture names the statement it was saved beside, so an ingest "
            + "that finishes on another scope still knows where its ref belongs")
        let assets = well(beside: landed.statement, in: fixture.projectURL)
        XCTAssertTrue(landed.ref.contains("\(assets.lastPathComponent)/"),
                      "control: a real picture lands in the derived well; got \(landed.ref)")
    }

    /// S6 (issue #29): the NSImage arm minted the statement BEFORE the save
    /// could fail. An unencodable bitmap must refuse with nothing behind —
    /// not even the empty statement it would have gone into.
    ///
    /// The twin of `test_aTextFileIsRefusedOnItsWayIntoVisualLanguage` for the
    /// other arm: the fileURL arm asks `isIngestableImage` before it mints, and
    /// this one now re-encodes before it mints, so both refuse the writer's own
    /// bad input at the same point.
    func test_anUnencodableImageLeavesNoStatementBehind() async throws {
        let fixture = try await fixture(named: "VisualLanguageUnencodable")
        XCTAssertNil(fixture.store.statement(kind: .visualLanguage, scope: .project),
                     "precondition: nothing here yet, so what the assertion below "
                     + "reads can only have come from this call")

        do {
            _ = try await fixture.store.addImage(
                toStatement: .visualLanguage, scope: .project, image: NSImage())
            XCTFail("a zero-size NSImage has no bitmap to encode")
        } catch let error as ImagePasteHandler.ImagePasteError {
            guard case .encodingFailed = error else {
                return XCTFail("expected .encodingFailed, got \(error)")
            }
        }

        XCTAssertNil(fixture.store.statement(kind: .visualLanguage, scope: .project),
                     "a refused picture leaves nothing behind — not even the statement")

        // Control: the same call with a real picture through the same arm mints
        // one, so the assertion above is about the refusal and not about an arm
        // that mints nothing at all.
        let landed = try await fixture.store.addImage(
            toStatement: .visualLanguage, scope: .project, image: try makeImage())
        XCTAssertEqual(
            landed.statement.id,
            try XCTUnwrap(fixture.store.statement(kind: .visualLanguage, scope: .project)).id)
    }

    /// **The disk-failure case, both arms.** A regular FILE planted where the
    /// assets DIRECTORY must go makes the saver's `createDirectory` throw — the
    /// one failure neither arm can validate its way out of, because it happens
    /// after the mint. The rollback is what makes "a refused picture leaves
    /// nothing behind" true of the disk's refusals too.
    ///
    /// Healed at the end: with the plant removed the same call lands, so the two
    /// refusals above are the planted disk and not an ingest that refuses
    /// everything.
    func test_aDiskFailureAfterTheMintRollsTheStatementBack() async throws {
        let fixture = try await fixture(named: "VisualLanguageDiskFailure")
        let path = try await conventionalPath(
            of: .visualLanguage, named: "VisualLanguageDiskFailureProbe")
        let plant = try plantAFileWhereTheWellMustGo(
            forStatementAt: path, in: fixture.projectURL)
        let statementFile = fixture.projectURL.appendingPathComponent(path)

        let png = fixture.projectURL.appendingPathComponent("real.png")
        try pngBytes().write(to: png)

        // The fileURL arm: `isIngestableImage` passes, the mint lands, and the
        // copy's own directory creation is what throws.
        do {
            _ = try await fixture.store.addImage(
                toStatement: .visualLanguage, scope: .project, fileURL: png)
            XCTFail("no well can be created where a regular file already is")
        } catch {}
        XCTAssertNil(fixture.store.statement(kind: .visualLanguage, scope: .project),
                     "the mint this call made must not outlive the save that failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: statementFile.path),
                       "and the empty file went with the manifest row — a row-less "
                       + "file is inert, but here neither should be left")

        // The NSImage arm on the same planted disk: the encode succeeds, so the
        // mint happens and the write is what fails.
        do {
            _ = try await fixture.store.addImage(
                toStatement: .visualLanguage, scope: .project, image: try makeImage())
            XCTFail("no well can be created where a regular file already is")
        } catch {}
        XCTAssertNil(fixture.store.statement(kind: .visualLanguage, scope: .project),
                     "both arms roll their own mint back, not just the file one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: statementFile.path))

        // Heal.
        try FileManager.default.removeItem(at: plant)
        let landed = try await fixture.store.addImage(
            toStatement: .visualLanguage, scope: .project, fileURL: png)
        XCTAssertEqual(
            landed.statement.id,
            try XCTUnwrap(fixture.store.statement(kind: .visualLanguage, scope: .project)).id,
            "with the disk healed the same call lands, so the refusals above were "
            + "the plant and not an ingest that refuses everything")
        XCTAssertEqual(files(in: well(beside: landed.statement, in: fixture.projectURL)).count, 1)
    }

    /// **And the guard that makes rollback safe under find-or-create:** a save
    /// failure on a SECOND picture must NOT delete the writer's existing
    /// statement — this call did not mint it.
    ///
    /// Nothing else distinguishes the two cases at the point of failure: the
    /// statement's file is empty and its op log has no words either way (the ref
    /// goes in through the caller's own append), so `rollbackUnusedStatement`
    /// would happily remove a declaration the writer made yesterday. Only the
    /// question asked BEFORE `createStatement` can tell them apart.
    func test_aSaveFailureOnASecondPictureKeepsTheExistingStatement() async throws {
        let fixture = try await fixture(named: "VisualLanguageSecondPicture")
        let png = fixture.projectURL.appendingPathComponent("real.png")
        try pngBytes().write(to: png)

        let first = try await fixture.store.addImage(
            toStatement: .visualLanguage, scope: .project, fileURL: png)
        let assets = well(beside: first.statement, in: fixture.projectURL)
        XCTAssertEqual(files(in: assets).count, 1, "control: the first picture landed")

        // Break the well under the statement the writer now has.
        try FileManager.default.removeItem(at: assets)
        _ = try plantAFileWhereTheWellMustGo(
            forStatementAt: first.statement.path, in: fixture.projectURL)

        for arm in ["fileURL", "NSImage"] {
            do {
                _ = arm == "fileURL"
                    ? try await fixture.store.addImage(
                        toStatement: .visualLanguage, scope: .project, fileURL: png)
                    : try await fixture.store.addImage(
                        toStatement: .visualLanguage, scope: .project, image: try makeImage())
                XCTFail("the \(arm) arm should have failed on the planted well")
            } catch {}

            let still = try XCTUnwrap(
                fixture.store.statement(kind: .visualLanguage, scope: .project),
                "the \(arm) arm FOUND the writer's statement rather than minting "
                + "it, and a save failure must never delete a declaration it did "
                + "not make")
            XCTAssertEqual(still.id, first.statement.id)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: fixture.projectURL.appendingPathComponent(still.path).path),
                "and its file is still there")
        }
    }
}
