import SwiftUI
import XCTest
import MaughamCore
@testable import Maugham

/// `DetailPaneToggle` is generic over its inspector content, so a static
/// member reference has to bind that parameter — `<AnyView>` is an arbitrary
/// witness; `visibleSegments` is pure and ignores it (mirrors
/// `DetailPaneTogglePersonaTests`' own header comment).
final class PersonaPaneRegistryTests: XCTestCase {
    func test_everyPersona_offersAtLeastTwoPanes() {
        // A one-pane picker reads as broken chrome rather than a choice.
        //
        // **Nothing sits on this floor any more.** Publish did, exactly, from
        // slice 1 until §5.0's re-cut — which is why the floor was cited as
        // half the reason Publish kept `.inspector`. It carries five panes now,
        // and the real argument for that cell was always
        // `InspectorPublishSection` rather than the count; see the `.publish`
        // case in `Persona.panes`. Left in place as a floor, not as a reason.
        for persona in Persona.allCases {
            XCTAssertGreaterThanOrEqual(persona.panes.count, 2,
                                        "\(persona) offers \(persona.panes.count) pane(s)")
        }
    }

    func test_everyPersona_listsEachPaneAtMostOnce() {
        for persona in Persona.allCases {
            XCTAssertEqual(Set(persona.panes).count, persona.panes.count,
                           "\(persona) lists a duplicate pane")
        }
    }

    /// **Retired (stage 3a Task 6).** `.outline` was the one segment ever
    /// registered nowhere — the persona shell's slice 1 demoted it, leaving
    /// the tree to show structure while the read-only pane stayed reachable
    /// by shortcut alone. Task 6 finished that arc by deleting the case
    /// outright (its structure surface is the centre column now), and
    /// `.research`/`.palette` left every registry the same commit, so there
    /// is no longer any `DetailSegment` case unregistered everywhere — the
    /// census below (`test_everyDetailSegmentIsRegisteredSomewhere`) needs no
    /// exemption list for that claim at all.
    ///
    /// What still needs a list is a DIFFERENT mechanism this file used to
    /// conflate with "unregistered": a segment can reach a persona's picker
    /// WITHOUT that persona registering it, via `DetailPaneToggle
    /// .visibleSegments(including:)`'s append — `ProjectWindow` force-sets
    /// `detailSegment = .translation` on entering translation review from ANY
    /// persona, including the three whose own `panes` do not list it. That is
    /// still worth a named, non-vacuous example even though `.translation` is
    /// registered somewhere (Publish) — `test_forcedEntryReachesAPersonaThatDoesNotRegisterIt`
    /// is this list's own control, the way `test_nothingInTheUnregisteredListIsActuallyRegistered`
    /// used to be the retired list's.
    private static let forcedEntry: Set<DetailSegment> = [.translation]

    /// Every `DetailSegment` case has a home in at least one persona's own
    /// registry. Unlike the retired `deliberatelyUnregistered` census, this
    /// one asserts flatly — `.outline` was the last case allowed to be
    /// registry-less anywhere, and it was deleted rather than reinstated.
    func test_everyDetailSegmentIsRegisteredSomewhere() {
        let registered = Set(Persona.allCases.flatMap(\.panes))
        for segment in DetailSegment.allCases {
            XCTAssertTrue(registered.contains(segment),
                          "\(segment) is in no persona's registry. A new segment needs a "
                          + "persona — there is no more registry-less exemption.")
        }
    }

    /// The control for `forcedEntry`: a segment listed there only proves
    /// something about the append mechanism if some persona genuinely does
    /// NOT register it and still shows it via `visibleSegments(including:)`.
    func test_forcedEntryReachesAPersonaThatDoesNotRegisterIt() {
        XCTAssertFalse(Self.forcedEntry.isEmpty,
                       "the list is empty, so this control is vacuous")
        for segment in Self.forcedEntry {
            let outsidePersonas = Persona.allCases.filter { !$0.panes.contains(segment) }
            XCTAssertFalse(outsidePersonas.isEmpty,
                           "\(segment) is registered in every persona, so listing it in "
                           + "forcedEntry proves nothing about the append mechanism")
            for persona in outsidePersonas {
                let segments = DetailPaneToggle<AnyView>.visibleSegments(
                    persona: persona, including: segment)
                XCTAssertTrue(segments.contains(segment),
                              "\(persona) does not append the forced \(segment)")
            }
        }
    }

