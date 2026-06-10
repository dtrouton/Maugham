import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// The load-bearing pin for the windowed-typography perf fix
/// (`perf(editor): windowed typography application`).
///
/// For each (document, edit) case we assert that the INCREMENTAL path — apply
/// the edit to an already-styled storage so attributes shift the way they do in
/// production, then run the windowed restyle with old→new tokens — produces an
/// ATTRIBUTE-IDENTICAL storage to the WHOLE-DOC path (style the post-edit text
/// from scratch).
///
/// If this test fails, the window is dropping or mis-applying an attribute the
/// whole-doc path produces; investigate the window math / mode gating, do NOT
/// weaken the assertion. See `TokenRestyleWindow`, `ScreenplayMode`/`ProseMode`
/// `applyTypography`, and the Editor AREA guide.
final class WindowedTypographyEquivalenceTests: XCTestCase {

    private let theme: Theme = .light

    // MARK: - Screenplay realistic document

    /// A ~30+ element screenplay with a title page, scene headings, action,
    /// character cues, parentheticals, dialogue, a transition, a section, a
    /// synopsis, an inline `[[todo:]]` task, and inline emphasis — so the diff
    /// exercises every styling pass.
    private let screenplayDoc = """
    Title: The Long Afternoon
    Author: A. Writer

    FADE IN:

    INT. KITCHEN - DAY

    Larry stands at the counter, *staring* at a cold cup of coffee.

    LARRY
    (muttering)
    Not again.

    He pours the coffee down the drain.

    BARRY
    You always do that.

    LARRY
    Do what?

    EXT. STREET - NIGHT

    The rain comes down in sheets. [[todo: describe the neon]]

    # Act Two

    = Larry confronts the truth about the afternoon.

    DETECTIVE MORALES
    Where were you at noon?

    LARRY
    Home. Drinking bad coffee.

    CUT TO:

    INT. PRECINCT - LATER

    Morales paces behind the glass.

    MORALES
    (to himself)
    He's lying.
    """

    private let proseDoc = """
    # The Long Afternoon

    Larry stood at the counter, *staring* at a cold cup of coffee. The
    morning had not gone the way he planned, and the **kitchen** felt
    smaller than it had the day before.

    ## Chapter One

    He thought about the meeting. About what [[Barry Sullivan]] had said,
    and how the words had landed like a slap he hadn't seen coming.

    - [ ] call the detective back
    - [x] throw out the coffee

    > Some quotes are worth remembering. This is not one of them.

    The `terminal` blinked on the desk. He had work to do, and a
    [[deadline]] that would not move for anyone.

    ## Chapter Two

    By the time the rain started, Larry had decided. He would tell
    Morales everything, and let the afternoon fall where it might.
    """

    /// Dual-dialogue fixture: LARRY speaks, then BARRY's cue carries the
    /// trailing `^` making his block the dual-second column — his
    /// parenthetical and dialogue lines INHERIT `isDualSecond` from the cue
    /// without their own text encoding it (FountainTokenizer). Used by the
    /// dual-caret regression cases below.
    private let dualDialogueDoc = """
    INT. BAR - NIGHT

    Larry and Barry argue across the counter, neither one listening.

    LARRY
    I can't believe you did that. After everything we talked about.

    BARRY ^
    (overlapping)
    You never believe anything. That's your whole problem, Larry.

    The bartender slides a glass between them.

    MORALES
    Gentlemen. Take it outside.

    They don't take it outside.
    """

    // MARK: - Dual-dialogue regression (review HIGH: inherited isDualSecond)

    /// Deleting the trailing ` ^` from a dual-second cue must de-dual the
    /// FOLLOWING parenthetical + dialogue lines too — their `isDualSecond` is
    /// inherited from the cue, not encoded in their own text, so without
    /// `isDualSecond` in token identity they matched (kind, length) and kept
    /// stale dual-column indents. (The originally-shipped windowing failed
    /// exactly here.)
    func test_screenplay_removeDualCaret_deDualsInheritedFollowers() {
        let edit = Edit(replace: "BARRY ^", with: "BARRY")
        assertEquivalent(doc: dualDialogueDoc, edit: edit, mode: .screenplay)
    }

