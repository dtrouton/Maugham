import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The set-aside sentence is acknowledged, per device, per record** (signed
/// op log P2a, D2).
///
/// What shipped in P1 summed EVERY `.lines` record forever: a foreign line
/// found once became a standing accusation with no way to put it down short of
/// deleting the forensics. Denver's ruling is that the writer says "I've seen
/// this", the archive stays exactly where it is, and the sentence returns —
/// counting only what is new — the next time something writes a line Maugham
/// did not.
///
/// Pinned windowlessly throughout (tripwire 33): the predicate is pure over a
/// set of names, the count composes it with `OpLogQuarantine.setAsideChangeCount`
/// against a real temp project, and the two **Acknowledge** buttons are
/// asserted DRAWN by reading the panes' own source — never pressed and awaited.
@MainActor
final class SetAsideAcknowledgementTests: XCTestCase {

    // MARK: - The predicate

    func test_anAcknowledgedRecordStandsDownAndTheRestStandUp() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let records = try threeRecords(in: project)

        let acknowledged: Set<String> = [
            SetAsideAcknowledgement.name(for: records[1], in: project)
        ]
        let standing = SetAsideAcknowledgement.unacknowledged(
            records: records, acknowledged: acknowledged, in: project)

        XCTAssertEqual(standing.count, 2,
                       "one of three acknowledged leaves two still to say")
        XCTAssertEqual(
            standing.map { SetAsideAcknowledgement.name(for: $0, in: project) },
            [SetAsideAcknowledgement.name(for: records[0], in: project),
             SetAsideAcknowledgement.name(for: records[2], in: project)],
            "and the two that stand are the two the writer has not seen")
    }

    func test_nothingAcknowledgedLeavesEveryRecordStanding() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let records = try threeRecords(in: project)

        XCTAssertEqual(
            SetAsideAcknowledgement.unacknowledged(
                records: records, acknowledged: [], in: project).count,
            3,
            "an empty set is where every project starts \u{2014} nothing is "
            + "acknowledged until the writer acknowledges it")
    }

    /// A name no record on disk carries is harmless and is never swept: the
    /// archive it named may be on another device, or may have been read and
    /// deleted by hand, and forgetting an acknowledgement would resurrect a
    /// sentence the writer already put down.
    func test_aNameNoRecordCarriesIsHarmless() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let records = try threeRecords(in: project)

        let standing = SetAsideAcknowledgement.unacknowledged(
            records: records,
            acknowledged: ["doc-zzzz.phone.jsonl.deadbeef.stamp.lines"],
            in: project)
        XCTAssertEqual(standing.count, 3,
                       "a stranger's name filters nothing and throws nothing")
    }

    /// The key is the ARCHIVE file's own name — what
    /// `OpLogQuarantine.quarantinedFileURL` resolves and what the History
    /// pane's disclosure shows the writer. Not `originalName`, which several
    /// records share: one op-log file can be found carrying foreign lines more
    /// than once, and each finding is its own archive.
    func test_theKeyIsTheArchiveFilesOwnNameNotTheOpLogFilesName() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let records = try threeRecords(in: project)

        let names = records.map { SetAsideAcknowledgement.name(for: $0, in: project) }
        XCTAssertEqual(Set(names).count, 3,
                       "three findings of the same op-log file are three keys")
        for (record, name) in zip(records, names) {
            XCTAssertEqual(
                name,
                OpLogQuarantine.quarantinedFileURL(for: record, in: project)
                    .lastPathComponent)
            XCTAssertNotEqual(name, record.originalName,
                              "\u{2026}and the op-log file's own name is not it")
        }
    }

    // MARK: - The count and the sentence

    func test_theSentenceCountsTheUNACKNOWLEDGEDLinesAlone() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let records = try threeRecords(in: project)   // 3 + 2 + 1 lines

        XCTAssertEqual(
            OpLogQuarantine.setAsideChangeCount(records: records, in: project), 6,
            "premise: six set-aside changes across three records")

        let acknowledged: Set<String> = [
            SetAsideAcknowledgement.name(for: records[0], in: project)
        ]
        let standing = SetAsideAcknowledgement.unacknowledged(
            records: records, acknowledged: acknowledged, in: project)

        XCTAssertEqual(
            HistoryPane.setAsideChangesByReason(records: standing, in: project),
            ["written by something that is not Maugham": 3],
            "the three lines of the acknowledged record stop being counted")
        XCTAssertEqual(
            HistoryPane.setAsideChangesNotice(
                byReason: HistoryPane.setAsideChangesByReason(
                    records: standing, in: project)),
            "3 changes to this document were set aside (written by something "
            + "that is not Maugham); kept in backup, not applied.")
    }

    func test_everyRecordAcknowledgedSilencesTheSentenceEntirely() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let records = try threeRecords(in: project)

        let all = Set(records.map { SetAsideAcknowledgement.name(for: $0, in: project) })
        let standing = SetAsideAcknowledgement.unacknowledged(
            records: records, acknowledged: all, in: project)

        XCTAssertTrue(standing.isEmpty)
        XCTAssertNil(
            HistoryPane.setAsideChangesNotice(
                byReason: HistoryPane.setAsideChangesByReason(
                    records: standing, in: project)),
            "the writer has seen all of it; the notice goes away")
        XCTAssertNil(
            InboxPane.setAsideNotice(
                changeCount: OpLogQuarantine.setAsideChangeCount(
                    records: standing, in: project)),
            "\u{2026}and the inbox's sentence answers the same predicate")
    }

    /// The whole point of acknowledging per RECORD rather than per project: a
    /// new finding is a new sentence, and it counts only itself.
    func test_aNewRecordBringsTheSentenceBackCountingOnlyItself() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let records = try threeRecords(in: project)
        let acknowledged = Set(
            records.map { SetAsideAcknowledgement.name(for: $0, in: project) })

        let opsURL = project.appendingPathComponent(".maugham/ops/doc-abcd.phone.jsonl")
        let fresh = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [Data("{\"new\":1}".utf8), Data("{\"new\":2}".utf8), Data("{\"new\":3}".utf8),
             Data("{\"new\":4}".utf8)],
            from: opsURL, docId: "doc-abcd",
            reason: "written by something that is not Maugham", in: project))

        let standing = SetAsideAcknowledgement.unacknowledged(
            records: records + [fresh], acknowledged: acknowledged, in: project)

        XCTAssertEqual(standing, [fresh])
        XCTAssertEqual(
            HistoryPane.setAsideChangesNotice(
                byReason: HistoryPane.setAsideChangesByReason(
                    records: standing, in: project)),
            "4 changes to this document were set aside (written by something "
            + "that is not Maugham); kept in backup, not applied.",
            "the sentence returns for the new finding and counts only it")
    }

    /// Acknowledging is a UI-state write and nothing else: the archives are
    /// forensics and stay exactly where they were.
    func test_acknowledgingTouchesNothingOnDisk() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let records = try threeRecords(in: project)
        let dir = project.appendingPathComponent(".maugham/conflicts/quarantined-ops")
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        _ = SetAsideAcknowledgement.unacknowledged(
            records: records,
            acknowledged: Set(records.map {
                SetAsideAcknowledgement.name(for: $0, in: project)
            }),
            in: project)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
            before,
            "every archive and every sidecar is still there")
    }

    // MARK: - Fixtures

    /// Three `.lines` records for one op-log file, holding 3, 2 and 1 lines.
    /// Distinct bytes, because `setAsideLines` is content-deduped and the same
    /// bytes twice is deliberately one record.
    private func threeRecords(in project: URL) throws -> [QuarantineRecord] {
        let opsURL = project.appendingPathComponent(".maugham/ops/doc-abcd.phone.jsonl")
        let first = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [Data("{\"a\":1}".utf8), Data("{\"a\":2}".utf8), Data("{\"a\":3}".utf8)],
            from: opsURL, docId: "doc-abcd",
            reason: "written by something that is not Maugham", in: project))
        let second = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [Data("{\"b\":1}".utf8), Data("{\"b\":2}".utf8)],
            from: opsURL, docId: "doc-abcd",
            reason: "written by something that is not Maugham", in: project))
        let third = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [Data("{\"c\":1}".utf8)],
            from: opsURL, docId: "doc-abcd",
            reason: "written by something that is not Maugham", in: project))
        return [first, second, third]
    }

    private func makeProject() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("setaside-ack-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Where the acknowledgements live

/// The names are per-device derived state: `UIState`, under `.maugham/`, so
/// acknowledging on this Mac says nothing about the phone. Each device tells
/// its own writer once.
@MainActor
final class SetAsideAcknowledgementUIStateTests: XCTestCase {

    func test_aFileWithoutTheFieldDecodesToNothingAcknowledged() throws {
        let state = try JSONDecoder().decode(
            UIState.self, from: Data("{\"schemaVersion\":1}".utf8))
        XCTAssertTrue(state.acknowledgedSetAsideRecords.isEmpty,
                      "every ui-state.json written before this task is such a "
                      + "file, and every record in it still has its say")
    }

    func test_theNamesRoundTrip() throws {
        var state = UIState.empty
        state.acknowledgedSetAsideRecords = ["a.lines", "b.lines"]
        let back = try JSONDecoder().decode(
            UIState.self, from: try JSONEncoder().encode(state))
        XCTAssertEqual(back.acknowledgedSetAsideRecords, ["a.lines", "b.lines"])
    }

    /// Nothing acknowledged writes no key at all, so a `ui-state.json` on a
    /// project where this never happened is byte-for-byte what it was.
    func test_nothingAcknowledgedWritesNoKey() throws {
        let encoded = try JSONEncoder().encode(UIState.empty)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("acknowledgedSetAsideRecords"), "Got:\n\(text)")
    }

    /// The store's verb UNIONS: acknowledging one pane's notice never
    /// un-acknowledges what the other's already said.
    func test_theStoresVerbUnionsAndNeverForgets() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createNovelProject(
            named: "Setaside", in: temp.url)
        let store = try await DocumentStore.open(url: url)

        XCTAssertTrue(store.uiState.acknowledgedSetAsideRecords.isEmpty,
                      "premise: nothing acknowledged")

        store.acknowledgeSetAsideRecords(["a.lines", "b.lines"])
        XCTAssertEqual(store.uiState.acknowledgedSetAsideRecords,
                       ["a.lines", "b.lines"])

        store.acknowledgeSetAsideRecords(["c.lines"])
        XCTAssertEqual(store.uiState.acknowledgedSetAsideRecords,
                       ["a.lines", "b.lines", "c.lines"],
                       "the second press adds; it does not replace")

        store.acknowledgeSetAsideRecords([])
        XCTAssertEqual(store.uiState.acknowledgedSetAsideRecords,
                       ["a.lines", "b.lines", "c.lines"],
                       "an empty press is a no-op, not a clear")
    }
}