    func test_defaultPane_isTheFirstRegisteredPane() {
        for persona in Persona.allCases {
            XCTAssertEqual(persona.defaultPane, persona.panes.first)
        }
    }

    // MARK: - One order, four subsets

    /// **The canonical right-column order**, transcribed once. §5.0 of
    /// `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`
    /// (2026-08-03), which supersedes §5's per-persona lists for the right
    /// column. Denver: *"it'll be confusing if I am always hunting for the
    /// right option in different modes, so the order should be one set and
    /// things just disappear or appear in it, and we have some common
    /// anchors."*
    ///
    /// Three anchors: **Tasks** divides what you are working *with* from what
    /// is flowing *through*; **History** and **Inspector** close the row,
    /// Inspector outermost.
    ///
    /// **Inspector last is load-bearing, not tidiness.** `defaultPane` is
    /// `panes.first`, so each persona's default falls out of membership plus
    /// this order and nothing picks it. Inspector first — the shape an earlier
    /// draft of §5.0 had — would land every persona on Inspector and force
    /// `panes` to become an order plus a separate default: two values that can
    /// disagree about where a persona opens.
    ///
    /// Deliberately not `private`, unlike the ledgers below: a later test that
    /// needs this order should reuse it rather than transcribe it a second
    /// time, which is the whole argument for having one.
    /// Research and Palette left this order whole in stage 3a Task 6 — every
    /// tree grew its own section for both (stage 2a), so neither is a
    /// right-column segment any more.
    static let canonicalPaneOrder: [DetailSegment] = [
        .diagnostics, .annotations, .inbox, .intent,
        .references, .visualLanguage, .tasks, .translation, .history, .inspector
    ]

    /// **The order guard, and it is the first assertion of pane ORDER this
    /// suite has ever carried.** The right-column audit of 2026-08-03 found
    /// that order was asserted nowhere: every array-equality in
    /// `DetailPaneTogglePersonaTests` compares against `Persona.<x>.panes`
    /// itself and so re-derives under any permutation, and the only real
    /// constraint was on first elements. *"A reorder that keeps every first
    /// element would pass the whole suite while changing the picker for every
    /// writer."* `test_theOrderGuardCatchesAReorderThatKeepsEveryFirstElement`
    /// below is that reorder, planted.
    ///
    /// **Expressed as a derivation, never as four expected arrays.** A
    /// per-persona literal would have to be edited in the same commit as any
    /// membership change, which is exactly the edit that reintroduces drift —
    /// and four transcriptions of one order is four chances to mistype it. The
    /// persona's own members come from `panes`, so this test asserts one
    /// property and one only: **`panes` is a subsequence of the canonical
    /// order.** Membership is `test_everyPersona_matchesTheDesignMatrix`'s job
    /// and is not restated here.
    func test_everyPersonasPanesAreTheCanonicalOrderFilteredToItsMembers() {
        for persona in Persona.allCases {
            let members = Set(persona.panes)
            XCTAssertEqual(persona.panes,
                           Self.canonicalPaneOrder.filter(members.contains),
                           "\(persona)'s picker is not the canonical order filtered to "
                           + "its own members. A persona case in Persona.panes chooses "
                           + "MEMBERSHIP; the sequence is canonicalPaneOrder's and is "
                           + "the same in all four.")
        }
    }

    /// The control that keeps the guard above falsifiable from the other side.
    /// The expectation is built by filtering `canonicalPaneOrder`, so a segment
    /// **missing** from that order is silently dropped from the expectation —
    /// and the guard would then fail with a length mismatch whose message
    /// blames the persona rather than the order. This says which it is, and it
    /// is also the census a new `DetailSegment` has to answer: give it a place
    /// in the order. Since Task 6 there is no exemption list to name instead —
    /// every case has a persona (`test_everyDetailSegmentIsRegisteredSomewhere`).
    func test_theCanonicalOrderPlacesEveryPaneThatIsRegisteredAnywhere() {
        XCTAssertEqual(Set(Self.canonicalPaneOrder).count, Self.canonicalPaneOrder.count,
                       "canonicalPaneOrder lists a segment twice")
        XCTAssertFalse(Self.canonicalPaneOrder.isEmpty,
                       "the order is empty, so the guard above is vacuous")
        for segment in DetailSegment.allCases {
            XCTAssertTrue(Self.canonicalPaneOrder.contains(segment),
                          "\(segment) has no place in the canonical right-column order")
        }
    }