    /// The symmetric direction: adding ` ^` to a solo cue must dual-ify the
    /// followers.
    func test_screenplay_addDualCaret_dualsInheritedFollowers() {
        let edit = Edit(replace: "MORALES", with: "MORALES ^")
        assertEquivalent(doc: dualDialogueDoc, edit: edit, mode: .screenplay)
    }

    /// The deeper hole that drove the token-identity fix (option 2 over a
    /// window-extension heuristic): a SAME-LENGTH overtype of the `^`
    /// (`BARRY ^` → `BARRY X`) changes `isDualSecond` for the cue and its
    /// followers without changing ANY token's length — only identity-aware
    /// tokens let the diff see it at all.
    func test_screenplay_sameLengthCaretOvertype_deDuals() {
        let edit = Edit(replace: "BARRY ^", with: "BARRY X")
        assertEquivalent(doc: dualDialogueDoc, edit: edit, mode: .screenplay)
    }

    /// Non-vacuity guard for the dual-caret pins: the removeDualCaret edit
    /// must produce a PROPER SUB-WINDOW (covering the cue + inherited
    /// followers) — not a full-document fallback, which would make the
    /// equivalence assertions above prove nothing about the windowed path.
    func test_removeDualCaret_producesProperSubWindow() {
        let oldTokens = tokenize(dualDialogueDoc, mode: .screenplay)
        let ns = dualDialogueDoc as NSString
        let r = ns.range(of: "BARRY ^")
        let newText = ns.replacingCharacters(in: r, with: "BARRY")
        let newTokens = tokenize(newText, mode: .screenplay)
        let decision = TokenRestyleWindow.decide(
            oldTokens: oldTokens, newTokens: newTokens,
            storageLength: (newText as NSString).length)
        guard case .window(let w) = decision else {
            return XCTFail("expected a sub-window, got \(decision)")
        }
        let newNS = newText as NSString
        XCTAssertLessThan(w.length, newNS.length,
                          "window covered the whole document — not actually windowed")
        XCTAssertGreaterThan(w.location, 0,
                             "window started at 0 — head was not trimmed")
        XCTAssertLessThan(NSMaxRange(w), newNS.length,
                          "window ran to end of document — tail was not trimmed")
        // The window must reach THROUGH the inherited-dual followers: the cue,
        // the parenthetical, and the dialogue line must all be inside it.
        for needle in ["BARRY", "(overlapping)", "your whole problem"] {
            let hit = newNS.range(of: needle)
            XCTAssertNotEqual(hit.location, NSNotFound, "fixture drifted: \(needle)")
            XCTAssertTrue(
                NSIntersectionRange(hit, w).length == hit.length,
                "window \(w) does not fully cover follower text '\(needle)' at \(hit)")
        }
    }

    // MARK: - Screenplay edit cases

