import XCTest

/// **The wiring census: the one home for "this view still calls that".**
///
/// Some wiring no test can reach by behaviour: a menu item in `MaughamApp`, a
/// closure a `ProjectWindow` hands a pane, a `.onChange` inside a private
/// modifier. Each entry below names where the code lives, the tokens it must
/// still contain, and why losing one is a silent break (the feature compiles,
/// every behavioural test stays green, and the button does nothing).
///
/// **What this is not.** An architectural rule — a ban, a count, a closed set
/// of callers — is a tripwire, and lives in `TripwireGrepTests` or a named
/// census. Behaviour that a pure function or a posted event can show belongs in
/// a behavioural test; this census only keeps the last hop honest.
///
/// **Tolerant by construction**, so a reformat or a file split never turns it
/// red while the wiring holds:
/// - **Keys name a type or a symbol, never a file.** `type:<Name>` reads every
///   declaration of `<Name>` (extensions included, child views sharing the
///   file excluded); `family:ProjectWindow` reads the window's declarations
///   plus `SourceTree.windowFamilyTypes`; `decl:<header>` reads one
///   brace-matched declaration found by its header.
/// - **Comments are stripped** (`SourceScan.codeLines`): a comment quoting a
///   call is not the call.
/// - **Whitespace is ignored** where it separates punctuation, and collapsed to
///   one space between two identifier characters — so line breaks, indentation
///   and argument wrapping never matter, but `let x` never matches `letx`.
/// - **Order** is per entry: `.anyOrder` asks only that every token appear;
///   `.inOrder` asks that each appear after the one before it.
///
/// The planted control is `test_theCensusFailsOnAMissingTokenAndPassesAReformattedOne`.
final class WiringCensusTests: XCTestCase {

    enum Order { case anyOrder, inOrder }

    struct Entry {
        let key: String
        let order: Order
        let tokens: [String]
        let why: String

        init(_ key: String, _ order: Order, _ tokens: [String], why: String) {
            self.key = key
            self.order = order
            self.tokens = tokens
            self.why = why
        }
    }

    static let window = "family:ProjectWindow"

