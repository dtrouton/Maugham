// MaughamTests/CompilerNoteTests.swift
import XCTest
@testable import Maugham

/// `CompilerNote` turns an accepted diagnostic into the note the writer reads.
/// This suite covers the reader section's kind → label mapping, which is the
/// half of `DiagnosticIngest.readerKinds` that produces words: the label
/// travels in the note's body, because no pane draws it above the row any more
/// (M4 P1).
final class CompilerNoteTests: XCTestCase {

    /// **Four kinds, four labels** (two loops P2 Task 3, spec §4.3). The
    /// vocabulary widened when the first reader arrived — `drag` and `lost`
    /// are hers — and a kind the parser accepts but this mapping cannot name
    /// would reach the writer as a report with its label silently missing.
    func test_everyReaderKindTheParserAcceptsHasALabel() {
        XCTAssertEqual(
            DiagnosticIngest.readerKinds.map { CompilerNote.readerKindLabel($0) },
            ["Dream break", "Belief", "Drag", "Lost"],
            "the parser's vocabulary and the labels are two readers of one "
            + "list; a kind with no label reaches the writer unlabelled")
    }

    /// The control for the pairing above: a kind from outside the vocabulary
    /// gets no label rather than a guess. v2 mints no free-form category (spec
    /// §5), so a value from anywhere but the schema has nothing to be called.
    func test_aKindOutsideTheVocabularyHasNoLabel() {
        XCTAssertNil(CompilerNote.readerKindLabel("boredom"))
        XCTAssertNil(CompilerNote.readerKindLabel(nil))
        XCTAssertNil(CompilerNote.readerKindLabel(""))
    }
}
