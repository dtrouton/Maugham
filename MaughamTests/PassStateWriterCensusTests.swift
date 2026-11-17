import XCTest
import MaughamCore
@testable import Maugham

/// **Who may write a piece's review state, and what may not write the legacy
/// status string.** Moved out of the retired persona pane registry suite
/// (shell p1 Task 6) whole: none of these censuses was about a persona — they
/// sat beside the registry because the Inspector's place in Review's picker
/// was argued from them.
final class PassStateWriterCensusTests: XCTestCase {
    // MARK: - Who writes a pass state

    /// The files allowed to write a piece's review state — `setPassState`'s
    /// production callers.
    ///
    /// **This census replaces `statusWritingFiles` and re-makes its argument on
    /// the control that replaced its control** (M3 P1 Task 4). The old one
    /// pinned the two files that wrote `StructureItem.status` through
    /// `updateInspector(… status:)`; that argument was `status:`-shaped, and
    /// `status:` no longer exists. Both members are the same two Inspector
    /// arms: `InspectorView` is what `ProjectWindow.existingInspectorSwitch`
    /// renders, and `PieceInspector` is the arm `inspectorRoute` takes instead
    /// on a Collection. They now host the pass LADDER, and the ladder is the
    /// only place in the app a writer can say where a piece stands on a pass.
    ///
    /// **The third member is the BOARD's host, and its name is a surprise worth
    /// reading** (M3 P1 Task 8). Task 7's carry expected `ReviewBoardPane.swift`
    /// here; what landed is `ProjectWindow.swift`, and the two facts that force
    /// it are both load-bearing:
    ///
    /// 1. The board takes **values and closures, never a store** — tripwire 4,
    ///    enforced on the pane's own file by
    ///    `ReviewBoardPaneTests.test_theSourceReadsNoStoreAtAll`, because the
    ///    pane's body runs once per row on a project that can hold hundreds and a
    ///    `ProjectStore` in that scope is an invitation to a disk read. So the
    ///    pane *cannot* be the caller without breaking the census that made it
    ///    cheap.
    /// 2. Which means the store call lands at the board's HOST — and that is the
    ///    same shape the other two members have, not an exception to it.
    ///    `PassLadder` does not write either; `InspectorView` and `PieceInspector`
    ///    do, because they host it (see `PassLadder`'s own doc comment on why the
    ///    write stays at the host). The census names hosts, and Review's board is
    ///    hosted by the window's centre column.
    ///
    /// **So the census is deliberately NOT what a reader would guess from the
    /// board's own directory**, and the self-check below asserts
    /// `ReviewBoardPane.swift`'s ABSENCE by name so that a future refactor
    /// handing the pane a store fails here as well as at the pane's own census.
    ///
    /// The window is keyed by TYPE (`type:ProjectWindow`, foundations plan 2):
    /// every file declaring `ProjectWindow` answers under that key, so a split
    /// of the window into extension files moves nothing here.
    ///
    /// **Since foundations plan 4 Task 4 the board's host is `CentreColumn`**,
    /// the window's centre column as a view of its own, keyed by its type for
    /// the same reason — the same host, moved, not a new writer.
    ///
    /// **Since Task 5 the queue's pass-order nudge is `RightColumn`'s**
    /// (`onSetPassState`, handed to `AnnotationsPane` through
    /// `DetailPaneToggle`), which the window hosted beside the board all along
    /// until its right column became a view of its own — again the same host,
    /// moved. `ProjectWindow` itself is no longer a member, but it stays a TYPE
    /// KEY in the census (`passStateWriters`), so a write that comes back into
    /// the window folds under `type:ProjectWindow` and fails the comparison.
    static let passStateWritingFiles: Set<String> = [
        "InspectorView.swift",
        "PieceInspector.swift",
        "type:CentreColumn",
        "type:RightColumn",
    ]