    static let entries: [Entry] = [
        // MARK: The run keys (⌘R, ⌘⇧R)
        Entry("type:FocusedRunButtons", .anyOrder,
              ["MaughamEvent.postCompilerRun()", #".keyboardShortcut("r", modifiers: .command)"#,
               "MaughamEvent.postCompilerFreshEyes()", #".keyboardShortcut("r", modifiers: [.command, .shift])"#],
              why: "the menu items post through the typed wrapper (tripwire 21) and carry ⌘R / ⌘⇧R; without them neither key reaches a window"),
        Entry("type:CompilerRunModifier", .anyOrder,
              [".onKeyWindowCommand(.maughamRunCompiler, window: window) { _ in send(Self.request(freshEyes: false, persona: persona, docId: activeDocId)) }",
               ".onKeyWindowCommand(.maughamFreshEyesCompiler, window: window) { _ in send(Self.request(freshEyes: true, persona: persona, docId: activeDocId)) }",
               "roster.compiler.runRequested( docId: request.docId, kind: request.kind, freshEyes: request.freshEyes)"],
              why: "each key hands its own request (CompilerRunCommandTests pins what `request` answers) to the compiler; a literal kind or a dropped flag here files ⌘R in Review as a check, or ⌘⇧R as an ordinary ⌘R"),
        Entry(window, .anyOrder,
              ["CompilerRunModifier(", "Task { await sessions.release(lease) }",
               "SaveFlashOverlay(isShowing: $flashes.showingCompiler"],
              why: "without the first the run keys are never mounted, without the second a closed window keeps its session alive, without the third the keystroke is unacknowledged"),
        Entry("decl:func runRoundWhenPieceOpens(", .anyOrder,
              ["RunWhenDocumentOpens.start(", "document(forDocId:", "onTimedOut:",
               ".show(.pieceWouldNotOpen)", "[flash = compilerFlash]"],
              why: "the chip's run waits, bounded, for the piece to be OPEN; its expiry says so through the window's one flash path, capturing the flash sink rather than the window for the wait's 5s"),

        // MARK: The Describe… hand-off across the window's sheets
        Entry(window, .anyOrder,
              [".onChange(of: activeSheet) { _, presented in firstReaderHandoff.sheetPresented(presented) }",
               ".sheet(item: $activeSheet, onDismiss: openFirstReaderIfRequested)",
               "onDescribeFirstReader: { firstReaderHandoff.describeRequested() }"],
              why: "every presentation, the Describe… press and every dismissal reach `FirstReaderHandoff` (DiagnosticsPaneTests pins its behaviour); a missed call strands a stale request or never hands the writer on"),
        Entry("decl:func openFirstReaderIfRequested() {", .inOrder,
              ["guard firstReaderHandoff.sheetDismissed() else { return }",
               "Self.selectDetailSegment( .firstReader"],
              why: "the dismissal asks the hand-off, then lands through the one pane-selection act"),
        Entry("decl:private var diagnosticsPane: some View {", .anyOrder,
              ["choice: ds.uiState.authorReaderChoice", "ds?.setAuthorReaderChoice(",
               "onOpenProjectSettings: onOpenProjectSettings"],
              why: "the pane defaults its reader to `.nobody` and both verbs to no-ops: a host that forgot them draws a picker that changes nothing"),
        Entry(window, .anyOrder, ["onOpenProjectSettings: openProjectSettings"],
              why: "the Diagnostics header's define item reaches the window's sheet"),

        // MARK: The editor host
        Entry("type:EditorHost", .anyOrder,
              ["reviewPassId: activeReviewPassId(",
               "answersInsertCommands: !DocumentFormat.ofManuscript(path: path).isScreenplay",
               "projectLabelsElsewhere: {",
               "tableFigureMaker: {"],
              why: "a margin note belongs to the active pass; a Markdown manuscript answers the Insert menu; a table label sees the project's other labels; ⌘⇧T has a table-figure maker"),
        Entry(window, .anyOrder, ["activeReviewPassId:"],
              why: "the window threads the pass resolver into EditorHost"),
        Entry("type:EditorHost", .anyOrder,
              ["let referenceIndex: ReferenceIndexHost",
               "referenceIndex: { [referenceIndex] in referenceIndex.index }",
               "referenceIndex.noteSettled(docId: doc.docId, text: doc.displayText)",
               "referenceIndex.labelsDefined(excluding: doc.docId)",
               "referenceIndex.invalidate(.all)",
               "await doc.close() referenceIndex.invalidate(.piece(doc.docId))",
               ".onChange(of: store.manifest.research) { _, _ in figureCards.invalidate() }"],
              why: "the editor is handed the window's reference index as a plain reference (tripwire 6), reads the cached value (never a build), feeds it at the metrics edge, asks every piece again on a document switch and re-reads the piece it leaves when it unmounts (the window's index outlives it); a research change refills the figure cards (report plan 7a Task 3)"),
        Entry("type:ReferenceIndexWiring", .anyOrder,
              ["host.attach(.window(store: store, documentStore: documentStore))",
               "referenceIndex.attach(nil)",
               "control.referenceIndexVersion = $0",
               "listing.refresh(index: host.index, store: store)",
               ".onChange(of: store?.manifest.research) { _, _ in referenceIndex.invalidate(.research) }",
               ".onChange(of: store?.manifest.structure) { _, _ in referenceIndex.invalidate(.all)",
               ".onChange(of: store?.manifest.figures) { _, _ in refreshListing() }",
               "referenceIndex.invalidate(.piece(changed))"],
              why: "the window's reference index is attached to the open project and invalidated on research, binder and closed-piece sync changes with or without an editor mounted, its version reaches the editor one-way, and every build or registry change refreshes the Figures listing (report plan 8a Task 2)"),
        Entry("decl:@MainActor static func window(store: ProjectStore, documentStore: DocumentStore) -> Self {", .anyOrder,
              ["DerivedManuscriptCache.tokens(forDocIds: docIds, in: url)",
               "store.derivedCache.displayText(forDocId: docId, in: store.url)"],
              why: "a closed piece is read from its op log behind the derived cache's token, one ops listing per rebuild (tripwire 20, whole-branch review I2)"),
        Entry(window, .anyOrder,
              ["ReferenceIndexWiring(", "referenceIndex: referenceIndex"],
              why: "the window mounts the wiring and hands its index to the centre column; without them the index is never attached, or the editor reads an empty one"),
        Entry(window, .inOrder,
              ["if !MaughamEvent.isLive(window) {", "referenceIndex.attach(nil)", "figureListing.clear()",
               "treeState.detachFigureCards()", "store = nil"],
              why: "a closed window detaches its index and the tree's figure cards explicitly, beside the stores' own release: the index's closures hold both stores, the cards' source holds the document store, and a husk's `.onChange` may never fire"),
        Entry("type:FigureSectionWiring", .anyOrder,
              ["documentStore.attachFigureCardCache(cards)",
               "await documentStore?.figureCardInputs()",
               "cards.onVersionChange = { [weak treeState] _ in treeState?.figureCardsChanged() }",
               "treeState.refreshFigureRows(listing: rows)",
               ".onChange(of: store?.manifest.figures) { _, _ in treeState.figureCards.invalidate() }",
               "previous.detachFigureCardCache(cards)"],
              why: "the tree's Figures rows follow the window's listing and the tree's own figure cards, attached to the document store's figure triggers and refilled on a registry change, so the parked test and the tags stay current with no editor mounted (report plan 8a Task 4)"),
        Entry(window, .anyOrder, ["FigureSectionWiring(", "listing: figureListing"],
              why: "the window feeds the tree's Figures section; without it the section never shows"),
        Entry("type:CentreColumn", .anyOrder, ["referenceIndex: referenceIndex,"],
              why: "the centre hands the window's index to the manuscript editor"),
        Entry("decl:func loadDocumentIfNeeded() async {", .anyOrder,
              ["documentStore.unregister(path: priorPath) referenceIndex.invalidate(.piece(prior.docId))"],
              why: "the piece just left is re-read from its flushed op log at the switch itself (plan 3b I1)"),
        Entry("type:MaughamTextView", .anyOrder,
              ["coordinator.asNotTyping { pasteAsTyped(sender) }",
               "coordinator.asNotTyping { super.performDragOperation(sender) }"],
              why: "a paste and a drop are not typing (no test may paste on the shared pasteboard or synthesise a drop)"),

        // MARK: The canvas centre
        Entry(window, .anyOrder,
              ["pieceTitle: { ProjectWindow.canvasPieceTitles(in: store).title(of: $0) }"],
              why: "the region inspector and the canvas read one title table, or they disagree about whether a chapter exists"),
        Entry(window, .anyOrder,
              ["if let refusal = canvasModel.sidecarRefusal", "try canvasModel.startFreshLayout()",
               "tryAgain: { canvasModel.retryUnreadable() }"],
              why: "the read-only and unreadable notices are mounted off the model's own state and wired to its verbs"),
        Entry("type:BinderView", .anyOrder, [".tag(BinderSubject.project)"],
              why: "the project row's value is the one Escape writes (§4.1: Escape IS the project row)"),
        Entry("type:TasksPane", .inOrder,
              [".contextMenu(forSelectionType: String.self", "primaryAction:",
               "Self.jumpTarget(for: ids, in: currentPool())", "jumpToParagraph(task)"],
              why: "double-click or Return on a task row jumps to its paragraph through the List's primary action, not a row tap gesture (tripwire 9)"),
        Entry(window, .anyOrder, ["selectTheProjectRow: { selectedSubject = .project }"],
              why: "the canvas's way out of the dim writes the project row's own value into the window's subject"),
        Entry("decl:struct PaletteWallModifier: ViewModifier {", .inOrder,
              [".onChange(of: selectedSubject) { _, _ in",
               "if paletteWall.showsWall { paletteWall.showsWall = false }"],
              why: "any subject change closes the palette wall — the door's own contract"),

        // MARK: Window notices, commands and sweeps
        Entry(window, .anyOrder, [".onProjectEvent(.maughamDocumentNotice", "restoreToast = message"],
              why: "the document notice has a project-scoped subscriber, rendered in the restore toast rather than a second overlay"),
        Entry(window, .anyOrder,
              [".onKeyWindowCommand(.maughamTranslatorsNote, window: window)", "activeSheet = .translatorsNote("],
              why: "⌘⌥C reaches a handler, and the handler opens the sheet"),
        Entry("decl:onKeyWindowCommand(.maughamFindInProject, window: window) { _ in", .anyOrder,
              ["treeFindActive = true"],
              why: "⌘⌥F opens the tree's find overlay"),
        Entry(window, .anyOrder, ["SubjectValidationModifier(store: store, documentStore: documentStore,"],
              why: "without the sweep nothing validates the subject on a structure change, and without the document store a parked figure stays the subject"),
        Entry("decl:private func openResearchItem(_ itemId: String) {", .inOrder,
              ["treeState.reveal(", "treeState.scrollRequest = .row("],
              why: "a forced entry opens the tree's section and scrolls to what `reveal` returned (ResearchSubjectRevealTests' probe mirrors this)"),
        Entry("decl:private func handleShowLatestMCPNote() {", .inOrder,
              ["treeState.reveal(", "treeState.scrollRequest = .row("],
              why: "the MCP banner's Show opens and scrolls the tree the same way"),
        Entry("type:BinderPaneToggle", .anyOrder, ["onRestoreOutcome: onRestoreOutcome"],
              why: "the trash disclosure is handed the window's restore reporter, or a shortfall has nowhere to go"),
        Entry("type:CollectionBinderPaneToggle", .anyOrder, ["onRestoreOutcome: onRestoreOutcome"],
              why: "the same, in a collection's binder"),
        Entry("type:ProjectStatisticsWindow", .anyOrder,
              ["cancelled: Task.isCancelled, window: self.window"],
              why: "the statistics window's keep-check reads the live window inside the closure"),

        // MARK: The centre's surfaces and their rules
        Entry(window, .anyOrder, ["title: store.manifest.title"],
              why: "the altitude and board mounts are handed the project's own name, not a pane label"),
        Entry(window, .anyOrder,
              ["structure: store.manifest.structure", "passes: store.manifest.effectiveReviewPasses"],
              why: "the review board's mount passes the manifest's values"),
        Entry("decl:func manuscriptEditor(", .anyOrder,
              [".task { refreshOpenNotes(store: store) }", ".onProjectEvent(.maughamAnnotationsChanged"],
              why: "the board recounts when it appears and when the project says its notes changed, through the scoped receive helper (ADR 0021)"),
        Entry("type:ProjectWindow", .anyOrder, ["showsTheReviewBoard"],
              why: "the window decides something about Review's centre and must ASK the predicate"),
        Entry("decl:static func reviewCentreShowsBoard(", .anyOrder,
              ["subjectShowsAltitude(", "showsTheReviewBoard"],
              why: "the board's rule composes the window's own document question and the persona predicate"),
        Entry("decl:static func publishCentre(", .anyOrder, ["subjectShowsAltitude("],
              why: "Publish's rule composes the window's own document question"),
        Entry("decl:static func selectDetailSegment(", .anyOrder,
              ["showInspector.wrappedValue = true", "assistant.dismiss()",
               "detailSegment.wrappedValue = seg"],
              why: "the one pane-selection act shows the column, ends a study and selects the pane"),
        Entry("decl:onKeyWindowCommand(.maughamSetDetailSegment, window: window) { note in", .anyOrder,
              ["ProjectWindow.selectDetailSegment("],
              why: "the key-window receiver calls the shared act"),
        Entry(window, .anyOrder, ["detailResizeHandle(documentStore: documentStore)"],
              why: "a fixed column's own divider is inert: without its handle the writer's one width is one width forever"),
        Entry(window, .anyOrder,
              ["IntentStrip.line(", "IntentDrift.mayTrailDraft(", "mayTrailDraft: intentStripMayTrailDraft",
               "lastRun(docId:"],
              why: "the strip's line is the one resolver's, and its draft mark comes from the one decision fed the standing run"),

        // MARK: The designer
        Entry("type:ProjectSession", .anyOrder,
              ["AgentRoster()", "roster.detachAll()", "designer.configure("],
              why: "the session's roster owns, wires and releases the designer"),
        Entry(window, .anyOrder, [".environment(roster)", "roster.updateModel("],
              why: "the window injects the roster and re-models it"),
        Entry("type:DetailPaneToggle", .anyOrder,
              ["@Environment(AgentRoster.self)", "{ roster?.designer }", "designer: designer"],
              why: "the desk reaches the designer through the roster the window injects"),
        Entry(window, .anyOrder,
              ["designGateActions(", "onProposalChanged:", "DesignGatePromotion."],
              why: "the gate is given wired verbs that run through the one performer, and the window takes the refreshed proposal back"),
        Entry(window, .anyOrder, ["DepartmentDesignRow.sendChanges"],
              why: "the gate reaches requestChanges' one spelling rather than composing its own"),
        Entry("type:DepartmentPaneHost", .anyOrder, ["DepartmentDesignRow.sendChanges"],
              why: "the desk reaches the same spelling"),
    ]

    // MARK: - The census

    func test_everyWiringEntryHolds() throws {
        let failures = try Self.failures(of: Self.entries, base: SourceTree.repoRoot)
        XCTAssertEqual(failures, [], "\n" + failures.joined(separator: "\n"))
    }

    func test_everyEntrySaysWhy() {
        for entry in Self.entries {
            XCTAssertFalse(entry.tokens.isEmpty, entry.key)
            XCTAssertFalse(entry.why.trimmingCharacters(in: .whitespaces).isEmpty, entry.key)
        }
    }

    // MARK: - The planted control

    /// A missing token fails, a token only in a comment fails, a token out of
    /// order fails an `.inOrder` entry and passes an `.anyOrder` one, and a
    /// reformatted call — wrapped across lines, re-indented, moved into an
    /// extension in another file — still passes. A token in a child view
    /// sharing the type's file is not the type's.
    func test_theCensusFailsOnAMissingTokenAndPassesAReformattedOne() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/Planted.swift": """
            struct Planted: View {
                var body: some View {
                    content
                        .wired(
                            to:   store,
                            onDone: { finish() }
                        )
                    // ghost(call)
                    second()
                }
            }
            struct ChildView { func f() { childOnly() } }
            """,
            "Maugham/Views/Planted+Split.swift": """
            extension Planted {
                func moved() { movedIntoAnExtension() }
            }
            """,
        ])
        func failures(_ order: Order, _ tokens: [String], key: String = "type:Planted") throws -> [String] {
            try Self.failures(of: [Entry(key, order, tokens, why: "planted")], base: base)
        }

        XCTAssertEqual(try failures(.anyOrder, [".wired(to: store, onDone: { finish() })"]), [],
                       "a call wrapped across lines and re-spaced is the same call")
        XCTAssertEqual(try failures(.anyOrder, ["movedIntoAnExtension()"]), [],
                       "a type key reads the type's extensions in other files")
        XCTAssertEqual(try failures(.anyOrder, ["second()", ".wired("]), [],
                       "any order is any order")
        XCTAssertEqual(try failures(.inOrder, [".wired(", "second()"]), [],
                       "control: in order, in order")

        XCTAssertEqual(try failures(.anyOrder, ["missing()"]).count, 1, "a missing token fails")
        XCTAssertEqual(try failures(.anyOrder, ["ghost(call)"]).count, 1,
                       "a token only in a comment is not code")
        XCTAssertEqual(try failures(.inOrder, ["second()", ".wired("]).count, 1,
                       "out of order fails an in-order entry")
        XCTAssertEqual(try failures(.anyOrder, ["childOnly()"]).count, 1,
                       "a child view sharing the file is not the type")
        XCTAssertEqual(try failures(.anyOrder, ["varbody"]).count, 1,
                       "whitespace between two identifiers is kept")
        XCTAssertEqual(try failures(.anyOrder, ["finish()"], key: "decl:func moved() {").count, 1,
                       "a decl key reads only that declaration")
        XCTAssertThrowsError(try failures(.anyOrder, ["x"], key: "type:NothingDeclaresThis"),
                             "a key naming nothing throws rather than passing empty")
    }

    // MARK: - Reading

    /// Every failed entry, as `key: missing token — why`. Throws when a key
    /// resolves to nothing. The tree is read ONCE per call, and
    /// each key's code and each type's declarations are computed once: the
    /// window family alone is twenty types, named by a dozen entries, and a
    /// walk per type per entry took the census to ~90s.
    static func failures(of entries: [Entry], base: URL) throws -> [String] {
        let reader = Reader(base: base)
        var out: [String] = []
        for entry in entries {
            let haystack = try reader.normalizedCode(of: entry.key)
            var from = haystack.startIndex
            for token in entry.tokens {
                let needle = normalized(token)
                let range: Range<String.Index>?
                switch entry.order {
                case .anyOrder: range = haystack.range(of: needle)
                case .inOrder: range = haystack.range(of: needle, range: from..<haystack.endIndex)
                }
                if let range {
                    from = range.upperBound
                } else {
                    out.append("\(entry.key): missing `\(token)`"
                               + (entry.order == .inOrder ? " (in order)" : "")
                               + " — \(entry.why)")
                }
            }
        }
        return out
    }

    /// The code a key names: `Maugham/` read once, each file masked at most
    /// once, and the answer memoised per key and per type for the life of one
    /// `failures` call. `decl:` keys are found in the same files, with `SourceTree.declaration`'s
    /// matching and its throw on none or more than one.
    final class Reader {
        let base: URL
        private var files: [(path: String, text: String, bytes: [UInt8])]?
        private var masks: [String: [UInt8]] = [:]
        private var byType: [String: [String]] = [:]
        private var byKey: [String: String] = [:]

        init(base: URL) { self.base = base }

        /// The files under `Maugham/` whose text contains `name`, each masked
        /// once and only when first asked for. The tree is read once, and the
        /// prefilter is `memmem` over the raw bytes: `String.contains` across
        /// 600-odd files is ~0.15s a call in a Debug build, and the window
        /// family alone asks twenty times.
        private func candidates(naming name: String) throws
            -> [(path: String, text: String, masked: [UInt8])] {
            if files == nil {
                files = try SourceTree.swiftFiles(under: "Maugham", base: base).map {
                    let text = try SourceTree.read($0, base: base)
                    return ($0, text, Array(text.utf8))
                }
            }
            let needle = Array(name.utf8)
            return try (files ?? []).filter { Self.contains(needle, in: $0.bytes) }.map { file in
                if let known = masks[file.path] { return (file.path, file.text, known) }
                let masked = try SourceTree.checkedMask(file.text, path: file.path)
                masks[file.path] = masked
                return (file.path, file.text, masked)
            }
        }

        private static func contains(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
            guard !needle.isEmpty else { return true }
            return haystack.withUnsafeBytes { h in
                needle.withUnsafeBytes { n in
                    memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
                }
            }
        }

        func normalizedCode(of key: String) throws -> String {
            if let known = byKey[key] { return known }
            let code = WiringCensusTests.normalized(try self.code(of: key))
            byKey[key] = code
            return code
        }

        /// The comment-stripped code a key names.
        func code(of key: String) throws -> String {
            let raw: [String]
            if key.hasPrefix("decl:") {
                let header = String(key.dropFirst(5))
                raw = [try SourceTree.declaration(
                    named: header, in: candidates(naming: SourceTree.withoutAccessModifiers(header)),
                    root: "Maugham")]
            } else if key == WiringCensusTests.window {
                raw = try declarations(of: "ProjectWindow")
                    + SourceTree.windowFamilyTypes.flatMap { type -> [String] in
                        do { return try declarations(of: type) } catch where base != SourceTree.repoRoot {
                            return []   // a planted tree plants only what it needs
                        }
                    }
            } else if let type = SourceTree.typeName(ofKey: key) {
                raw = try declarations(of: type)
            } else {
                throw SourceTree.LookupError(description: "WiringCensus: unknown key kind `\(key)`")
            }
            return raw.map { SourceScan.codeLines(of: $0).joined(separator: "\n") }
                .joined(separator: "\n")
        }

        /// The text of every declaration of `type` (extensions included) under
        /// `Maugham/`, each brace-matched; throws when nothing declares it.
        func declarations(of type: String) throws -> [String] {
            if let known = byType[type] { return known }
            let files = try candidates(naming: type)
            let ranges = try SourceTree.declarationRanges(of: type, in: files)
            guard !ranges.isEmpty else {
                throw SourceTree.LookupError(description: "WiringCensus: no file declares type '\(type)'")
            }
            let texts = Dictionary(files.map { ($0.path, $0.text) }, uniquingKeysWith: { a, _ in a })
            let found = ranges.keys.sorted().flatMap { file -> [String] in
                let lines = (texts[file] ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                return ranges[file, default: []].map {
                    lines[($0.lowerBound - 1)...($0.upperBound - 1)].joined(separator: "\n")
                }
            }
            byType[type] = found
            return found
        }
    }

    /// Whitespace dropped, except one space kept between two identifier
    /// characters — so a reflow never matters and `let x` never reads `letx`.
    static func normalized(_ text: String) -> String {
        func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var out = ""
        var pendingSpace = false
        for c in text {
            if c.isWhitespace { pendingSpace = true; continue }
            if pendingSpace, let last = out.last, isIdentifier(last), isIdentifier(c) { out.append(" ") }
            pendingSpace = false
            out.append(c)
        }
        return out
    }
}