// MARK: - The two panes

/// **One predicate, two panes.** Both count only what
/// `SetAsideAcknowledgement.unacknowledged` returns and neither restates the
/// filter; both draw an **Acknowledge** button beside the sentence; the History
/// pane also lists every record REGARDLESS, because acknowledging is about the
/// sentence and never about the forensics.
///
/// Read off the panes' own source (tripwire 33: the buttons are asserted drawn,
/// never pressed and awaited) — the same census shape
/// `DiagnosticsPaneTests` uses for the reader picker's wiring.
@MainActor
final class SetAsideAcknowledgementPaneTests: XCTestCase {

    func test_theHistoryPanesSentenceCarriesAnAcknowledgeButton() throws {
        let source = try Self.source(of: "Views/HistoryPane.swift")
        let body = try XCTUnwrap(Self.declaration(named: "var body: some View {", in: source))

        XCTAssertTrue(
            body.contains("Self.setAsideChangesNotice(byReason: setAsideChangesByReason)"),
                      "premise: the sentence is still drawn. Got:\n\(body)")
        XCTAssertTrue(body.contains("Button(\"Acknowledge\", action: acknowledgeSetAside)"),
                      "\u{2026}and the writer can put it down. Got:\n\(body)")
    }

    func test_theHistoryPaneListsEveryRecordWhetherAcknowledgedOrNot() throws {
        let source = try Self.source(of: "Views/HistoryPane.swift")
        let body = try XCTUnwrap(Self.declaration(named: "var body: some View {", in: source))

        XCTAssertTrue(
            body.contains("SetAsideRecordsDisclosure(names: setAsideRecordNames)"),
            "the records are listed, from the unfiltered list, so acknowledging "
            + "hides the sentence and never the forensics. Got:\n\(body)")
        // …and the disclosure is still a disclosure. It moved out of `body`
        // into a view of its own so that its WIDTH could be measured without a
        // window (P2 smoke, find 8); what it draws did not change.
        let disclosure = try XCTUnwrap(Self.declaration(
            named: "struct SetAsideRecordsDisclosure: View {", in: source))
        XCTAssertTrue(disclosure.contains("DisclosureGroup(\"Set-aside records\""),
                      "Got:\n\(disclosure)")
    }