    /// **The planted offender.** Author's real panes, with History and
    /// References swapped — a permutation built to survive every other test
    /// in this suite: same members (so the design-matrix test passes), same
    /// first element (so `test_defaultPane_isTheFirstRegisteredPane`,
    /// `test_reviewPersona_leadsWithAnnotations`, `PersonaModifierTests` and
    /// every derived array-equality in `DetailPaneTogglePersonaTests` pass).
    /// Only the guard above sees it. A plant that does not fire is the finding.
    func test_theOrderGuardCatchesAReorderThatKeepsEveryFirstElement() {
        let offender: [DetailSegment] = [.diagnostics, .intent, .references,
                                         .history, .tasks, .inspector]

        // The plant is honest: a permutation of Author's own panes, not a
        // membership change wearing a permutation's clothes.
        XCTAssertEqual(Set(offender), Set(Persona.author.panes),
                       "the plant must differ from Author's panes only in ORDER — "
                       + "update it alongside Author's membership")
        XCTAssertNotEqual(offender, Persona.author.panes,
                          "the plant IS Author's order, so it plants nothing")
        XCTAssertEqual(offender.first, Persona.author.panes.first,
                       "the plant must keep the first element, or an existing test "
                       + "catches it and it proves nothing about order")

        // The guard's own predicate, run against the plant.
        XCTAssertNotEqual(offender,
                          Self.canonicalPaneOrder.filter(Set(offender).contains),
                          "the guard accepted a permutation — it is asserting "
                          + "membership, not order")
    }

    func test_authorPersona_excludesAnnotations() {
        // The two-loop separation from the design: adjudicating durable notes
        // is a review activity. Diagnostics (M2 Task 8) serve the fast loop
        // and are Author's, not Review's — the converse of this assertion.
        XCTAssertFalse(Persona.author.panes.contains(.annotations))
        XCTAssertTrue(Persona.author.panes.contains(.diagnostics))
        XCTAssertFalse(Persona.review.panes.contains(.diagnostics))
    }

    /// References is the one M2 pane both writing personas carry, and the
    /// asymmetry with Diagnostics above is the design's: a compiler run is the
    /// fast loop and belongs to whoever is drafting, while what a piece is
    /// pinned to is equally a question when adjudicating whether the draft used
    /// it (§6.3 marks it ● for Author and ○ for Review).
    func test_referencesServeBothWritingPersonasAndNeitherOfTheOthers() {
        XCTAssertTrue(Persona.author.panes.contains(.references))
        XCTAssertTrue(Persona.review.panes.contains(.references))
        XCTAssertFalse(Persona.plan.panes.contains(.references),
                       "Plan is where the pinned set is MADE — clustered on the canvas "
                       + "and linked in the tree — which is the left column's, not a "
                       + "pane's (§5.0's make-left/consult-right rule)")
        XCTAssertFalse(Persona.publish.panes.contains(.references))
    }

    /// The suite's oldest order constraint, and until 2026-08-03 its only one.
    /// It now has a sibling —
    /// `test_everyPersonasPanesAreTheCanonicalOrderFilteredToItsMembers` — and
    /// keeping both is deliberate: the sibling says Review's panes follow the
    /// shared order, this says Review must *lead* with adjudication. A future
    /// canonical order that moved Annotations off the front would satisfy the
    /// sibling and fail here, which is the argument that would need to be had.
    func test_reviewPersona_leadsWithAnnotations() {
        XCTAssertEqual(Persona.review.defaultPane, .annotations)
    }

    // MARK: - Why Review keeps the Inspector

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
    static let passStateWritingFiles: Set<String> = [
        "InspectorView.swift",
        "PieceInspector.swift",
        "ProjectWindow.swift",
    ]

