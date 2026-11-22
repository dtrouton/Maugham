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
        // MARK: The run commands (⌘R, ⇧⌘R, ⌃⌘R, ⌃⇧⌘R)
        Entry("type:RunButtons", .anyOrder,
              ["MaughamEvent.postRun(.checkWriting)", #".keyboardShortcut("r", modifiers: .command)"#,
               "MaughamEvent.postRun(.reread)", #".keyboardShortcut("r", modifiers: [.command, .shift])"#,
               "MaughamEvent.postRun(.runRound)", #".keyboardShortcut("r", modifiers: [.command, .control])"#,
               "MaughamEvent.postRun(.freshEyes)", #".keyboardShortcut("r", modifiers: [.command, .control, .shift])"#],
              why: "each menu item posts its own command through the typed wrapper (tripwire 21) and carries its key; without them no run reaches a window, and a swapped pair posts a round under ⌘R"),
        Entry("type:CompilerRunModifier", .anyOrder,
              [".onKeyWindowCommand(.maughamRunCompiler, window: window) { _ in send(.checkWriting) }",
               ".onKeyWindowCommand(.maughamFreshEyesCompiler, window: window) { _ in send(.reread) }",
               ".onKeyWindowCommand(.maughamRunRound, window: window) { _ in send(.runRound) }",
               ".onKeyWindowCommand(.maughamFreshEyesRound, window: window) { _ in send(.freshEyes) }",
               "switch Self.decision(command, subject: subject, structure: structure, isDocumentOpen: isDocumentOpen) {",
               "case .pieceNotOpen(let kind): onPieceNotOpen(kind)",
               "roster.compiler.runRequested( docId: request.docId, kind: request.kind, freshEyes: request.freshEyes)"],
              why: "each event hands its own command's decision (CompilerRunCommandTests pins what `request` and `decision` answer) to the compiler; a swapped arm files ⌘R as a round, a literal kind or a dropped flag files Fresh Eyes as an ordinary check, and a dropped flash makes a run on a piece that is not open silent again"),
        Entry(window, .anyOrder,
              ["CompilerRunModifier(", "onPieceNotOpen: { [flash = compilerFlash] kind in flash.show(.openThePieceFirst(kind)) }",
               "Task { await sessions.release(lease) }",
               "SaveFlashOverlay(isShowing: $flashes.showingCompiler"],
              why: "without the first the run keys are never mounted (and the flash for a piece that is not open names the window's one flash path), without the second a closed window keeps its session alive, without the third the keystroke is unacknowledged"),
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
               "Self.pullUp( .firstReader"],
              why: "the dismissal asks the hand-off, then pulls her statement up through the one pull-up act"),
        Entry("type:ResolvePane", .anyOrder,
              ["choice: documentStore.uiState.authorReaderChoice", "documentStore.setAuthorReaderChoice(",
               "onOpenProjectSettings: onOpenProjectSettings"],
              why: "To resolve's head (the Diagnostics pane's header before it) defaults its reader to `.nobody` and both verbs to no-ops: a host that forgot them draws a picker that changes nothing"),
        Entry(window, .anyOrder, ["onOpenProjectSettings: openProjectSettings"],
              why: "the Diagnostics header's define item reaches the window's sheet"),

        // MARK: The editor host
        Entry("type:EditorHost", .anyOrder,
              ["reviewPassId: activeReviewPassId(",
               "answersInsertCommands: !DocumentFormat.ofManuscript(path: path).isScreenplay",
               "projectLabelsElsewhere: {",
               "tableFigureMaker: {",
               "existingFigures: { [figureListing, figureCards, referenceIndex, store, documentStore] liveText in",
               "live: ExistingFigurePicker.liveUses(in: liveText,",
               "elsewhere: ExistingFigurePicker.liveUsesElsewhere(",
               "existingFigureIsParked: { [documentStore] figureId in"],
              why: "a margin note belongs to the active pass; a Markdown manuscript answers the Insert menu; a table label sees the project's other labels; ⌘⇧T has a table-figure maker; Insert ▸ Existing Figure… reads the window's listing, the editor's live text and every other open document's (a figure placed before the settle is already used), parked figures left out by the editor's cards and refused by the store at the choice"),
        Entry("type:CentreColumn", .anyOrder, ["figureListing: figureListing,"],
              why: "the centre hands its editor the window's figure listing; without it Insert ▸ Existing Figure… offers nothing"),
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
               ".onChange(of: store?.manifest.research) { _, _ in referenceIndex.invalidate(.research) refreshListing() }",
               ".onChange(of: store?.manifest.structure) { _, _ in referenceIndex.invalidate(.all)",
               ".onChange(of: store?.manifest.figures) { _, _ in refreshListing() }",
               "referenceIndex.invalidate(.piece(changed))"],
              why: "the window's reference index is attached to the open project and invalidated on research, binder and closed-piece sync changes with or without an editor mounted, its version reaches the editor one-way, and every build, registry or Research change refreshes the Figures listing — a line into Research matches its item (report plan 8a Task 2, 8b Task 9)"),
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
        Entry("decl:func expandFigureGrid(lineAt location: Int) -> Bool {", .inOrder,
              ["windows.holdInPlace(figureId,", "fold: { [weak self] in",
               "self.figureGrid?.figureId == figureId", "self.forceFoldFigureGrid(.sentToResearch)"],
              why: "an in-place grid hands FigureWindows its own forced fold, the cause the grid's own Send to Research uses, so a tree row's send folds it first and its writes land before the park (report plan 8a Task 4)"),
        Entry(window, .anyOrder, ["FigureSectionWiring(", "listing: figureListing"],
              why: "the window feeds the tree's Figures section; without it the section never shows"),
        Entry("type:CentreColumn", .anyOrder, ["referenceIndex: referenceIndex,"],
              why: "the centre hands the window's index to the manuscript editor"),
        Entry("decl:func loadDocumentIfNeeded() async {", .anyOrder,
              ["documentStore.unregister(path: priorPath) referenceIndex.invalidate(.piece(prior.docId))"],
              why: "the piece just left is re-read from its flushed op log at the switch itself (plan 3b I1)"),
        Entry("type:MaughamTextView", .anyOrder,
              ["coordinator.asNotTyping { pasteAsTyped(from: pasteboard, sender) }",
               "coordinator.asNotTyping { super.performDragOperation(sender) }",
               "override func paste(_ sender: Any?) { paste(from: .general, sender: sender) }"],
              why: "a paste and a drop are not typing, and ⌘V is `paste(from: .general)` — the one body a test drives on a pasteboard of its own (shell p4 Task 11; no test synthesises a drop)"),

        // MARK: The canvas centre
        Entry(window, .anyOrder,
              ["pieceTitle: { ProjectWindow.canvasPieceTitles(in: store).title(of: $0) }"],
              why: "the region inspector and the canvas read one title table, or they disagree about whether a chapter exists"),
        Entry(window, .anyOrder,
              ["if let refusal = canvasModel.sidecarRefusal", "try canvasModel.startFreshLayout()",
               "tryAgain: { canvasModel.retryUnreadable() }"],
              why: "the read-only and unreadable notices are mounted off the model's own state and wired to its verbs"),
        Entry("type:BinderView", .anyOrder, [".tag(TreeRowTag.subject(.project))"],
              why: "the project row's value is the one Escape writes (§4.1: Escape IS the project row)"),
        Entry("type:BinderView", .inOrder,
              [#"await addItem( parent: nil, kind: .document(store.manifest.type.primaryFormat)) } } label: { Label("New Document", systemImage: "doc.badge.plus")"#,
               #"Task { await addItem(parent: nil, kind: .group) } } label: { Label("New Group", systemImage: "folder.badge.plus")"#],
              why: "the empty state's own New Document / New Group buttons (each action spanned to its label, so the root context menu's identical calls cannot stand in) run the binder's creation verb, which TreeStructureCreationTests pins windowlessly (#120, tripwire 33); a dropped action draws buttons that make nothing"),
        Entry("type:BinderView", .anyOrder,
              ["try await Self.addItem(parent: parent, kind: kind, in: store)"],
              why: "every creation button and menu item reaches the static verb the tests pin"),
        // MARK: The pressed tests #120 made windowless (Task 1b)
        Entry("type:DiagnosticsDriftLine", .anyOrder,
              ["Button { MaughamEvent.postPosition(.brief) } label: { Text(line)"],
              why: "the drift line asks for Brief, where the intent it names is; a dropped hop is a line that does nothing"),
        Entry("type:DiagnosticRow", .anyOrder, ["ExcerptChip(ref: ref, onJump: onJump)"],
              why: "a diagnostic's chip carries the pane's jump"),
        Entry("type:ExcerptChip", .inOrder,
              ["func jump() { onJump(ref.paragraphId) }", "Button { jump() } label:"],
              why: "the chip's press is `jump()`, which DiagnosticsPaneTests calls"),
        // MARK: The annotation queue's hops (#116 F11)
        Entry("type:ResolvePane", .anyOrder,
              ["ResolveHeadView(", "AnnotationRowHost(", "AnnotationsBulkBar(",
               ".modifier(ResolveDialogs(",
               // The posture's verbs, narrowed to Reopen alone on a row
               // wearing the stet flourish (Task 6 fix 2).
               "let decided = rowVerbs(for: ann, docId: docId, isOwn: isOwn)",
               // Which rows are narrowed: those wearing the flourish now.
               "return flourishing.contains(ann.id)",
               "ResolveStetHold.heldVerbs(decided, status: ann.status) : decided",
               // The settled figure notes' section (review I2).
               "ResolveFigureSettledSection(",
               "onAccept: { verbs.accept($0, $1) }",
               "onReject: { rejectSheet = ResolveNoteTarget(document: $0, annotation: $1) }",
               "onStet: { verbs.stet($0, $1) }",
               "onTriage: { verbs.triage($0, $1, mark: $2) }",
               "onArchive: { verbs.archive($0, $1) }",
               "onReply: { querySheet = ResolveNoteTarget(document: $0, annotation: $1) }",
               "onAnswerAsRuling: { rulingSheet = ResolveNoteTarget(document: $0, annotation: $1) }",
               "onMakeChoice: { verbs.performChoice($0, $1) }",
               "onKeepAsLesson: { keepLessonSheet = ResolveLessonTarget(docId: $0, annotation: $1) }",
               "onEdit: { editSheet = ResolveNoteTarget(document: $0, annotation: $1) }",
               "onWithdraw: { withdrawConfirm = ResolveNoteTarget(document: $0, annotation: $1) }",
               "onRevert: { verbs.revert($0, $1) }",
               "onReopen: { verbs.reopen($0, id: $1.id) }",
               "onJump: { docId, ann in go(.note(ProjectAnnotation(docId: docId, annotation: ann))) }",
               // A figure note's verbs (report plan 9c-1 Task 7).
               "onAccept: { verbs.figureAccept($0, $1) }",
               "onReject: { figureRejectSheet = ResolveFigureNoteTarget(figureId: $0, annotation: $1) }",
               "onStet: { verbs.figureStet($0, $1) }",
               "onArchive: { verbs.figureArchive($0, $1) }",
               "onReply: { figureReplySheet = ResolveFigureNoteTarget(figureId: $0, annotation: $1) }",
               "onReopen: { verbs.figureReopen($0, $1) }"],
              why: "To resolve (shell plan 2 Task 7; the Annotations pane before it) mounts its head and rows, hands them its OWN row wiring (a read-only wiring there would hide every verb and stay green), and hands every row verb to its own verb or sheet; a dropped hop is a row button that does nothing"),
        Entry("type:AnnotationRowHost", .anyOrder,
              ["verbs: ResolveVerbGate.noteVerbs(", "mayAct: rowDocument != nil)",
               "onToggleSelection: { wiring.onToggleSelection(ann.id) }",
               "onAccept: { withDocument(rowDocument) { wiring.onAccept($0, ann) } }",
               "onReject: { withDocument(rowDocument) { wiring.onReject($0, ann) } }",
               "onStet: { withDocument(rowDocument) { wiring.onStet($0, ann) } }",
               "withDocument(rowDocument) { wiring.onTriage($0, ann, mark) }",
               "onArchive: { withDocument(rowDocument) { wiring.onArchive($0, ann) } }",
               "onReply: { withDocument(rowDocument) { wiring.onReply($0, ann) } }",
               "onAnswerAsRuling: { withDocument(rowDocument) { wiring.onAnswerAsRuling($0, ann) } }",
               "onMakeChoice: { withDocument(rowDocument) { wiring.onMakeChoice($0, ann) } }",
               "onKeepAsLesson: { wiring.onKeepAsLesson(docId, ann) }",
               "onEdit: { withDocument(rowDocument) { wiring.onEdit($0, ann) } }",
               "onWithdraw: { withDocument(rowDocument) { wiring.onWithdraw($0, ann) } }",
               "onRevert: { withDocument(rowDocument) { wiring.onRevert($0, ann) } }",
               "onReopen: { withDocument(rowDocument) { wiring.onReopen($0, ann) } }",
               "onJumpToParagraph: { wiring.onJump(docId, ann) }",
               // A figure's row (report plan 9c-1 Task 7): no Document belt.
               // A live figure suggestion's Accept is the row's click (9c-2 Task 7).
               "onAccept: { gate.acceptTravels ? wiring.onJump(figureId, ann) : figure.onAccept(figureId, ann) }",
               "onReject: { figure.onReject(figureId, ann) }",
               "onStet: { figure.onStet(figureId, ann) }",
               "onArchive: { figure.onArchive(figureId, ann) }",
               "onReply: { figure.onReply(figureId, ann) }",
               "onReopen: { figure.onReopen(figureId, ann) }",
               "onJumpToParagraph: { wiring.onJump(figureId, ann) }"],
              why: "the row host hands each row verb to its wiring behind the open-piece gate and the no-document belt (Keep as lesson needs no document); a figure's row to the wiring's figure verbs"),
        Entry("type:ResolvePane", .anyOrder,
              ["notThisLine(item, note: note, acting: acting)", "Self.offersNotThis(",
               "CheckNarrative.notThis(", "DiagnosticsColdStartOffer("],
              why: "a check's note row mounts its one-gesture Not this, gated and run by the pinned verbs, and an unchecked open piece mounts the cold-start offer; a dropped mount ships green otherwise (Task 7 fix 2, N2)"),
        Entry("type:ResolveHeadView", .anyOrder, ["DiagnosticsDriftLine("],
              why: "the head mounts the drift line its re-pinned tests measure on their own (Task 7 fix 2, N2)"),
        Entry("type:ResolveSettledSection", .anyOrder,
              [#"Button("Restore") { noteVerbs.reopen(document, id: note.id) }"#],
              why: "the Settled section's Restore reaches the list's reopen (the old document queue's Deleted view)"),
        Entry("type:AnnotationsBulkBar", .inOrder,
              ["private func bulkButton(", "verbs.runBulk(verb, on: planned, in: document)",
               "private func bulkMenuItem(", "verbs.runBulk(verb, on: planned, in: document)"],
              why: "both the bar's buttons and its triage items run the list's one bulk executor"),
        Entry("type:ResolveDialogs", .anyOrder,
              ["verbs.reject(target.document, target.annotation, reason: reason)",
               "verbs.replyToQuery(target.document, target.annotation, reply: reply)",
               "verbs.answerAsRuling(target.document, target.annotation, answer: answer)",
               "verbs.keepAsLesson(target.annotation, heading: heading)",
               "Task { await verbs.performAccept(target.document, target.annotation) }",
               "verbs.performRevert(target.document, target.annotation)",
               "verbs.editOwn(target.document, target.annotation,",
               "verbs.withdrawOwn(target.document, target.annotation)",
               "set: { if !$0 { verbs.setChoiceOffer(nil) } }",
               "verbs.figureReject(target.figureId, target.annotation, reason: reason)",
               "verbs.figureAccept(target.figureId, target.annotation, reply: reply)"],
              why: "every sheet's commit and every alert's confirm reaches the pane's verb; a dropped hop is a dialog that closes and does nothing"),
        // MARK: History's hops (#116 F11)
        Entry("type:HistoryPane", .anyOrder,
              ["HistoryNotices(", "HistoryTimeline(",
               "retryQuarantine: verbs.retryQuarantine,",
               "acknowledgeSetAside: verbs.acknowledgeSetAside,",
               "acknowledgeLostHistory: verbs.acknowledgeLostHistory,",
               "sendHeldWordsToInbox: verbs.sendHeldWordsToInbox,",
               "sendSetAsideToInbox: verbs.sendSetAsideToInbox)",
               "jump: verbs.jump)",
               ".task { await verbs.reload() }",
               ".task(id: heldHolderKey) { await verbs.reloadHeldWordCounts() }",
               ".onChange(of: activeDocId) { _, _ in Task { await verbs.reload() } }"],
              why: "the pane mounts its notices and timeline, hands every press to its own verb, and reloads on open, on a new provenance's holders and on a document switch; a dropped hop is a button that does nothing or a pane that never refreshes"),
        Entry("type:HistoryNotices", .anyOrder,
              [#"Button("Retry", action: retryQuarantine)"#,
               #"Button("Acknowledge", action: acknowledgeSetAside)"#,
               "acknowledgeLostHistory(row.streamKey)",
               "HeldLineNoticeRow(row: row) { sendHeldWordsToInbox($0) }",
               "rows: setAsideRows, onSend: sendSetAsideToInbox)",
               "MaughamEvent.postAdmissionRequested( projectURL: projectURL, forced: true)",
               #"Button("View") { showingRecoveredHistorySheet = true }"#],
              why: "each notice's control reaches the verb it is handed, Admit… asks the window for the sheet, forced, and View opens the recovered-history sheet"),
        Entry("type:HistoryTimeline", .anyOrder,
              ["let rows = entries", "ForEach(rows) { entry in",
               "let opsIndex = HistoryPane.opsIndex(ops)", "lookupOp: { opsIndex[$0] }",
               "HistoryRow(", "onJump: { jump(entry) }",
               "selectedCheckpoint = cp", "showingRestorePicker = true",
               "expanded.remove(entry.id)", "expanded.insert(entry.id)"],
              why: "the rows and the op index are built once per pass and captured, never rebuilt per row (tripwire 4); a row's ⌘-click jumps, its Revert here… opens the picker on its checkpoint, and a click toggles it open"),
        Entry("type:BriefPieceView", .anyOrder,
              ["GoingForView( store: store, documentStore: documentStore, scope: .document(docId),"],
              why: "a piece's Brief draws its intent over the piece itself (the old inspectors' Open Intent row, which led here, is gone with them)"),
        Entry("type:BriefBookView", .anyOrder,
              ["GoingForView( store: store, documentStore: documentStore, scope: .project,"],
              why: "the Book's Brief draws the Book's intent"),
        Entry("type:IntentStrip", .anyOrder,
              ["Button { MaughamEvent.postBriefOfTheOpenPiece() } label:"],
              why: "the strip's click asks for the open piece's Brief, the request IntentStripTests pins"),
        Entry("decl:onKeyWindowCommand(.maughamShowOpenPieceBrief, window: window) { _ in", .anyOrder,
              ["ProjectWindow.showBriefOfTheOpenPiece( subject: $subject, showInspector: $showInspector, position: $position,"],
              why: "the strip's post reaches the window's hand-off; without the receiver the line above the prose is a button that does nothing"),
        Entry("decl:static func showBriefOfTheOpenPiece(", .inOrder,
              ["RightColumnContent.facesForTheStrip(", "Self.selectPosition( .brief,"],
              why: "the faces go to the open piece, then Brief shows through the one selection act"),
        Entry("type:DesignGateView", .inOrder,
              ["if let confirmation = DesignGate.confirmation( for: verb, perform: { confirmed(verb) }, cancel: { cancelConfirmation() }) { pendingConfirmation = confirmation onConfirmationChanged(confirmation) return } run(verb)",
               "private func confirmed(_ verb: DesignGate.Verb) { pendingConfirmation = nil onConfirmationChanged(nil) run(verb) }",
               "private func cancelConfirmation() { guard pendingConfirmation != nil else { return } pendingConfirmation = nil onConfirmationChanged(nil) }",
               "guard let outcome = await Self.outcome(of: verb, on: proposal, actions: actions)",
               "case .done(let updated, let sentence): notice = sentence",
               "onProposalChanged(updated)"],
              why: "a Finalize press mints the confirmation and stops; yes runs the verb DesignGateTests pins and draws its sentence and hands the proposal up; no clears the question (#120)"),
        Entry("type:DesignGateView", .anyOrder, ["if let notice { Text(notice)"],
              why: "the verb's sentence is drawn in the footer"),
        // The desk's verbs, in their homes (shell p4 Task 7).
        Entry("type:TreeEditionRows", .anyOrder,
              ["Button(EditionCastVerbs.addLanguageTitle) { MaughamEvent.postAddLanguage() }",
               "if mayAddLanguage {", "if row.isSource && mayAddLanguage { addLanguageItem }"],
              why: "the Editions `+` and the Source row's menu post the window's Add Language sheet, hidden where this Mac may not add one"),
        Entry("type:EditionWiring", .inOrder,
              [".onKeyWindowCommand(.maughamAddLanguage, window: window) { note in",
               "EditionCastVerbs.mayAddLanguage(documentStore: documentStore)",
               "addPrompt = EditionCastVerbs.addPrompt(",
               ".onKeyWindowCommand(.maughamShowEditionResolve, window: window) { _ in",
               "guard let row = Self.editionForTheKey(",
               "subject = ProjectWindow.facesForABrief(.edition(language: row.language), subject: subject)",
               "showToResolve()",
               ".focusedSceneValue(\\.editionKeyTitle,",
               "Task { landed(EditionCastVerbs.landing(await EditionCastVerbs.addLanguage(",
               "if let target = landing.select { select(target) }",
               "if let shown = landing.position { show(shown) }",
               "refusal = landing.alert",
               "ProjectWindow.selectPosition(shown, showInspector: $showInspector, position: $position)"],
              why: "Add Language presents the one sheet and lands where `EditionCastVerbs.landing` says (a new edition on To resolve or, from a proposal, its Brief; an existing one on its Brief; a refusal alerted); ⌘⌥K moves the faces to the edition it names and shows To resolve; the menu's title is that edition's"),
        Entry("type:BriefEditionView", .anyOrder,
              ["castPrompt = EditionCastVerbs.renamePrompt(language: language, in: store.manifest)",
               "castPrompt = EditionCastVerbs.designerPrompt(store: store)",
               "notice = await EditionCastVerbs.confirmRename(",
               "notice = EditionCastVerbs.cancelledLine(prompt)",
               "MaughamEvent.postAddLanguage(proposing: tag)",
               "confirmingDiscard = shown",
               "proposalNotice = await EditionCastVerbs.discardProposal("],
              why: "an edition's Brief changes its cast, the Source's its designer, and a proposed brief with no edition reaches Add Language and Discard"),
        Entry("type:ReviewRoundCockpit", .anyOrder,
              ["var letterInitiallyOpen = false",
               "LetterDisclosureRow(line: letterLine, disclosure: letterDisclosure, initiallyOpen: letterInitiallyOpen)"],
              why: "the letter's disclosure starts where ReviewRoundCockpitLetterScrollTests mounts it (#120); closed unless a host says otherwise"),
        Entry("type:LetterDisclosureRow", .anyOrder,
              ["@State private var isOpen: Bool", "_isOpen = State(initialValue: initiallyOpen)",
               "DisclosureGroup(isExpanded: $isOpen)"],
              why: "the open state lives with the letter's own branch, so a letterless chapter drops it"),
        Entry(window, .inOrder, ["selectTheProjectRow: {", "subject = ProjectWindow.leavingTheCanvasDim(subject)"],
              why: "the canvas's way out of the dim is the one rule"),
        Entry("decl:static func leavingTheCanvasDim(", .inOrder,
              ["subject.besideIsLatest && subject.beside?.treeSubject != nil", "next.faces = .project",
               "if dimsFromBeside { next.beside = nil }"],
              why: "the canvas's way out of the dim puts the faces on the Book, leaves the canvas the centre, and puts away what is pulled up only where that is what dims the board"),
        Entry("decl:struct PaletteWallModifier: ViewModifier {", .inOrder,
              [".onChange(of: subject) { old, new in",
               "paletteWall.applyPaletteWallChange("],
              why: "any subject change that takes `open` off the palette closes the wall, through the wall's one fold"),
        Entry("decl:private func closePaletteWall() {", .inOrder,
              ["paletteWall.closingWall(subject)", "Self.validatedSubject("],
              why: "the wall's own Close goes back to the subject it was opened over, repaired against the project"),
        Entry("decl:static func binding(subject: Binding<WindowSubject>,", .anyOrder,
              ["write(written, state: state, subject: subject, store: store)"],
              why: "every tree's `List` selection writes the window subject through the one setter"),
        Entry("decl:static func write(_ written: Set<TreeRowTag>, state: BinderTreeSectionsState,", .anyOrder,
              ["resolvedTags(", "projectType: store.manifest.type"],
              why: "the one setter resolves every write through the one rule"),
        Entry("decl:static func resolvedTags(", .anyOrder,
              ["resolved(", "settle: waits ? one : nil"],
              why: "a subject's tag is today's resolution, whose single-row arm is `ClickRule.resolve(_, .click, …)`; a fold row's tag selects and, from the keys, waits to settle (shell p4 Task 10 fix round 1)"),
        Entry("decl:enum TreeRowSettle {", .anyOrder,
              ["ClickRule.pullUp(pulled, current: subject)", "guard columnShowsPulledUp"],
              why: "a settled landing pulls up only where the column already shows the pulled-up position"),
        Entry("decl:struct TreeTravelModifier: ViewModifier {", .anyOrder,
              ["TreeTravel.openInCentre("],
              why: "a double-click on a tree row is the click rule's `.openInCentre`"),
        Entry(window, .anyOrder, ["TreeTravelModifier(window: window,", "subject: subjectBinding,"],
              why: "the double-click receiver is mounted on the window, over the window's subject"),
        Entry("decl:struct SubjectValidationModifier: ViewModifier {", .anyOrder,
              ["ProjectWindow.validatedSubject(subject, in: store)"],
              why: "the runtime sweep repairs the whole window subject with the restore's own function, written directly — never through the click rule"),
        Entry("decl:private var paletteSection: some View {", .anyOrder,
              ["DisclosureGroup(isExpanded: $state.paletteSectionExpanded)", "paletteRow",
               ".tag(TreeRowTag.subject(.palette))"],
              why: "the Palette row is the wall's door: the tree's `List` selects it (the tag is on its group), and the click rule opens the wall"),

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
        Entry(window, .anyOrder, ["bookTitle: store.manifest.title"],
              why: "the altitude and book mounts are handed the project's own name (with an edition's language), not a pane label"),
        Entry(window, .anyOrder,
              ["structure: store.manifest.structure", "passes: store.manifest.effectiveReviewPasses"],
              why: "the review board's mount passes the manifest's values"),
        Entry("decl:func statusBoard(", .anyOrder,
              [".task { refreshOpenNotes(store: store) }", ".onProjectEvent(.maughamAnnotationsChanged"],
              why: "the board recounts when it appears and when the project says its notes changed, through the scoped receive helper (ADR 0021)"),
        Entry("decl:func manuscriptEditor(", .inOrder,
              ["if let altitude {", "ProjectAltitudePane(", "statusBoard(store: store, structure: scope.structure)"],
              why: "the board is the altitude layer's Status view, handed to the pane by its one mount"),
        Entry(window, .anyOrder, ["editionView: editionView,", "preview: publishCentre.preview(for: subject.open)"],
              why: "the route is asked with the edition's own view and its own books; a default would show every edition the same book and never its Status"),
        Entry("type:PublishPreviewModifier", .anyOrder,
              [".onChange(of: centre.compileRunner.state)", "centre.compileSettled(from: old, to: new)"],
              why: "the window's compile settling is observed once, here; without it a refusal over the manuscript's problems covers nothing"),
        Entry("type:EditionStatusHost", .anyOrder,
              ["openQuestions: .init(byDoc: reading.openQuestions", "languages: [language]", "yieldsAndStops: true"],
              why: "the edition's Status hands its questions in from the presence read, so `documentRows` never reaches `withAnnotationDocument` (no chapter load), derives one language, and stops when superseded"),
        Entry("type:ResolvePresenceWatch", .anyOrder, ["state.bookReading = reading"],
              why: "the presence read publishes the book's questions and paragraph orders, which the edition's Status and book read instead of loading chapters"),
        Entry("type:ResolvePane", .anyOrder,
              ["? publishCentre.map { ResolveEditionItems.stoppingProblems($0.compileRunner.state) } ?? []",
               "publishCentre.show(problems: publishCentre.compileRunner.state.problems)"],
              why: "an edition's compile problems are the window's runner's own facts, and their Show is the centre's cover — never re-derived (shell p4 Task 6)"),
        Entry("decl:static func reviewCentreShowsBoard(", .anyOrder, ["altitudeView("],
              why: "the board's rule is the Book's view, asked of `altitudeView` rather than restated"),
        Entry("decl:static func altitudeView(", .anyOrder, ["subjectShowsAltitude("],
              why: "the Book's view composes the window's own document question"),
        Entry("decl:static func publishCentre(", .anyOrder, ["guard case .edition = subject.open"],
              why: "an edition's rule asks whether an edition is open, and nothing else decides it"),
        Entry("decl:static func selectPosition(", .anyOrder,
              ["showInspector.wrappedValue = true", "position.wrappedValue = asked"],
              why: "the one position-selection act shows the column and selects the position"),
        Entry("decl:onKeyWindowCommand(.maughamSetRightColumn, window: window) { note in", .inOrder,
              ["ProjectWindow.position(in: note.userInfo)", "ProjectWindow.selectPosition(",
               "ProjectWindow.positionAsk(", "if let request = ask.request { resolveRequest = request }",
               "if let field = ask.briefField { briefFocus = field }"],
              why: "the key-window receiver reads the position the post names, calls the shared act, then hands To resolve its filter wherever its list is what shows (never left to fire later over the review), and hands Brief ⌘⌥I's or ⌘⌥N's field"),
        Entry("decl:onKeyWindowCommand(.maughamPullUp, window: window) { note in", .inOrder,
              ["ProjectWindow.pullUpRequest(in: note.userInfo)", "ProjectWindow.pullUp("],
              why: "⌘⌥G/Y/V/H reach the one pull-up act; without the receiver four menu items do nothing"),
        Entry("decl:static func pullUp(_ request: PullUpRequest,", .inOrder,
              ["pullUp(RightColumnContent.pulledUp(", "subject: subject, showInspector: showInspector, position: position,"],
              why: "a key's pull-up asks the one table what the request names and goes through the one act"),
        Entry("decl:static func pullUp(_ item: PulledUp, subject: Binding<WindowSubject>,", .inOrder,
              ["ClickRule.pullUp(item, current: subject.wrappedValue)",
               "memory?.pulledUp()",
               "showInspector.wrappedValue = true", "position.wrappedValue = .pulledUp"],
              why: "the one pull-up act puts the item beside through the click rule, shows it over a standing canvas selection, and shows the column on it — also when it was already beside, which no observer sees"),
        Entry("decl:func pullUpItem(_ item: PulledUp)", .anyOrder,
              ["Self.pullUp(item, subject: subjectBinding, showInspector: $showInspector, position: $rightColumnPosition, memory: pulledUpMemory)"],
              why: "Brief's pull-up links are the keys' own act"),
        Entry(window, .anyOrder,
              [".modifier(ResearchRevealModifier(subject: subjectState, showInspector: $showInspector, position: $rightColumnPosition, previousFace: $previousFace,",
               ".modifier(PulledUpEscapeModifier(", "showStrain: { showStrain($0) }", "openBrief: { openBrief($0) }",
               "pullUp: { pullUpItem($0) }", "briefFocus: $briefFocus",
               "openInCentre: { openInCentre($0) }", ".modifier(EditionWiring("],
              why: "the subject's observer (the position after a change, the reveal, the remembered position) and Esc's claim are each one mount line; the column is handed the window's verbs for a mark's jump, a Brief link and Open in Centre"),
        Entry("type:RightColumn", .anyOrder,
              ["RightColumnControl(", "switch shown {", "ResolvePane(",
               "publishCentre: publishCentre,",
               "readIn: ReadingLanguage.of(subject: subject, switched: editorControl.translationLanguage, sourceLanguage: publishCentre.sourceLanguage),",
               "editorControl: editorControl,", "presenceMarks: figureTree?.presence)",
               "BriefPane(", "PulledUpView(",
               "onPullUp: pullUp,",
               "onShowStrain: showStrain", "onOpenBrief: openBrief",
               "onShowNotes: { _ in position = .resolve }",
               "canvasDetails: { AnyView(canvasInspector(store: store)) }",
               ".task { await documentStore.inboxStore.refresh() }",
               ".onChange(of: editorControl.translationLanguage) { _, lang in if lang != nil { position = .resolve } }"],
              why: "the column is the control over one switch whose arms mount every position's view (To resolve given the window's publish centre for an edition's list); Brief's links, the edition's Open the desk, a figure's Show notes and the canvas's details each reach their verb, To resolve is handed the reading language (a piece read in a language lists that language's — the one answer ⌘⌥K reads), the editor's control and the tree's marks, reading in a language shows To resolve, and the inbox is read at window open (the picker's old job) so the tree's Inbox row is drawn"),
        Entry("type:ResearchRevealModifier", .anyOrder,
              ["RightColumnContent.positionAfterSubjectChange(", "if Self.reveals(from: previous, to: next) { showInspector = true }",
               "documentStore?.updateUIState { $0.rightColumnPosition = new }",
               "previousFace = Self.previousFace(previousFace, after: new)"],
              why: "a subject change moves the position and an arrival shows the column; the position is remembered and the face before the pulled-up one kept"),
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
        Entry("type:EditionHeadView", .anyOrder,
              ["@Environment(AgentRoster.self)",
               "EditionHeadVerbs.production(roster: roster, store: store, documentStore: documentStore)"],
              why: "an edition's head reaches its verbs through the roster the window injects"),
        Entry("type:EditionHeadVerbs", .anyOrder,
              ["await TranslationRunStart.startBookRun(",
               "pipeline.runBook(documentIds: documentIds, language: language)",
               "designer.runDesign(direction: direction, language: nil)",
               "DesignRoundState.sendChanges(words, to: designer)",
               "designer.cancel()", "roster.pipeline.cancel()", "roster.translator.cancel()"],
              why: "an edition's head reaches the translator's pipeline and the designer through the roster the window injects — the desk's Run Whole Book, its cast sheet's run, the design round, Request Changes and both Cancels, moved (shell p4 Task 6)"),
        Entry("type:ResolvePane", .anyOrder,
              ["TranslationRoundActions.production(", "DesignGatePromotion.approve(",
               "DesignGatePromotion.discard(proposal, projectURL: projectURL)",
               "onShowRound: { publishCentre?.show(round: $0) }",
               "onShowProposal: { publishCentre?.show(proposal: $0) }",
               "publishCentre?.adoptVerbAnswer($0)", "onFiled: { filed($0) }",
               "onRoundChanged: { roundChanged($0) }",
               "editionRead = ResolveEditionItems.patching(editionRead, with: updated)",
               "publishCentre?.adoptVerbAnswer(updated)"],
              why: "an edition's rows act through the round report's verbs and the gate's, say where an answer was filed, patch the list and the centre's report with the round as written, and their Shows reach the centre"),
        Entry(window, .anyOrder,
              ["designGateActions(", "onProposalChanged:", "DesignGatePromotion."],
              why: "the gate is given wired verbs that run through the one performer, and the window takes the refreshed proposal back"),
        Entry(window, .anyOrder, ["DesignRoundState.sendChanges"],
              why: "the gate reaches requestChanges' one spelling rather than composing its own"),
        Entry("type:EditionHeadVerbs", .anyOrder, ["DesignRoundState.sendChanges"],
              why: "the Source edition's head reaches the same spelling"),
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