    func test_theInboxPanesSentenceCarriesAnAcknowledgeButton() throws {
        let source = try Self.source(of: "Views/InboxPane.swift")
        let body = try XCTUnwrap(Self.declaration(named: "var body: some View {", in: source))

        XCTAssertTrue(body.contains("Self.setAsideNotice(changeCount: setAsideChangeCount)"),
                      "premise: the sentence is still drawn. Got:\n\(body)")
        XCTAssertTrue(body.contains("Button(\"Acknowledge\", action: acknowledgeSetAside)"),
                      "\u{2026}and the writer can put it down here too. Got:\n\(body)")
    }

    /// **Find 7's wiring**: each pane counts its sentence against what its own
    /// stream is currently carrying, so a re-admitted change stops being called
    /// set aside. Read off the source — the alternative is a pane mounted
    /// against a project whose device was admitted mid-test, which is a window
    /// and a wait for a decision that is one argument.
    func test_eachPaneCountsAgainstWhatItsStreamIsCarrying() throws {
        XCTAssertTrue(
            try Self.code(of: "Views/HistoryPane.swift")
                .contains("applied: Set(ops.map(\\.opId))"),
            "History counts against the document's own ops \u{2014} the list it "
            + "has already loaded, so no body pass reads disk for it")
        XCTAssertTrue(
            try Self.code(of: "Views/InboxPane.swift")
                .contains("applied: store.appliedManifestIDs"),
            "\u{2026}and the Inbox against every manifest row its refresh "
            + "applied, whatever status that row now has")
    }

