import XCTest
import MaughamCore
@testable import Maugham

/// Recovery spec §4: the read-only partial view can write NOTHING — zero ops
/// appended, `.md` byte-identical, pending file untouched, no checkpoint, no
/// seal — including across close(). This is the load-bearing rung: every
/// other rung is safe only because this one is.
@MainActor
final class ReadOnlyRecoveryTests: XCTestCase {

    /// Full gauntlet: open partial, hit EVERY mutation entry point, close.
    func test_partialView_writesNothing_evenAcrossClose() async throws {
        let (project, docURL) = try makeTestProject(prefix: "ROREC", initialMd: "One.\n\nTwo.\n")
        // A real session first, so the op log + a pending file exist.
        let doc1 = try await Document.load(url: docURL, device: "m", session: "s", presenter: nil)
        let docId = doc1.docId
        doc1.setFullText("One.\n\nTwo.\n\nThree.\n")
        try await doc1.flushBurstNow()
        await doc1.close()

        // Squat a second device's file so the strict load refuses…
        let bad = DeviceSlug.make(from: "bad")
        let badURL = OpLogStore.opLogFileURL(forDocId: docId, deviceSlug: bad, in: project)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)
        do {
            _ = try await Document.load(url: docURL, device: "m", session: "s", presenter: nil)
            XCTFail("precondition: the strict load must refuse")
        } catch {
            XCTAssertNotNil(
                RecoveryCause.classify(loadError: error, projectURL: project,
                                       isDatalessStub: { _ in false }),
                "a real refusal must classify — the whole ladder hangs on this "
                + "error crossing Document.load unwrapped")
        }

