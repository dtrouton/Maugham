// MaughamTests/OpLog/RestoreTests.swift
import XCTest
@testable import Maugham

final class RestoreTests: XCTestCase {
    func test_buildRestoreOp_singleParagraphScope_emitsOnlyThatParagraph() {
        let currentState = Deriver.DerivedState(
            paragraphs: ["a": "current-a", "b": "current-b"],
            sequence: ["a", "b"])
        let targetState = Deriver.DerivedState(
            paragraphs: ["a": "old-a", "b": "old-b"],
            sequence: ["a", "b"])
        let op = Restore.buildRestoreOp(
            current: currentState, target: targetState,
            scope: .paragraph("a"),
            docId: "doc-1", device: "m", session: "s",
            sourceCheckpoint: "cp-1")
        XCTAssertEqual(op!.kind, .checkpointRestore)
        XCTAssertEqual(op!.changes.count, 1)
        XCTAssertEqual(op!.changes[0].paragraphId, "a")
        XCTAssertEqual(op!.changes[0].next, "old-a")
        XCTAssertEqual(op!.provenance?.sourceCheckpoint, "cp-1")
    }

    func test_buildRestoreOp_documentScope_emitsAllChangedParagraphs() {
        let currentState = Deriver.DerivedState(
            paragraphs: ["a": "current-a", "b": "current-b", "c": "same"],
            sequence: ["a", "b", "c"])
        let targetState = Deriver.DerivedState(
            paragraphs: ["a": "old-a", "b": "old-b", "c": "same"],
            sequence: ["a", "b", "c"])
        let op = Restore.buildRestoreOp(
            current: currentState, target: targetState,
            scope: .document,
            docId: "doc-1", device: "m", session: "s",
            sourceCheckpoint: "cp-1")
        XCTAssertEqual(op!.changes.count, 2)
        XCTAssertEqual(Set(op!.changes.map(\.paragraphId)), ["a", "b"])
    }

    func test_buildRestoreOp_noChanges_returnsNil() {
        let same = Deriver.DerivedState(
            paragraphs: ["a": "x"], sequence: ["a"])
        XCTAssertNil(Restore.buildRestoreOp(
            current: same, target: same, scope: .document,
            docId: "doc-1", device: "m", session: "s",
            sourceCheckpoint: "cp-1"))
    }
}