    /// The census: the filter is asked of `SetAsideAcknowledgement` and the
    /// acknowledged names are named ONLY where they are held, written, and
    /// handed to the predicate. A pane spelling `acknowledged.contains(…)` for
    /// itself would be a second answer to one question.
    func test_theTwoPanesCountThroughTheOnePredicateAndNeitherRestatesIt() throws {
        let panes = ["Views/HistoryPane.swift", "Views/InboxPane.swift"]
        for pane in panes {
            let code = try Self.code(of: pane)
            XCTAssertTrue(code.contains("SetAsideAcknowledgement.unacknowledged("),
                          "\(pane) must ask the one predicate")
            XCTAssertEqual(
                code.components(separatedBy: "acknowledgedSetAsideRecords").count - 1, 1,
                "\(pane) names the stored set exactly once \u{2014} reading it to "
                + "hand to the predicate, never to filter with")
        }

        let owners = try Self.filesNaming("acknowledgedSetAsideRecords",
                                          under: Self.appSourceDir)
        XCTAssertEqual(
            owners,
            ["Stores/DocumentStore.swift", "Stores/UIState.swift",
             "Views/HistoryPane.swift", "Views/InboxPane.swift"],
            "the field, its one write door, and the two readers that hand it "
            + "to the predicate \u{2014} nobody else. Got: \(owners)")
    }

    /// Control for the census above: the same walk over a planted third
    /// reader catches the code line and lets a doc comment through. Without
    /// this, a census that silently walked nothing would pass forever.
    func test_theCensusFiresOnAPlantedThirdReader() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("setaside-census-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        /// Mentions `acknowledgedSetAsideRecords` in prose — documentation.
        let clean = 1
        """.write(to: tmp.appendingPathComponent("Innocent.swift"),
                  atomically: true, encoding: .utf8)
        try """
        func thirdReader(state: UIState, name: String) -> Bool {
            state.acknowledgedSetAsideRecords.contains(name)
        }
        """.write(to: tmp.appendingPathComponent("Offender.swift"),
                  atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try Self.filesNaming("acknowledgedSetAsideRecords", under: tmp),
            ["Offender.swift"],
            "the census sees a reader that filters for itself, and a doc "
            + "comment naming the field is not one")
    }

    // MARK: - Census helpers

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/OpLog/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private static func source(of relativePath: String) throws -> String {
        try String(contentsOf: appSourceDir.appendingPathComponent(relativePath),
                   encoding: .utf8)
    }

    /// The file's CODE, comments stripped — a doc comment naming a symbol is
    /// documentation, not a second reader of it.
    private static func code(of relativePath: String) throws -> String {
        SourceScan.codeLines(of: try source(of: relativePath)).joined(separator: "\n")
    }

    /// Every production file under `root` whose CODE names `needle`, as paths
    /// relative to `root`, sorted. `root` is a parameter so the control below
    /// can run the same walk over a planted offender instead of the app.
    private static func filesNaming(
        _ needle: String, under root: URL
    ) throws -> [String] {
        let fm = FileManager.default
        // Both sides resolved: the enumerator answers real paths, and
        // `temporaryDirectory` is a symlink into `/private/var` — trimming a
        // `/var/…` prefix off a `/private/var/…` path silently trims nothing
        // and every hit comes back absolute. The control below caught exactly
        // that.
        let base = root.resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: nil) else { return [] }
        var hits: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  SourceScan.codeLines(of: text).contains(where: {
                      $0.contains(needle)
                  }) else { continue }
            hits.append(
                url.resolvingSymlinksInPath().path
                    .replacingOccurrences(of: base + "/", with: ""))
        }
        return hits.sorted()
    }

    /// The text from `name` to the end of its brace-balanced body
    /// (`ReviewBoardPaneTests`' reader, which this census shares).
    private static func declaration(named name: String, in source: String) -> String? {
        guard let start = source.range(of: name) else { return nil }
        var depth = 0
        var index = start.lowerBound
        var seenOpen = false
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1; seenOpen = true }
            if character == "}" {
                depth -= 1
                if seenOpen && depth == 0 {
                    return String(source[start.lowerBound...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