    /// Where `setPassState` is DECLARED. Excluded from the census because a
    /// declaration is not a writer — the store is the one channel every writer
    /// goes through, which is what makes the census meaningful at all. Named
    /// rather than pattern-matched so moving the declaration fails loudly here.
    static let passStateWriteDefiner = "ProjectStore+Metadata.swift"

    /// Every production file under `Maugham/` that calls `needle`, by file
    /// name, ignoring comment-only lines.
    ///
    /// One walker for both censuses below. Comment-only lines are dropped
    /// first so a doc comment naming a call is never a hit — several of the
    /// comments in this very milestone name `setPassState` in prose.
    private func callers(of needle: String, excluding excluded: String? = nil) throws -> Set<String> {
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // MaughamTests/
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if let excluded, url.lastPathComponent == excluded { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains(needle) { found.insert(url.lastPathComponent) }
        }
        return found
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

    /// **Review keeps `.inspector` because the Inspector is where a writer rules
    /// on the piece they are READING.**
    ///
    /// **Re-made in M3 P1 Task 8, not patched.** The warrant this replaces said
    /// the two Inspector arms were the only surfaces that could record a verdict
    /// at all. That stopped being true the moment the board's chips could rule:
    /// a reviewer at project level now sets a pass from the centre column, and
    /// the old sentence would have gone on being cited while the census that
    /// backed it named three files.
    ///
    /// What is true instead, and is why the entry stays: **the board is
    /// project-level only.** `ProjectWindow.reviewCentreShowsBoard` composes
    /// `subjectShowsAltitude`, so the moment the reviewer opens a chapter — the
    /// state they are in for most of a review — the board is gone and the pass
    /// ladder in the Inspector is the only ruling surface on screen. Drop
    /// `.inspector` from Review and a reviewer reading a chapter has to go back
    /// up to the project, or switch persona, to mark its Copyedit done. That is
    /// a narrower claim than the old one and it is the one the code supports.
    ///
    /// The census is still the load-bearing half, and it now guards a second
    /// thing: that the board's write went where the ladder's writes go — to the
    /// host — rather than into the pane, which would have cost the board its
    /// tripwire-4 cheapness (see `passStateWritingFiles`).
    func test_reviewKeepsTheInspectorBecauseItIsWhereAPassIsRuledOn() throws {
        XCTAssertTrue(Persona.review.panes.contains(.inspector),
            "Review must offer the Inspector: with a chapter open — where a "
            + "reviewer spends most of a review — the passes board is not on "
            + "screen, and the ladder is the only surface that writes "
            + "StructureItem.passStates, the record Review adjudicates.")

        XCTAssertEqual(
            try callers(of: "setPassState(", excluding: Self.passStateWriteDefiner),
            Self.passStateWritingFiles,
            "The set of files writing a piece's pass states has changed.\n\n"
            + "`Persona.swift`'s `.review` case argues for keeping `.inspector` on "
            + "the grounds that a reviewer READING a chapter has no board on "
            + "screen, so the two Inspector arms — reached via "
            + "`ProjectWindow.inspectorRoute`'s `.segment` and `.collectionPiece` "
            + "routes — are the only ruling surfaces there. The third member is "
            + "`ProjectWindow` itself, hosting the Review board's chips at "
            + "project level (M3 P1 Task 8).\n\n"
            + "If you have added a writer somewhere else, re-make that argument at "
            + "the `.review` case; do not just add a name to the expectation above.")
    }

    /// The census must be able to fail, and must be reading real code.
    ///
    /// Both halves matter: a walker that found nothing would make the set
    /// comparison above pass only by accident of also being empty, and one that
    /// matched reads as well as writes would sweep in every view that draws a
    /// pass state and stop being about writing at all.
    func test_thePassStateWriterCensusIsReadingRealCodeAndCanFail() throws {
        let census = try callers(of: "setPassState(", excluding: Self.passStateWriteDefiner)
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

    // MARK: - The whole matrix, not a row at a time

    /// The design's pane × persona matrix, transcribed. Both `●` (primary) and
    /// `○` (available) mean the segment belongs to that persona; `—` means
    /// absent. Only segments that have a `DetailSegment` case today — Editions
    /// belongs to a later milestone and is listed as reserved in
    /// `Persona.panes`. Intent and Visual Language joined in M1A; Diagnostics
    /// and References in M2.
    ///
    /// **Three documents make this table, each later than the last, and the
    /// transcription's authority moved again on 2026-08-03.** The base is §6.3
    /// of `docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md`;
    /// §5 of `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`
    /// amends it; **§5.0 of that same document supersedes §5's per-persona
    /// lists for the right column**, and its four-row table is what is
    /// transcribed below. §5's own "Leaving, by persona" delta — which the last
    /// transcription used, because §5's three-column table dropped cells the
    /// delta kept — is no longer the authority for this registry.
    ///
    /// §5.0's rows, which are also the canonical order filtered four ways:
    ///
    /// - **Plan** — Inbox · Tasks · History · Inspector. It loses Research,
    ///   Palette, Intent and Visual Language: Plan authors all four, and
    ///   authoring is the left column's.
    /// - **Author** — Diagnostics · Research · Palette · Intent · References ·
    ///   Tasks · History · Inspector. Membership unchanged at §5.0; only the
    ///   order moved. `.diagnostics` and `.references` are M2's additions, both
    ///   made after this table's other four rows were transcribed — neither had
    ///   a `DetailSegment` case at the time, so neither could appear here yet
    ///   either. References is §6.3's `●` for Author.
    /// - **Review** — Annotations · Intent · References · Tasks · History ·
    ///   Inspector. It loses Palette, Visual Language and Translation, and
    ///   gains References, which §6.3 marks `○` here.
    /// - **Publish** — Visual Language · Tasks · Translation · History ·
    ///   Inspector. Translation arrives, reversing §5's move of it to Review.
    ///
    /// Two cells changed CATEGORY rather than membership, and both are worth
    /// naming because a reader of the previous version will look for them:
    /// **Plan's `.tasks` came off `notYetDelivered`** (§5 removed it, §5.0 is
    /// later and gives it back, so it is design now), and **Publish's
    /// `.inspector` came out of `documentedDeviations`** (§5.0 gives Inspector
    /// to all four, so it is no longer a deviation from anything — see
    /// `notYetDelivered`).
    ///
    /// **A THIRD supersession, later than §5.0: stage 3a Task 6 takes Research
    /// and Palette off Author's row.** Every tree grew its own section for
    /// both (stage 2a), so ⌘⌥R/⌘⌥P reveal those sections instead of a pane —
    /// the `DetailSegment` cases themselves are deleted, not merely demoted,
    /// so `.author`'s row below is what stage 3a's own docs (not §5.0) now
    /// authorize.
    ///
    /// Editing this table without re-citing it leaves the test asserting a
    /// matrix no document contains.
    private static let designMatrix: [Persona: Set<DetailSegment>] = [
        .plan: [.inbox, .tasks, .history],
        .author: [.diagnostics, .intent, .references,
                  .tasks, .history],
        .review: [.annotations, .intent, .references, .tasks, .history],
        .publish: [.visualLanguage, .tasks, .translation, .history]
    ]

    /// Departures the design requires that this re-cut does not deliver. This
    /// is the ledger the `Persona.panes` comment points at rather than
    /// restating. It is deliberately NOT merged into `documentedDeviations`: a
    /// deviation is a decision to differ from the design, this is a decision the
    /// design already made and a later slice carries out. Merging them would
    /// lose which of the two a reader is looking at.
    ///
    /// **One entry, and it is `.inspector` in all four.** §5.1 dissolves the
    /// Inspector into per-persona sections at slice 4. §5.0 is later than §5.1
    /// and keeps it in every persona until then — it anchors the far end of the
    /// canonical order, which is what lets `defaultPane` stay `panes.first` —
    /// so it is *pending*, not *deviant*, everywhere including Publish. What is
    /// particular to Publish is only that it will be the last one slice 4 can
    /// take: `InspectorPublishSection` is the app's sole per-piece publish
    /// config UI. That argument lives at the `.publish` case in `Persona.panes`.
    private static let notYetDelivered: [Persona: Set<DetailSegment>] = [
        .plan: [.inspector],
        .author: [.inspector],
        .review: [.inspector],
        .publish: [.inspector]
    ]

    /// Deviations the registry takes on purpose, each argued at its case in
    /// `Persona.panes`. Listing them here is what makes the matrix test able to
    /// fail on an oversight: anything outside matrix ∪ deviations ∪ pending is
    /// a pane nobody decided to add.
    ///
    /// **Empty as of §5.0, and the mechanism is kept rather than deleted.** Its
    /// one entry was Publish's `.inspector`, which §6.3 marked `—`; §5.0 gives
    /// Inspector to all four personas, so that cell stopped being a departure
    /// from the design and moved to `notYetDelivered` with the other three. An
    /// empty list here is a claim in its own right — every pane this registry
    /// offers is one some design document asks for.
    private static let documentedDeviations: [Persona: Set<DetailSegment>] = [:]

    /// Asserts every persona against the whole table in one pass. Row-at-a-time
    /// spot checks let the same defect through twice: Review lost `.translation`
    /// and `.palette` when the registry was written, and Plan lost `.tasks` in
    /// the commit that fixed Review. A per-row assertion can only ever prove
    /// its own row.
    func test_everyPersona_matchesTheDesignMatrix() {
        for persona in Persona.allCases {
            let expected = Self.designMatrix[persona] ?? []
            let allowed = expected
                .union(Self.documentedDeviations[persona] ?? [])
                .union(Self.notYetDelivered[persona] ?? [])
            let actual = Set(persona.panes)

            for segment in expected.subtracting(actual) {
                XCTFail("\(persona) is missing \(segment), which the design marks ● or ○")
            }
            for segment in actual.subtracting(allowed) {
                XCTFail("""
                    \(persona) offers \(segment), which the design marks —. If that is \
                    deliberate, argue it at the case in Persona.panes and add it \
                    to documentedDeviations; if a later slice removes it, add it \
                    to notYetDelivered.
                    """)
            }
        }
    }

    /// Every pane pending removal must still be registered — otherwise the
    /// entry is stale and the next reader believes a departure is owed that has
    /// already happened.
    func test_nothingInNotYetDeliveredHasAlreadyLeft() {
        for (persona, pending) in Self.notYetDelivered {
            for segment in pending {
                XCTAssertTrue(persona.panes.contains(segment),
                              "\(persona) no longer offers \(segment) — its departure "
                              + "shipped, so take it out of notYetDelivered")
            }
        }
    }

    /// The reserved segments have no case yet, so the matrix above cannot
    /// mention them. This pins the assumption: if a later milestone adds one,
    /// this test fails and `designMatrix` must gain its row.
    ///
    /// `forcedEntry` counts as a mention too, though it is no longer load-
    /// bearing for this particular union — every case left standing after
    /// Task 6's kill is registered in some persona's row already, so
    /// `designMatrix` alone would satisfy this test. It stays in the union
    /// because a case named ONLY via forced entry (none exists today) should
    /// still count as covered rather than "forgotten".
    func test_designMatrixCoversEveryDetailSegmentThatExists() {
        let mentioned = Set(Self.designMatrix.values.flatMap { $0 })
            .union(Self.documentedDeviations.values.flatMap { $0 })
            .union(Self.notYetDelivered.values.flatMap { $0 })
            .union(Self.forcedEntry)
        for segment in DetailSegment.allCases {
            XCTAssertTrue(mentioned.contains(segment),
                          "\(segment) exists but has no row in the transcribed matrix")
        }
    }

    func test_inboxIsPlanningOnly() {
        // Phone captures are raw planning material. They previously sat
        // between Tasks and Palette, which is why the segment needed an
        // unread badge to be discoverable at all.
        for persona in Persona.allCases where persona != .plan {
            XCTAssertFalse(persona.panes.contains(.inbox), "\(persona) should not offer the inbox")
        }
        XCTAssertTrue(Persona.plan.panes.contains(.inbox))
    }

    func test_coerce_keepsAPaneThePersonaOffers() {
        XCTAssertEqual(Persona.author.coerce(.tasks), .tasks)
    }

    func test_coerce_redirectsAPaneThePersonaDoesNotOffer() {
        XCTAssertEqual(Persona.author.coerce(.annotations), Persona.author.defaultPane)
    }
}
