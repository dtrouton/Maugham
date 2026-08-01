import XCTest
@testable import Maugham

/// The typed window subject and the one boundary that turns it back into a
/// bare document id.
final class BinderSubjectTests: XCTestCase {

    // MARK: - The two one-way accessors

    func test_itemID_isNilForTheProject_andTheIdForAnItem() {
        XCTAssertNil(BinderSubject.project.itemID,
                     "the project names no structure item — a caller must handle that")
        XCTAssertEqual(BinderSubject.item("doc-1").itemID, "doc-1")
    }

    /// The `activeDocId` the per-document panes take. Three spellings of this
    /// rule shipped three hops apart before the type; this is the only one.
    func test_activeDocId_substitutesTheSentinelForEverythingThatIsNotAnItem() {
        XCTAssertEqual(BinderSubject.activeDocId(for: .item("doc-1")), "doc-1")
        XCTAssertEqual(BinderSubject.activeDocId(for: .project),
                       BinderSubject.noDocumentSubject)
        XCTAssertEqual(BinderSubject.activeDocId(for: nil),
                       BinderSubject.noDocumentSubject)
    }

    /// The sentinel has one home. The panes that compare against it read it
    /// from here rather than each carrying the literal — the shape that let
    /// `DetailPaneToggle` re-substitute a value already substituted upstream.
    func test_theSentinelIsTheValueTheExistingPanesAlreadyCompareAgainst() {
        XCTAssertEqual(BinderSubject.noDocumentSubject, "__no-selection__")
        XCTAssertEqual(StatementPane.noSelectionSentinel,
                       BinderSubject.noDocumentSubject)
    }

    // MARK: - The codec, on real files

    /// **A `ui-state.json` on disk holds a bare id.** Every project opened by
    /// every shipped build has one, so a decode that cannot read a plain string
    /// silently resets the writer's selection on upgrade.
    func test_anOldFileHoldingABarePlainStringStillDecodes() throws {
        let json = Data("""
        {"schemaVersion":5,"selectedItemId":"doc-1","isNoChromeOn":false,
         "binderSegment":"manuscript","researchPreviewVisible":false,
         "detailSegment":"inspector","outlineLayout":"table",
         "isReviewModeOn":false,"persona":"author"}
        """.utf8)
        let decoded = try JSONDecoder().decode(UIState.self, from: json)
        XCTAssertEqual(decoded.selectedSubject, .item("doc-1"))
    }

    /// The pre-persona shape too — the oldest file we still claim to read.
    func test_aV1FileHoldingABarePlainStringStillDecodes() throws {
        let json = Data(#"{"schemaVersion":1,"selectedItemId":"doc-9"}"#.utf8)
        let decoded = try JSONDecoder().decode(UIState.self, from: json)
        XCTAssertEqual(decoded.selectedSubject, .item("doc-9"))
    }

    func test_aFileWithNoSelectionAtAllDecodesToNil() throws {
        let json = Data(#"{"schemaVersion":5}"#.utf8)
        let decoded = try JSONDecoder().decode(UIState.self, from: json)
        XCTAssertNil(decoded.selectedSubject)
    }

    func test_everySubjectRoundTrips() throws {
        for subject in [BinderSubject.project, .item("doc-1"), nil] as [BinderSubject?] {
            var state = UIState.empty
            state.selectedSubject = subject
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(UIState.self, from: data)
            XCTAssertEqual(decoded.selectedSubject, subject,
                           "\(String(describing: subject)) did not survive the codec")
        }
    }

    /// **What an older build sees.** The project subject is written under its
    /// own key and NOT under `selectedItemId`, so a build that has never heard
    /// of it reads no selection at all and falls to the first document — the
    /// same landing a deleted item already gets. Writing a reserved string into
    /// `selectedItemId` instead would have an old build restore a selection to
    /// an id that is in no structure.
    func test_theProjectSubjectIsNotWrittenIntoTheOldKey() throws {
        var state = UIState.empty
        state.selectedSubject = .project
        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertNil(object?["selectedItemId"],
                     "an older build would restore a selection that is in no structure")

        // And the converse: an item subject keeps using the old key, so an
        // older build restores it exactly as it always did.
        state.selectedSubject = .item("doc-1")
        let itemObject = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertEqual(itemObject?["selectedItemId"] as? String, "doc-1")
    }

    /// No schema bump: the representation is additive on one new key, and both
    /// directions of the version skew read cleanly.
    func test_theNewCaseDidNotCostASchemaBump() {
        XCTAssertEqual(UIState.currentSchemaVersion, 5)
    }

    /// **What the hand-written encoder makes newly possible, guarded.**
    ///
    /// `UIState`'s `encode(to:)` used to be synthesized, so a field added to the
    /// struct persisted itself. It is hand-written now — the subject is not
    /// stored the way it is spelled — and a field added without a line in that
    /// method would silently stop being saved, with `Codable` conformance intact
    /// and every existing round-trip test still green because each pins one
    /// field.
    ///
    /// This one sets **every** field away from its default and asserts whole-
    /// struct equality, so the omission is what fails rather than the feature
    /// that later depends on it.
    func test_everyFieldSurvivesTheHandWrittenEncoder() throws {
        var original = UIState(
            schemaVersion: UIState.currentSchemaVersion,
            selectedSubject: .item("doc-1"),
            isNoChromeOn: true,
            binderSegment: .research,
            researchPreviewVisible: true,
            detailSegment: .history,
            outlineLayout: .cards,
            isReviewModeOn: true,
            persona: .plan)
        original.personaMemory.record(persona: .review,
                                      binderSegment: .palette,
                                      detailSegment: .annotations)

        let decoded = try JSONDecoder().decode(
            UIState.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original,
                       "a field is missing from UIState.encode(to:)")
    }
}