    func test_screenplay_editInsideAction() {
        let edit = Edit(replace: "cold cup", with: "cold mug")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    /// Guards the test's own load-bearing-ness: a one-character mid-document
    /// insertion (the realistic keystroke) must produce a PROPER SUB-WINDOW
    /// (not a full-document fallback), otherwise the equivalence assertions
    /// above prove nothing about the windowing path. (A same-length swap that
    /// changes no token's kind/length correctly yields `.noChange`; here we
    /// change a token length so a window must be produced.)
    func test_diffProducesProperSubWindow_notFullFallback() {
        let oldTokens = tokenize(screenplayDoc, mode: .screenplay)
        let ns = screenplayDoc as NSString
        let r = ns.range(of: "cold cup of coffee")
        let newText = ns.replacingCharacters(in: r, with: "cold cup of fresh coffee")
        let newTokens = tokenize(newText, mode: .screenplay)
        let decision = TokenRestyleWindow.decide(
            oldTokens: oldTokens, newTokens: newTokens,
            storageLength: (newText as NSString).length)
        guard case .window(let w) = decision else {
            return XCTFail("expected a sub-window, got \(decision)")
        }
        XCTAssertLessThan(w.length, (newText as NSString).length,
                          "window covered the whole document — not actually windowed")
        XCTAssertGreaterThan(w.location, 0,
                             "window started at 0 — head was not trimmed")
        // The unchanged tail (everything after this action paragraph) must be
        // excluded from the window.
        XCTAssertLessThan(NSMaxRange(w), (newText as NSString).length,
                          "window ran to end of document — tail was not trimmed")
    }

    func test_screenplay_editInsideDialogue() {
        let edit = Edit(replace: "Not again.", with: "Not this again.")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    /// Reclassifies elements: lowercasing a CHARACTER cue makes it action and
    /// turns the following line from dialogue into action too.
    func test_screenplay_reclassifyCharacterCue() {
        // Turn an action line into a CHARACTER cue by uppercasing it, so the
        // following line reclassifies from action into dialogue.
        let edit = Edit(
            replace: "He pours the coffee down the drain.",
            with: "JANITOR")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_paragraphSplit() {
        // Insert a blank line inside the action, splitting one paragraph in two.
        let edit = Edit(
            replace: "comes down in sheets.",
            with: "comes down\n\nin sheets.")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_paragraphJoin() {
        // Delete a blank line, joining the section header onto the synopsis.
        let edit = Edit(
            replace: "# Act Two\n\n= Larry",
            with: "# Act Two\n= Larry")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_multiCharPasteMidDocument() {
        let edit = Edit(
            replace: "The rain comes down",
            with: "The rain comes down hard and fast and loud")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_editAtDocumentStart() {
        let edit = Edit(replace: "Title: The Long Afternoon",
                        with: "Title: The Very Long Afternoon")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_editAtDocumentEnd() {
        let edit = Edit(replace: "He's lying.", with: "He's clearly lying.")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_emojiInsertion() {
        // Emoji spans two UTF-16 code units; the window math is UTF-16-based.
        let edit = Edit(replace: "Do what?", with: "Do what? 🤔")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    // MARK: - Prose edit cases

    func test_prose_editInsideParagraph() {
        let edit = Edit(replace: "cold cup of coffee", with: "cold mug of coffee")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    func test_prose_paragraphSplit() {
        let edit = Edit(replace: "the day before.",
                        with: "the day before.\n\nA new paragraph appears.")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    func test_prose_multiCharPasteMidDocument() {
        let edit = Edit(replace: "He had work to do",
                        with: "He had a great deal of important work to do")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    func test_prose_wikiLinkEdit() {
        let edit = Edit(replace: "[[Barry Sullivan]]",
                        with: "[[Barry T. Sullivan]]")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    func test_prose_emojiInsertion() {
        let edit = Edit(replace: "He would tell", with: "He would 🙂 tell")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    /// Editing before a markdown checkbox shifts the checkbox; its stamped
    /// `MaughamCheckboxMarker.bracketLocation` must stay current document-wide.
    func test_prose_editBeforeCheckbox_marker_staysCurrent() {
        let edit = Edit(replace: "had landed like a slap",
                        with: "had landed like a hard slap")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    // MARK: - Equivalence harness

    private enum ModeKind { case screenplay, prose }

    private struct Edit {
        let replace: String
        let with: String
    }

    /// The window decision must never claim "no change needed" then leave the
    /// storage diverging; the assertion below enforces that by construction. We
    /// run the SAME diff the coordinator runs.
    private func assertEquivalent(
        doc oldText: String,
        edit: Edit,
        mode: ModeKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ns = oldText as NSString
        let editRange = ns.range(of: edit.replace)
        XCTAssertNotEqual(editRange.location, NSNotFound,
                          "edit anchor '\(edit.replace)' not found", file: file, line: line)
        let newText = ns.replacingCharacters(in: editRange, with: edit.with)

        let oldTokens = tokenize(oldText, mode: mode)
        let newTokens = tokenize(newText, mode: mode)

        // ----- Storage A: old text fully styled, then edited, then windowed -----
        let storageA = NSTextStorage(string: oldText)
        applyWhole(storageA, text: oldText, mode: mode)
        // Apply the edit the way NSTextView does — attributes shift with chars.
        storageA.replaceCharacters(in: editRange, with: edit.with)
        XCTAssertEqual(storageA.length, (newText as NSString).length,
                       "edit produced wrong storage length", file: file, line: line)

        let decision = TokenRestyleWindow.decide(
            oldTokens: oldTokens,
            newTokens: newTokens,
            storageLength: storageA.length)
        let window: NSRange?
        switch decision {
        case .noChange:      window = NSRange(location: 0, length: 0)
        case .window(let r): window = r
        case .fullDocument:  window = nil
        }
        applyWindowed(storageA, tokens: newTokens, mode: mode, window: window)

        // ----- Storage B: new text styled whole-doc from scratch -----
        let storageB = NSTextStorage(string: newText)
        applyWhole(storageB, text: newText, mode: mode)

        assertStoragesEqual(storageA, storageB, file: file, line: line)
    }

    private func tokenize(_ text: String, mode: ModeKind) -> [Token] {
        switch mode {
        case .screenplay: return ScreenplayMode().tokenize(text)
        case .prose:      return ProseMode().tokenize(text)
        }
    }

    private func applyWhole(_ storage: NSTextStorage, text: String, mode: ModeKind) {
        switch mode {
        case .screenplay:
            let m = ScreenplayMode()
            m.applyTypography(
                in: storage, theme: theme, typography: .screenplayDefaults,
                tokens: m.tokenize(text), parsedScript: FountainTokenizer().parse(text))
        case .prose:
            let m = ProseMode()
            m.applyTypography(
                in: storage, theme: theme, typography: .defaults,
                tokens: m.tokenize(text), wikiLinkResolver: nil)
        }
    }

    private func applyWindowed(
        _ storage: NSTextStorage,
        tokens: [Token],
        mode: ModeKind,
        window: NSRange?
    ) {
        let text = storage.string
        switch mode {
        case .screenplay:
            let m = ScreenplayMode()
            m.applyTypography(
                in: storage, theme: theme, typography: .screenplayDefaults,
                tokens: tokens, parsedScript: FountainTokenizer().parse(text),
                restyleWindow: window)
        case .prose:
            let m = ProseMode()
            m.applyTypography(
                in: storage, theme: theme, typography: .defaults,
                tokens: tokens, wikiLinkResolver: nil, restyleWindow: window)
        }
    }

    /// Enumerate every attribute at every character index and assert exact
    /// equality of the dictionaries — font, foregroundColor, paragraphStyle,
    /// underline/strikethrough, the custom checkbox marker, and any other key
    /// present in either storage.
    private func assertStoragesEqual(
        _ a: NSTextStorage,
        _ b: NSTextStorage,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(a.length, b.length, "storage length diverged",
                       file: file, line: line)
        guard a.length == b.length else { return }
        for i in 0..<a.length {
            let attrsA = a.attributes(at: i, effectiveRange: nil)
            let attrsB = b.attributes(at: i, effectiveRange: nil)
            let keys = Set(attrsA.keys).union(attrsB.keys)
            for key in keys {
                XCTAssertTrue(
                    attributeValuesEqual(attrsA[key], attrsB[key], key: key),
                    "attribute \(key.rawValue) diverged at index \(i): "
                        + "windowed=\(String(describing: attrsA[key])) "
                        + "whole=\(String(describing: attrsB[key]))",
                    file: file, line: line)
            }
        }
    }

    private func attributeValuesEqual(
        _ x: Any?, _ y: Any?, key: NSAttributedString.Key
    ) -> Bool {
        switch (x, y) {
        case (nil, nil):
            return true
        case let (px?, py?):
            if let fx = px as? NSFont, let fy = py as? NSFont { return fx == fy }
            if let cx = px as? NSColor, let cy = py as? NSColor { return cx == cy }
            if let sx = px as? NSParagraphStyle, let sy = py as? NSParagraphStyle {
                return sx.isEqual(sy)
            }
            if let mx = px as? MaughamCheckboxMarker,
               let my = py as? MaughamCheckboxMarker {
                return mx.bracketLocation == my.bracketLocation
                    && mx.checked == my.checked
                    && mx.kind == my.kind
            }
            if let ox = px as? NSObject, let oy = py as? NSObject {
                return ox.isEqual(oy)
            }
            return false
        default:
            return false
        }
    }
}