        // …then snapshot every byte the partial view must not change.
        let opsDir = project.appendingPathComponent(".maugham/ops")
        func snapshot() throws -> [String: Data] {
            var out: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: opsDir.path)
            where !name.hasPrefix(".") {
                // The squatting directory has no data; skip it.
                let url = opsDir.appendingPathComponent(name)
                if let d = try? Data(contentsOf: url) { out[name] = d }
            }
            out["__md__"] = try Data(contentsOf: docURL)
            let pendingDir = project.appendingPathComponent(".maugham/pending")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: pendingDir.path)) ?? [] {
                out["pending/\(name)"] = try? Data(contentsOf: pendingDir.appendingPathComponent(name))
            }
            return out
        }
        let before = try snapshot()

        // The partial open succeeds where the strict load refused…
        let doc = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil,
            recovery: .readOnlyPartial)
        XCTAssertTrue(doc.isReadOnlyRecovery)
        XCTAssertEqual(doc.readOnlyRecovery?.unreadableFiles.map(\.name),
                       [badURL.lastPathComponent], "the banner's names ride on the doc")
        XCTAssertTrue(doc.displayText.contains("Three."), "the readable history is all there")

        // …every mutation entry point no-ops…
        doc.setFullText("VANDALISM")
        doc.setParagraph(id: "zzzz", text: "VANDALISM")
        _ = doc.insertParagraph(after: nil, text: "VANDALISM")
        doc.deleteParagraph(id: "zzzz")
        doc.reorder(sequence: [])
        try await doc.flushBurstNow()
        XCTAssertTrue(doc.displayText.contains("Three."), "the view text never took the writes")
        XCTAssertFalse(doc.displayText.contains("VANDALISM"))

        // …and close writes nothing either (no flush, no autosave, no seal,
        // no pending clear).
        await doc.close()
        XCTAssertEqual(try snapshot(), before,
                       "byte-identical durable state after the whole gauntlet")
    }

    /// A clean project refuses the recovery mode: it exists only for the
    /// refusal path, never as a casual lenient open.
    func test_partialView_refusesWhenNothingIsUnreadable() async throws {
        let (_, docURL) = try makeTestProject(prefix: "ROREC2", initialMd: "Fine.\n")
        let doc1 = try await Document.load(url: docURL, device: "m", session: "s", presenter: nil)
        await doc1.close()
        do {
            _ = try await Document.load(
                url: docURL, device: "m", session: "s", presenter: nil,
                recovery: .readOnlyPartial)
            XCTFail("recovery mode on a healthy doc must refuse — use the normal load")
        } catch DocumentRecoveryError.nothingUnreadable {
            // The dedicated refusal: every file read cleanly, so there is no
            // partial view to offer and the normal load is the right door.
        }
    }

    // MARK: - The census

    /// The gauntlet above enumerates today's mutation entry points BY HAND, so
    /// it says nothing about the next one somebody writes. This census is the
    /// standing guard: in `Maugham/OpLog/Document*.swift`, every function that
    /// reaches `opStore.append(` or `pending.recordChange(` must consult the
    /// writability choke point FIRST.
    ///
    /// Tripwire-32 shape — **count the array, not this comment.** The
    /// allowlist below is the whole exemption list, each entry carrying why it
    /// cannot take a guard; a new writer is an offender until it is guarded or
    /// argued into that array in a review.
    func test_everyOpLogWriterConsultsTheWritabilityChokePoint() throws {
        var offenders: [String] = []
        for url in try Self.documentSourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            offenders += Self.unguardedWriters(
                in: source, file: url.lastPathComponent)
        }
        XCTAssertEqual(
            offenders, [],
            """
            Unguarded op-log writer(s). Open the function with \
            `rejectMutationIfNotWritable("name")` (Void) or \
            `try requireWritable("name")` (value-returning) before it writes — \
            or, if it genuinely cannot, add it to `writerAllowlist` with the \
            reason. See recovery spec §4.
            """)
    }

    /// The census is only worth its runtime if it FAILS on an offender. This
    /// plants four: an unguarded writer, one whose guard sits AFTER the write
    /// (the subtle case a substring check would wave through), one that
    /// records into the pending buffer, and one that reaches for the NARROW
    /// recovery-only arm under a name the M5-AN-048 allowlist does not carry —
    /// the case that satisfied the census by token match alone until the
    /// allowlist was added. The two properly guarded functions — the full
    /// guard, and the narrow arm under an allowlisted name — must NOT be
    /// reported.
    func test_theCensusFailsOnAPlantedOffender() {
        let planted = """
            extension Document {
                func plantedUnguardedWriter() async throws {
                    try await opStore.append(op)
                }
                func plantedGuardTooLate() async throws {
                    try await opStore.append(op)
                    if rejectMutationIfNotWritable("plantedGuardTooLate") { return }
                }
                func plantedPendingWriter() {
                    pending.recordChange(paragraphId: id, prior: nil, next: t)
                }
                func plantedNarrowGuardOffThePermittedList() async throws {
                    if rejectMutationIfReadOnlyRecovery("plantedNarrowGuardOffThePermittedList") { return }
                    try await opStore.append(op)
                }
                func plantedProperlyGuarded() async throws {
                    if rejectMutationIfNotWritable("plantedProperlyGuarded") { return }
                    try await opStore.append(op)
                }
                func appendLifecycleOp() async throws {
                    if rejectMutationIfReadOnlyRecovery("appendLifecycleOp") { return }
                    try await opStore.append(op)
                }
            }
            """
        let found = Self.unguardedWriters(in: planted, file: "Planted.swift")
        XCTAssertEqual(found.count, 4, "planted offenders missed: \(found)")
        for name in ["plantedUnguardedWriter", "plantedGuardTooLate",
                     "plantedPendingWriter",
                     "plantedNarrowGuardOffThePermittedList"] {
            XCTAssertTrue(found.contains { $0.contains(name) },
                          "census missed \(name): \(found)")
        }
        XCTAssertFalse(found.contains { $0.contains("plantedProperlyGuarded") },
                       "census reported a correctly guarded function")
        XCTAssertFalse(found.contains { $0.contains("appendLifecycleOp") },
                       "census reported an M5-AN-048 site taking the narrow arm "
                       + "it is named in `narrowGuardAllowlist` to take")
    }

    // MARK: - The delivery path

    /// Delivery-path census (the M9-OL-010 pattern): the refusal catch must
    /// classify, the body must render the pane for a classified cause, the
    /// read-only action must load `recovery: .readOnlyPartial` and must NOT
    /// register the doc, and the pane's auto-open must route through
    /// retryFullLoad. A mounted pin needs a full window fixture; this census
    /// catches each wire disappearing.
    func test_editorHostRefusalWiring_census() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Maugham/Views/EditorHost.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("RecoveryCause.classify(loadError:"),
                      "the catch classifies the refusal")
        XCTAssertTrue(source.contains("DocumentRecoveryPane("),
                      "a classified cause renders the pane, not the bare message")
        XCTAssertTrue(source.contains("recovery: .readOnlyPartial"),
                      "the read-only action uses the recovery load")
        // The recovery load's registration ban (spec §4): the only register
        // call must remain the normal path's single one.
        XCTAssertEqual(source.components(separatedBy: "documentStore.register(").count - 1, 1,
                      "exactly ONE register call site — the recovery doc is invisible to the registry MCP resolves through")
        XCTAssertTrue(source.contains("onOpenEditable: ") && source.contains("retryFullLoad()"),
                      "the pane's auto-open routes through the one retry path")
        // One refusal can follow another. The pane's watch starts on appear
        // and stops on disappear, so a model swapped in at a stable view
        // identity would leave the new cause unwatched and the old cause's
        // poller running with a callback that reloads a document the writer
        // has left. Identity-keying the pane is what makes the swap a
        // teardown; dropping the `.id` is silent.
        XCTAssertTrue(source.contains(".id(ObjectIdentifier(paneModel))"),
                      "the recovery pane is keyed on its model's identity")
        // Fix round 1 — the two defences against a stale action. The pane's
        // actions are minted once and one of them is fired by a POLLER, while
        // this host keeps its identity across a document switch: left standing,
        // the previous selection's pane reloads the document the writer left.
        // `EditorHostRecoveryActionGuardTests` pins what the guard DOES; these
        // pin that the delivery path still consults it, which no unit test of a
        // static function can see.
        XCTAssertTrue(source.contains("recoveryPaneModel?.stopWatching()"),
                      "a new load stops the previous selection's watch — "
                      + "the view's `.onDisappear` cannot run until a render "
                      + "pass the load's first suspension precedes")
        XCTAssertEqual(
            source.components(separatedBy: "Self.recoveryActionIsCurrent(").count - 1, 3,
            "ALL THREE minted actions — auto-open-editable, open-read-only and "
            + "set-aside — ask whether they are still the host's current model "
            + "before acting. The pane's actions are minted once with the model "
            + "and outlive the selection that raised them; set-aside is the one "
            + "of the three that MOVES A FILE, so a stale firing is the worst of "
            + "them. (The BANNER's set-aside is not counted here and needs no "
            + "guard: it is built per render inside `recoveryBannerInset`, from "
            + "the `doc` the body is currently rendering, so a superseded one "
            + "cannot exist to fire — the same shape as Reopen beside it.)")

        // MARK: Plan B — the set-aside wiring
        XCTAssertTrue(source.contains("OpLogQuarantine.quarantine("),
                      "the set-aside goes through the typed mover (tripwire 14), "
                      + "never a raw FileManager.moveItem on an op-log file")
        let bannerInset = Self.slice(
            of: source, from: "private func recoveryBannerInset",
            to: "private func retryFullLoad")
        XCTAssertTrue(
            bannerInset.contains("quarantineAndContinue()"),
            "the BANNER's offer reaches the same one verb — the read-only "
            + "writer who tried to type is the likeliest caller of all")
        // The CALL form, not the bare name: the comment beside these two
        // actions explains itself by naming the guard, and a census that
        // matched prose would fail on its own explanation.
        XCTAssertFalse(
            bannerInset.contains("Self.recoveryActionIsCurrent("),
            "and reaches it UNGUARDED, deliberately: both of the banner's "
            + "actions are built per render from the `doc` the body is "
            + "rendering, so there is no superseded one to refuse. A guard here "
            + "would be cargo — and would read as though the count above were "
            + "four")
        // Sliced from the pane's own mint (`let model = RecoveryPaneModel(`),
        // not from the first `onSetAside:` in the file — that one is the
        // BANNER's, several hundred lines above, and a slice starting there
        // swallows the pane's whole region and passes on the banner's wiring.
        let paneMint = Self.slice(
            of: source, from: "let model = RecoveryPaneModel(", to: "minted = model")
        XCTAssertTrue(
            paneMint.contains("onSetAside:")
                && paneMint.contains("quarantineAndContinue()"),
            "and so does the PANE's, minted with the model beside its two "
            + "siblings, so there is exactly one place that decides what gets "
            + "moved and what happens when a move fails")

        // MARK: Task 6 — the return runs itself at document open
        //
        // The hook must sit AFTER the pending-notice delivery, in the
        // success path only, and never on a recovery bind.
        let deliverRange = try XCTUnwrap(
            source.range(of: "deliverPendingRecoveryNoticeIfPossible()\n"),
            "the pending-notice delivery line the hook must follow")
        let afterDeliver = source[deliverRange.upperBound...]
        XCTAssertTrue(
            afterDeliver.contains("if !doc.isReadOnlyRecovery {"),
            "the auto-return hook sits after the pending-notice delivery, "
            + "guarded so it never runs on a read-only recovery bind")
        XCTAssertTrue(
            afterDeliver.contains("OpLogQuarantine.records("),
            "the hook reads this doc's held quarantine records")
        XCTAssertTrue(
            afterDeliver.contains("OpLogQuarantine.attemptReturn("),
            "the hook attempts the return for each held record")
        // `presenter: nil` is load-bearing (Task 5's review): passing this
        // view's own presenter would exclude the project's
        // ProjectFolderPresenter from the coordinated move, and it's that
        // presenter's callback that lets the OPEN document notice the
        // returned ops and merge them. The comment marker pins that the
        // reasoning travelled with the code, not just the literal.
        let hookSlice = Self.slice(
            of: String(afterDeliver), from: "if !doc.isReadOnlyRecovery {",
            to: "// Metrics for the freshly-loaded doc")
        XCTAssertTrue(
            hookSlice.contains("presenter: nil"),
            "presenter: nil keeps the project's own presenter eligible for "
            + "the change notification")
        XCTAssertTrue(
            hookSlice.contains("ProjectFolderPresenter"),
            "the comment explains WHY presenter: nil is correct here — a "
            + "bare nil with no reasoning is indistinguishable from an "
            + "oversight the next reader has to re-derive")
        XCTAssertTrue(
            hookSlice.contains("Self.autoReturnNotice("),
            "outcomes are mapped through the pinned pure helper, not "
            + "re-derived inline")
    }

    /// The text between two markers, for a census that must look INSIDE one
    /// function rather than anywhere in an 900-line file. Fails loudly rather
    /// than passing vacuously when a marker has moved.
    private static func slice(of source: String, from: String, to: String) -> Substring {
        guard let start = source.range(of: from) else {
            XCTFail("census marker not found: \(from)"); return ""
        }
        guard let end = source.range(of: to, range: start.upperBound..<source.endIndex) else {
            XCTFail("census marker not found after \(from): \(to)"); return ""
        }
        return source[start.upperBound..<end.lowerBound]
    }

    // MARK: - Census machinery

    /// Functions exempt from the census, each with the reason it cannot carry
    /// a guard. Keep this array SHORT and argued.
    private static let writerAllowlist: Set<String> = [
        // `Document.load`'s crash-recovery fold. Static: it runs before the
        // Document exists, so there is no instance to ask about writability —
        // and the recovery load reaches neither, because it skips the fold.
        "load",
    ]

    /// The sites permitted to satisfy the census with the NARROW
    /// (recovery-only) arm of the choke point, rather than the full guard.
    /// Every one is an annotation mutator whose closed-doc append is pinned by
    /// register claim **M5-AN-048** — widening it would re-decide that claim,
    /// which belongs in its own change with the claim and its filing moving
    /// alongside. Count the array, not a sentence: when M5-AN-048 closes,
    /// these collapse onto `rejectMutationIfNotWritable`/`requireWritable`
    /// and this list empties. A NEW writer reaching for the narrow arm is an
    /// offender until it is argued into this array in a review.
    private static let narrowGuardAllowlist: Set<String> = [
        "addAnnotation",                // value-returning; throws the refusal
        "appendAnnotationOpInternal",   // the shared annotation-op funnel
        "appendLifecycleOp",            // archive / reject / withdraw / reopen
    ]

    private static func documentSourceFiles() throws -> [URL] {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()   // OpLog
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
        let opLogDir = repoRoot.appendingPathComponent(
            "Maugham/OpLog", isDirectory: true)
        let all = try FileManager.default.contentsOfDirectory(
            at: opLogDir, includingPropertiesForKeys: nil)
        let documentFiles = all.filter {
            $0.lastPathComponent.hasPrefix("Document")
                && $0.pathExtension == "swift"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(
            documentFiles.isEmpty,
            "census found no Document*.swift to scan — the path is wrong, and a "
                + "census that scans nothing passes vacuously")
        return documentFiles
    }

    /// For every write call in `source`, find the nearest preceding `func`
    /// declaration and require a guard token between the two. Deliberately
    /// text-based and brace-free: "the guard appears before the write, inside
    /// the same declaration" is the property, and matching it this way cannot
    /// be fooled by a guard that sits after the write.
    private static func unguardedWriters(
        in source: String, file: String
    ) -> [String] {
        let writeTokens = ["opStore.append(", "pending.recordChange("]
        // The full guard: refuses a write on a closed doc AND on a recovery
        // view. Any writer may take it.
        let broadGuardTokens = ["rejectMutationIfNotWritable(", "requireWritable("]
        // The narrower recovery-only arm, which refuses the recovery view but
        // leaves a CLOSED doc's appends exactly as M5-AN-048 characterises
        // them. It satisfies the census ONLY for the sites named below: a new
        // writer that reaches for it is choosing the weaker guard, and the
        // census must say so rather than wave it through on a token match.
        let narrowGuardTokens = [
            "rejectMutationIfReadOnlyRecovery(", "requireNotReadOnlyRecovery(",
        ]

        // Every `func ` declaration, in source order, with its name.
        var funcStarts: [(at: String.Index, name: String)] = []
        var cursor = source.startIndex
        while let r = source.range(of: "func ", range: cursor..<source.endIndex) {
            let afterKeyword = source[r.upperBound...]
            let name = afterKeyword.prefix {
                $0.isLetter || $0.isNumber || $0 == "_"
            }
            funcStarts.append((at: r.lowerBound, name: String(name)))
            cursor = r.upperBound
        }

        var offenders: [String] = []
        for token in writeTokens {
            var searchFrom = source.startIndex
            while let call = source.range(
                of: token, range: searchFrom..<source.endIndex) {
                searchFrom = call.upperBound
                guard let owner = funcStarts.last(
                    where: { $0.at < call.lowerBound }) else { continue }
                if writerAllowlist.contains(owner.name) { continue }
                let body = source[owner.at..<call.lowerBound]
                let guarded = broadGuardTokens.contains { body.contains($0) }
                    || (narrowGuardAllowlist.contains(owner.name)
                        && narrowGuardTokens.contains { body.contains($0) })
                if !guarded {
                    offenders.append("\(file): \(owner.name) → \(token)")
                }
            }
        }
        return offenders.sorted()
    }
}
