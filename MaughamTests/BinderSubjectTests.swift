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

    // MARK: - The sentinel has one home, asserted rather than promised

    /// **`BinderSubject`'s doc comment says the literal was written out at six
    /// production sites and now has one. That claim is prose until something
    /// scans for it.**
    ///
    /// The type itself is compiler-enforced in the direction that matters — no
    /// `rawValue`, no `init(String)`, so nothing gets a bare id without deciding
    /// what the project means to it. The literal is the part the compiler cannot
    /// see: a new site spelling `"__no-selection__"` inline behaves identically
    /// *today* and diverges silently the day the constant's value changes. Six
    /// prior sites is the recurrence that earns a census rather than a warning
    /// (`memory/feedback_census_over_warning.md`).
    ///
    /// **Its honest limit.** `SourceScan` cannot see past an unclosed `/*`, and
    /// two production files end their scan inside one — see
    /// `TripwireGrepTests.test_noScannedFileIsTruncatedByAnUnclosedBlockComment`,
    /// which pins that set. An offender in such a tail would be missed. What
    /// keeps this from being unfalsifiable is the *required* member: if
    /// `BinderSubject.swift` were ever truncated the census goes red, loudly.
    func test_theSentinelLiteralIsWrittenInExactlyOnePlace() throws {
        XCTAssertEqual(
            try Self.filesNamingTheSentinelLiteral(in: Self.appSourceDir),
            ["BinderSubject.swift"],
            "the sentinel is declared once and read as "
            + "`BinderSubject.noDocumentSubject` everywhere else. A site "
            + "spelling the literal is a second place to change and a second "
            + "place to look — which is the shape the type was introduced to "
            + "end, after six of them")
    }

    /// **The planted offender**, without which the census could be scanning an
    /// empty tree and reporting a set that happens to have been written down.
    func test_theSentinelCensusCatchesASecondLiteral() throws {
        XCTAssertEqual(
            try Self.filesNamingTheSentinelLiteral(
                Self.appSourceDir,
                plus: ["SomeNewPane.swift":
                        #"if activeDocId != "__no-selection__" { show() }"#]),
            ["BinderSubject.swift", "SomeNewPane.swift"],
            "the census must see a planted second literal")
    }

    /// **The control on the control.** Four production files quote the literal
    /// in doc comments explaining what it is; prose is not a site.
    func test_theSentinelCensusDoesNotCountAComment() throws {
        XCTAssertEqual(
            try Self.filesNamingTheSentinelLiteral(
                Self.appSourceDir,
                plus: ["CommentedOnly.swift":
                        #"/// the `"__no-selection__"` literal, refused here as an id."#]),
            ["BinderSubject.swift"],
            "a literal quoted in a doc comment must not count — four production "
            + "files already do exactly that")
    }

    // MARK: - Census helpers

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private static func filesNamingTheSentinelLiteral(in dir: URL) throws -> [String] {
        try filesNamingTheSentinelLiteral(dir)
    }

    /// `plus` injects synthetic (name, source) pairs through the identical
    /// predicate, so the two companions above test *this* scan.
    private static func filesNamingTheSentinelLiteral(
        _ dir: URL,
        plus injected: [String: String] = [:]
    ) throws -> [String] {
        var sources: [(name: String, text: String)] = []
        let fm = FileManager.default
        let walker = try XCTUnwrap(fm.enumerator(at: dir, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            sources.append((url.lastPathComponent,
                            try String(contentsOf: url, encoding: .utf8)))
        }
        sources.append(contentsOf: injected.map { ($0.key, $0.value) })

        return sources
            .filter { SourceScan.namesInCode(#""__no-selection__""#, in: $0.text) }
            .map(\.name)
            .sorted()
    }
}