    /// Where `setPassState` is DECLARED. Excluded from the census because a
    /// declaration is not a writer — the store is the one channel every writer
    /// goes through, which is what makes the census meaningful at all. Named
    /// rather than pattern-matched so moving the declaration fails loudly here.
    static let passStateWriteDefiner = "ProjectStore+Metadata.swift"

    /// Every line of a production file under `Maugham/` that calls `needle`,
    /// as a (file name, line number) hit, ignoring comment-only lines.
    ///
    /// Comment-only lines are dropped first so a doc comment naming a call is
    /// never a hit — several of the comments in this very milestone name
    /// `setPassState` in prose. Per LINE, because `type:ProjectWindow` claims
    /// the window's declarations rather than the files holding them.
    private func callers(of needle: String, excluding excluded: String? = nil,
                         base: URL = SourceTree.repoRoot) throws -> [SourceTree.Hit] {
        let sourceDir = base.appendingPathComponent("Maugham", isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [SourceTree.Hit] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if let excluded, url.lastPathComponent == excluded { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains(needle) {
                found.append(SourceTree.Hit(file: url.lastPathComponent, line: index + 1))
            }
        }
        return found
    }

    /// The pass-state writers, each file a type key claims folded into that key
    /// (`SourceTree.keyedByType`, which throws when `type:ProjectWindow` names
    /// no file).
    private func passStateWriters(base: URL = SourceTree.repoRoot) throws -> Set<String> {
        try SourceTree.keyedByType(
            try callers(of: "setPassState(", excluding: Self.passStateWriteDefiner, base: base),
            typeKeys: Set(Self.passStateWritingFiles.filter { SourceTree.typeName(ofKey: $0) != nil })
                .union(["type:ProjectWindow"]),
            in: [base.appendingPathComponent("Maugham", isDirectory: true)])
    }

    /// **The planted control for the type key** (foundations plan 2): a write
    /// in an `extension ProjectWindow` file answers as `type:ProjectWindow`, one
    /// in `CentreColumn` as `type:CentreColumn`, and a write in any other file
    /// still answers under its own name.
    func test_thePassStateCensusFoldsTheWindowsFilesIntoItsTypeKey() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/ProjectWindow.swift": "struct ProjectWindow: View { }",
            "Maugham/Views/ProjectWindow+Board.swift": """
            extension ProjectWindow { func f() { store.setPassState(p, s) } }
            """,
            "Maugham/Views/CentreColumn.swift": """
            struct CentreColumn: View { func h() { store.setPassState(p, s) } }
            """,
            "Maugham/Views/RightColumn.swift": """
            struct RightColumn: View { func n() { store.setPassState(p, s) } }
            """,
            "Maugham/Views/SomeNewPane.swift": """
            struct SomeNewPane { func g() { store.setPassState(p, s) } }
            """,
        ])
        let writers = try passStateWriters(base: base)
        XCTAssertEqual(writers,
                       ["type:ProjectWindow", "type:CentreColumn", "type:RightColumn",
                        "SomeNewPane.swift"])
        XCTAssertFalse(writers.isSubset(of: Self.passStateWritingFiles),
                       "a write back in the window folds under its key and is "
                       + "not a member any more")
    }

    /// **…and only its DECLARATIONS** (plan 2 final review, I1): a write in a
    /// child view sharing a file with `extension ProjectWindow` answers under
    /// that FILE, which is not a member — the shape that let a planted
    /// `setPassState(` in `ResearchSubjectInspector` stay green.
    func test_thePassStateCensusCatchesAWriteInAChildViewSharingTheWindowsFile() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/ProjectWindow.swift": "struct ProjectWindow: View { }",
            "Maugham/Views/CentreColumn.swift": "struct CentreColumn: View { }",
            "Maugham/Views/RightColumn.swift": "struct RightColumn: View { }",
            "Maugham/Views/ResearchSubjectColumns.swift": """
            extension ProjectWindow {
                func f() { store.setPassState(p, s) }
            }

            struct ResearchSubjectInspector: View {
                func g() { store.setPassState(p, s) }
            }
            """,
        ])
        let writers = try passStateWriters(base: base)
        XCTAssertEqual(writers, ["type:ProjectWindow", "ResearchSubjectColumns.swift"])
        XCTAssertFalse(writers.isSubset(of: Self.passStateWritingFiles),
                       "the child view's write fails the census")
    }

    /// Every production file that still passes a `status:` argument to
    /// `updateInspector(`.
    ///
    /// **The argument list is read to its balanced close paren, not to the end
    /// of the line** — the inherited rule from the retired census, kept because
    /// it is the reason that one ever saw its primary writer: `InspectorView`
    /// spread its call over four lines with `status:` on the last, and a
    /// line-based matcher reported a one-member census while arguing from it.
    /// The expectation is now EMPTY, and this matcher is what makes an empty
    /// answer mean something.
    private func statusArgumentCensus() throws -> Set<String> {
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham", isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            found.formUnion(Self.statusArgumentHits(in: code, from: url.lastPathComponent))
        }
        return found
    }

    /// The matcher itself, over a string, so the planted-offender self-check
    /// can feed it code that is not on disk.
    static func statusArgumentHits(in code: String, from name: String) -> Set<String> {
        var found: Set<String> = []
        var rest = Substring(code)
        while let call = rest.range(of: "updateInspector(") {
            var depth = 1
            var idx = call.upperBound
            while idx < rest.endIndex, depth > 0 {
                if rest[idx] == "(" { depth += 1 } else if rest[idx] == ")" { depth -= 1 }
                idx = rest.index(after: idx)
            }
            if rest[call.upperBound..<idx].range(of: "status:") != nil { found.insert(name) }
            rest = rest[idx...]
        }
        return found
    }

    /// **The files that write a piece's pass states are the named hosts.**
    ///
    /// The Inspector is offered whatever the subject
    /// (`DetailSegment.pickerOrder` ends with it), and with a chapter open —
    /// where most of a review is spent — the Book's status board is not on
    /// screen, so the pass ladder the two Inspector arms host is the ruling
    /// surface there. The board's chips (`CentreColumn`) rule at Book level and
    /// the queue's pass-order nudge (`RightColumn`) beside a note.
    ///
    /// The census guards that every write goes to a HOST rather than into a
    /// pane, which would have cost the board its tripwire-4 cheapness (see
    /// `passStateWritingFiles`).
    func test_thePassStateWritersAreTheNamedHosts() throws {
        XCTAssertTrue(DetailSegment.pickerOrder.contains(.inspector),
            "the Inspector must be offered: with a chapter open the status board "
            + "is not on screen, and the ladder is the only surface there that "
            + "writes StructureItem.passStates.")

        XCTAssertEqual(
            try passStateWriters(),
            Self.passStateWritingFiles,
            "The set of files writing a piece's pass states has changed.\n\n"
            + "The members are the two Inspector arms — reached via "
            + "`ProjectWindow.inspectorRoute`'s `.segment` and `.collectionPiece` "
            + "routes — which host the pass ladder; `CentreColumn`, hosting the "
            + "status board's chips at Book level; and `RightColumn`, hosting the "
            + "queue's pass-order nudge.\n\n"
            + "If you have added a writer somewhere else, argue for it here; do "
            + "not just add a name to the expectation above.")
    }

    /// The census must be able to fail, and must be reading real code.
    ///
    /// Both halves matter: a walker that found nothing would make the set
    /// comparison above pass only by accident of also being empty, and one that
    /// matched reads as well as writes would sweep in every view that draws a
    /// pass state and stop being about writing at all.
    func test_thePassStateWriterCensusIsReadingRealCodeAndCanFail() throws {
        let census = try passStateWriters()
        XCTAssertFalse(census.isEmpty,
            "The census found no pass-state writers at all — it is reading "
            + "nothing, and the comparison above is vacuous.")
        XCTAssertFalse(census.contains("PassLadder.swift"),
            "`PassLadder` renders the ladder and must not write through it: the "
            + "write is the host's, so this census names the SURFACES that can "
            + "record a verdict. A shared leaf writer would collapse it to one "
            + "file and hide them (see PassLadder's doc comment).")
        XCTAssertFalse(census.contains("OutlineTable.swift"),
            "OutlineTable only READS the projection. If it appears here the "
            + "census is matching reads.")
        XCTAssertFalse(census.contains("ReviewBoardPane.swift"),
            "The Review board's own file must not write: it takes values and "
            + "closures so nothing on its per-row body path can reach a store or "
            + "the disk (tripwire 4, `ReviewBoardPaneTests"
            + ".test_theSourceReadsNoStoreAtAll`). Its write belongs to its host, "
            + "which is why `ProjectWindow.swift` — and not this file — is the "
            + "census's third member. If the pane has been handed a store, that "
            + "is the change to argue about, not this expectation.")
        XCTAssertTrue(census.isDisjoint(with: AnnotationsPaneSource.surfaceFiles),
            "The queue's pass-order nudge (2026-08-19) grew Mark done / Skip "
            + "buttons, but the write stays at the host exactly like the "
            + "board's and the ladder's: `AnnotationsPane.onSetPassState` is a "
            + "closure threaded in from `DetailPaneToggle`/`ProjectWindow`, "
            + "never a direct `store.setPassState` call in any of the pane's "
            + "files. If one appears here the pane has started writing directly and the "
            + "closure-threading argument in `AnnotationsPane.swift`'s own "
            + "doc comment no longer holds.")

        // The one excluded file must still be the DECLARATION. Without this the
        // exclusion is a hole: move the declaration and `passStateWriteDefiner`
        // starts silently exempting whatever file inherits the name.
        let definer = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham/Stores/\(Self.passStateWriteDefiner)")
        XCTAssertTrue(
            try String(contentsOf: definer, encoding: .utf8).contains("func setPassState("),
            "\(Self.passStateWriteDefiner) is excluded from the census as the place "
            + "`setPassState` is declared, but it no longer declares it — the "
            + "exclusion is now exempting a file for no reason.")

        // Planted offender: a third writer would be reported, and would not
        // equal the expectation.
        var planted = census
        planted.insert("SomeNewPane.swift")
        XCTAssertNotEqual(planted, Self.passStateWritingFiles,
            "Self-check: a third pass-state writer must disagree with the expectation.")
    }

    /// **`StructureItem.status` has no production writers left.** (M3 P1 Task 4.)
    ///
    /// FOUR greps, because the field can be written four ways and only one of
    /// them was ever a picker:
    ///
    /// 1. No `updateInspector(… status:)` call anywhere — the argument is gone
    ///    from the declaration, so this is belt to the compiler's braces, and it
    ///    is what fails if somebody re-adds the parameter and a call with it.
    /// 2. The declaration really has dropped the parameter (a call census over
    ///    an argument nobody could pass is trivially empty otherwise).
    /// 3. No production `.swift` file mints a status VALUE — no `status: "…"`
    ///    and no `.status = "…"`. This is the one that catches `ProjectFactory`'s
    ///    old `status: "draft"` seed, which was not a picker but did decide what
    ///    a brand-new document's field said.
    /// 4. **No bundled manifest RESOURCE carries a `status` key.** The third
    ///    creation path is not code at all: `SampleProjectBuilder` copies
    ///    `Maugham/Resources/Samples/<kind>/project.maugham.json` verbatim, so a
    ///    key in that JSON is a status write with no Swift to grep. Task 4's
    ///    first cut swept the Swift seed and left both samples hardcoding
    ///    `"status": "draft"` — onboarding's projects arrived pre-touched (a dot
    ///    on every chapter) while New Project's arrived clean, which is the
    ///    disagreement the seed removal existed to end. A `.swift`-only walker
    ///    could not see it; this arm is why the review's find cannot come back.
    ///
    /// What remains legal, and is deliberately not caught: `status: piece.status`
    /// (promotion CARRIES the writer's legacy string to the new project) and
    /// `.status = nil` (converting a piece to a reference CLEARS it). Both move
    /// or drop an existing value; neither invents one. A writer's OWN project on
    /// disk is untouched by any of this — the field is still read.
    func test_theStatusStringHasNoProductionWriters() throws {
        XCTAssertEqual(try statusArgumentCensus(), [],
            "Something passes `status:` to `updateInspector` again. The field is "
            + "legacy-read-only: `ReviewStatus.derived` falls back to it for "
            + "projects written before M3, and the ladder is what writes now.")

        let definer = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham/Stores/\(Self.passStateWriteDefiner)")
        let metadata = try String(contentsOf: definer, encoding: .utf8)
        let declaration = try XCTUnwrap(metadata.range(of: "func updateInspector("))
        let signature = metadata[declaration.upperBound...].prefix(while: { $0 != ")" })
        XCTAssertFalse(signature.contains("status:"),
            "`updateInspector` grew its `status:` parameter back. Removing it is "
            + "what made the compiler sweep the call sites in the first place.")

        var minters: Set<String> = []
        for file in try mintersOfAStatusLiteral() { minters.insert(file) }
        XCTAssertEqual(minters, [],
            "\(minters.sorted()) mints a literal `status` value. A seeded or "
            + "hardcoded draft/revising/final is a second answer beside the "
            + "derived one, and it makes an untouched piece indistinguishable "
            + "from a ruled-on one (`StatusSwatch.showsDot`).")

        let seeds = try Self.bundledSampleManifests()
        XCTAssertFalse(seeds.isEmpty,
            "the sample-manifest arm found no seeds to read — it is vacuous, and "
            + "the samples are a creation path with no Swift to grep")
        for (name, json) in seeds {
            XCTAssertFalse(Self.carriesAStatusKey(json),
                "\(name) hardcodes a `status` on a structure item. "
                + "`SampleProjectBuilder` copies this file verbatim, so every "
                + "sample project the writer creates from onboarding would arrive "
                + "pre-adjudicated — a dot on every chapter — while a New Project "
                + "document arrives untouched.")
        }
    }

    /// The three greps above must be able to fail — a census that cannot go red
    /// over an offender it was written for is cover, not a guard.
    func test_theStatusRetirementCensusFiresOnPlantedOffenders() throws {
        XCTAssertEqual(
            Self.statusArgumentHits(
                in: """
                    Task { try? await store.updateInspector(
                        id: piece.id,
                        status: newValue) }
                    """,
                from: "SomeNewPane.swift"),
            ["SomeNewPane.swift"],
            "the argument matcher missed a call spread over three lines with "
            + "`status:` on the last — the exact shape that once made this "
            + "census argue the opposite of the truth while staying green")
        XCTAssertEqual(
            Self.statusArgumentHits(
                in: "store.updateInspector(id: id, synopsis: s, tags: t)",
                from: "SomeNewPane.swift"),
            [],
            "control: the matcher must not report every `updateInspector` call, "
            + "or it is not about status at all")

        XCTAssertTrue(Self.mintsAStatusLiteral(in: #"status: "draft")"#),
                      "the literal matcher missed ProjectFactory's own old seed")
        XCTAssertTrue(Self.mintsAStatusLiteral(in: #"item.status = "final""#))
        XCTAssertFalse(Self.mintsAStatusLiteral(in: #"static let status = "status""#),
                       "control: a constant NAMED status is not a write of the "
                       + "field — DiagnosticIngest's JSON key, which the first "
                       + "run of this census reported")
        XCTAssertFalse(Self.mintsAStatusLiteral(in: "status: piece.status"),
                       "control: promotion CARRIES a legacy value and must stay legal")
        XCTAssertFalse(Self.mintsAStatusLiteral(in: "manifest.structure[i].status = nil"),
                       "control: converting to a reference CLEARS the field")

        // The resource arm, planted in the samples' own spelling (SwiftyJSON-
        // style spacing around the colon, which is what `JSONEncoder`'s
        // `.prettyPrinted` + `.sortedKeys` output in these files actually uses —
        // a matcher written for `"status":` alone would have read both seeds as
        // clean).
        XCTAssertTrue(Self.carriesAStatusKey("""
            { "structure" : [ { "id" : "doc-001", "status" : "draft" } ] }
            """),
            "the resource matcher missed the samples' own spelling — the exact "
            + "bytes that shipped pre-touched sample projects")
        XCTAssertTrue(Self.carriesAStatusKey(#"{"status":"final"}"#),
                      "…and the compact spelling a hand-edited seed would use")
        XCTAssertFalse(Self.carriesAStatusKey("""
            { "structure" : [ { "id" : "doc-001", "title" : "Welcome" } ] }
            """),
            "control: a seed with no status key must pass, or the arm is not "
            + "about status at all")
    }

    /// Does this manifest JSON carry a `status` key?
    ///
    /// Both spellings, because these files are `JSONEncoder` output with spaces
    /// around the colon and a hand-edited seed would not be.
    static func carriesAStatusKey(_ json: String) -> Bool {
        json.contains("\"status\" :") || json.contains("\"status\":")
    }

    /// Every bundled sample manifest, as `(path-ish name, contents)`.
    static func bundledSampleManifests() throws -> [(String, String)] {
        let samples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham/Resources/Samples", isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: samples, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [(String, String)] = []
        for case let url as URL in walker
        where url.lastPathComponent == ProjectManifest.fileName {
            let kind = url.deletingLastPathComponent().lastPathComponent
            found.append(("Samples/\(kind)/\(url.lastPathComponent)",
                          try String(contentsOf: url, encoding: .utf8)))
        }
        return found
    }

    /// Does this line mint a literal status value?
    ///
    /// The assignment arm requires the LEADING DOT (`.status = "`), because a
    /// bare `status = "` also matches a constant named `status` holding the
    /// string `"status"` — `DiagnosticIngest`'s JSON key, which this census
    /// reported on its first run. A field write always goes through a receiver.
    static func mintsAStatusLiteral(in line: String) -> Bool {
        line.contains("status: \"") || line.contains(".status = \"")
    }

    /// Production files minting a literal status value, comment lines dropped.
    private func mintersOfAStatusLiteral() throws -> [String] {
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham", isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let hit = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .contains { Self.mintsAStatusLiteral(in: String($0)) }
            if hit { found.append(url.lastPathComponent) }
        }
        return found
    }

    /// The Status column at altitude reads the PROJECTION, not the legacy
    /// string.
    ///
    /// A source census because the rendered value is not observable: measured
    /// (macOS 26.5) `OutlineTable`'s cells publish no `NSTextField` and the
    /// table's accessibility tree comes back unlabelled and valueless — see
    /// `InspectorPassLadderTests`' live-projection test, which makes the
    /// mounted half of this claim on the controls that ARE observable. With
    /// nothing writing `status`, a column printing it would have sat at "draft"
    /// under a green dot for ever.
    func test_theAltitudeStatusColumnReadsTheProjection() throws {
        let table = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/OutlineTable.swift")
        let code = try String(contentsOf: table, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("StatusSwatch.label(for:"),
                      "the Status column must render the derived status in words")
        XCTAssertFalse(code.contains("Text(item.status"),
                      "the Status column still prints the raw legacy string")
    }
}
