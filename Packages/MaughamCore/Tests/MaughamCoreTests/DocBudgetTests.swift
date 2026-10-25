import XCTest

/// **The docs' budgets** (foundations audit 2026-10-17, D1/D5). CLAUDE.md is
/// loaded into every session and every subagent; an AREA.md must be read
/// before its directory is edited. Both grew without limit because nothing
/// measured them. These ceilings RATCHET: a task that cuts a doc lowers its
/// number in the same commit, and no number is ever raised without a reason
/// written beside it.
final class DocBudgetTests: XCTestCase {

    /// Repo-relative path → the most words it may hold.
    static let wordCeilings: [String: Int] = [
        "CLAUDE.md": 3_093,  // ratchet: actual size; the hard cap is 4,000 words (foundations plan 1) — raise only with a reason. +10 #114 F16/F37: rows 3 and 6 name their EditorHost censuses, rows 42 and 56 say "(core tests)"; +33 report plan 6b: tripwire row 58, the synced-path census (Denver); +20 batch H (#59): tripwire row 57, the canvas load() closure census; +19: the Maugham/Models row names its two real guides (final fix wave); +92 at the foundations merge: tripwire rows 54–56 (plans 6/7's censuses), the type-keyed census line, AgentRoster in the Compiler row; −1 plan 5 final-review fixes: the trash is not under `.maugham/` (it is `<project>/.trash/`, TrashStore.trashRoot), so it leaves the derived list
        "docs/tripwires.md": 7_727,  // ratchet: actual size; +75 #114 F16/F29: rows 3 and 6 name their EditorHost censuses, row 56 the type-level pin, row 57 its any-receiver scan and its dependency on 32; +13 #114 T1 review: row 9 names TapGesture(, the row types and TreeTravelGestureAttachmentTests' census; +60 #114 F22/F24/F26: rows 1, 5, 9 and 18 name their new censuses, row 13 its widened one, row 15 the VStack half it now enforces; +8 canvas-keyboard-flow T8: row 32's repro double-clicks the chrome bar away from the region's title, which a double-click now renames; +42 report plan 6b Task 2 fix round 2: row 58 names the change-form census and the non-following creations; +71 report plan 6b Task 2 fix round 1: row 58 splits read (lexical) from change (folder chain on disk), names id names and the reasoned marker; +200 report plan 6b Task 2: row 58 (a synced path reaches a file call only through SafeRelativePath, its derived census and known limit); +6 report plan 6a Task 8 fix round 1: row 52 names the figure op's `Op(…, figure:)` rather than the payload; +76 report plan 6a Task 8: rows 20, 38 and 52 each name how their census reaches figures; +28 canvasview-split final review: the census-key paragraph says the canvas surface list is derived and checked, and row 57 says the construction census checks that a holder schedules no work; +24 canvasview-split T5: row 32 says "the canvas surface" and names the construction census and the windowless refusal; +38 canvasview-split T3 review: row 57 says a held helper is frozen for work its holder schedules, and names `@State` capture; +6 canvasview-split T2 review: row 57 says the helpers are built only in a computed property; +64 canvasview-split T2: row 57 names the layoutPass replay, the planted helper case and how the surface helpers escape its known limit; +7 batch I (#102 SW5): row 53 names the phone-side no-mint twin; +36 batch H (#59) final review: row 57 names the stored-closure hook it now catches and the local-capture shape it does not; +56 batch H (#59) review fixes: row 57 states its known limit and the walk's extension/method-reference reach; +143 batch H (#59): row 57 (load()'s closures read no plain view property, #57's class); +485 at the foundations merge: rows 54–56, the census-key paragraph, rows 17/24/39/46 name the OpLogStore split's homes; −17 plan 5 T9: rows 37–48 drop the old OpLog area-tripwire numbers
        "docs/testing/TROUBLESHOOTING.md": 4_406,  // ratchet: actual size; +28 over 4,378 for the line naming the old CLAUDE.md phrases comments still cite
        "docs/INDEX.md": 454,  // ratchet: actual size (Core and Publish guides and the recipes line added); +6: Stores line names the project session; +15: the docs/history line (plan 5); +37 plan 5 final-review fixes: the cross-guide routing sentence (Core → OpLog Rules, Outside-this-folder lists point back)
        "Maugham/Canvas/AREA.md": 7_951,  // ceiling held (actual 7,948): +30 canvas-keyboard-flow whole-branch review, three rules (a dimmed selected card is no selection; a key-placed scrap keeps out of foreign regions and off its home edge; a title takes the keyboard from no other text view) and the offer row names Tab then Return, net of seven why-clauses to docs/history/canvas.md's "Moved from the guide by the canvas-keyboard-flow whole-branch review"; Task 9 (actual 7,918): −27 canvas-keyboard-flow T8, fifteen why-clauses to docs/history/canvas.md's "Moved from the guide by canvas-keyboard-flow Task 8", net of the RegionTitleEditorHost.swift and CanvasRegionTitleEditing.swift Map rows, the one-editor-slot rule and the region repro's "away from its title"; +10 canvas-keyboard-flow T7, the keyboard-request rule names the binder's Tab and ⇧Tab; −16 canvas-keyboard-flow T6, ceiling held so Tasks 7 and 8 have room: seven why-clauses to docs/history/canvas.md's "Moved from the guide by canvas-keyboard-flow Task 6", net of the canvas-keys rule and handleCanvasKey/onKey on the CanvasKeyHandler and CanvasEventView Map rows; +69 canvas-keyboard-flow T5: the in-scrap keys rule and the keyboard-request rule, and the ScrapEditorHost, CanvasKeyHandler and CanvasEventView Map rows name onCommand, handleEditorCommand and serveKeyboardRequest; +1 canvas-keyboard-flow T4 review: reveal(_:viewSize:) named on the CanvasCamera row; +14 canvas-keyboard-flow T4: the CanvasKeyboard.swift Map row; +15 canvas-keyboard-flow T3 review: the drop routes birth a picture at its header height; +38 canvas-keyboard-flow T3: the CanvasDropWrap.swift Map row, the wrap-joins-only-dropped-items rule under Creation absorbs, the capture placement renamed; +87 canvas-keyboard-flow T2: the CanvasScrapFlow.swift Map row, the creation-binding rule in The dim, the CanvasClickHandler row says it holds scrapFlow; +80 canvas-keyboard-flow T1: the one-drop-modifier Routes rule, the CanvasDropRoute.swift Map row, and the CanvasDropHandler row names the one entry; −274 canvas-keyboard-flow T0 (net of two rule sentences restored in review): 28 why-clauses to docs/history/canvas.md's "Moved from the guide by canvas-keyboard-flow Task 0", and the Routes drop-order sentence (the reverse of CanvasView.body) deleted, to leave room for the keyboard flow's Map rows and rules; +3 canvasview-split final review: the helpers are "never stored by the view" (a handler does hold one it was handed); +47 canvasview-split T7: the Ownership rule for the per-call helpers (built only by CanvasView's computed properties, never stored, never given $sceneRevision) with its two censuses, and the CanvasView.swift Map row, a rule, a recipe and the bracket rule naming each handler's new home; +31 canvasview-split T6: Map row for CanvasDropHandler.swift; +16 canvasview-split T5: Map row for CanvasKeyHandler.swift; +19 canvasview-split T4: Map row for CanvasClickHandler.swift; +22 canvasview-split T3: Map row for CanvasDragHandler.swift; +38 canvasview-split T2: Map rows for CanvasLayoutPass.swift and CanvasEditFocus.swift; +11 canvasview-split T1 review fixes: the Claude-card straighten keeps its provenance clause (+8), the raw hide-modifier scan names the whole surface (+3); −258 canvasview-split T1: narrative to history, room for six Map rows (19 why-clauses to docs/history/canvas.md's "Moved from the guide by canvasview-split Task 1"); +10 batch H (#59): the model-held-closure bullet states why (the VALUE capture) and names tripwire 57, net of a 12-word trim; +27 batch F (#88): the `.unreadable` refusal rule; plan 5: re-templated, +271 review fixes (47,971 → 7,681 → this; tripwire 33, split bullets, narrative-only rules), +3 T9: the Stores pointer names its sections; the narrative is in docs/history/canvas.md
        "Maugham/OpLog/AREA.md": 7_994,  // +20 report plan 6c final fix wave: two rules back from docs/history/oplog.md (declareActorOnce runs on the store's own actor; a refused displacing record about this device records its key as a claimant), and the figure restore skips a figure parked or resumed since the pointer, net of tightening that rule; −25 report plan 6c Task 6: the Figures rules gain the figure restore (ordinary ops, the park-cycle pin rule, .partlyRestored), net of nine why-clauses moved to docs/history/oplog.md; +6 report plan 6b final re-review: the resume names its park, so a stale return folds nothing; +2 report plan 6b final fix wave: the Figures rules say a figure edit claims its piece (revised R-D4) and a return's ops name their resume (`returnOf`), and cite base(of:streams:frontier:), net of the minting why-clause moved to docs/history/oplog.md; −9 report plan 6b Task 10: the Figures rules (a figure follows its piece's posture with both starter arms, parked folds nothing, minted after the newest folded op, the three-way return, figure undo) and the FigureDocument row pointing at them, net of nineteen why-clauses and stated limits moved to docs/history/oplog.md; +1 report plan 6b Task 9: the FigureDocument row names refreshPins's one-visit ⌘Z, net of "not `Document`" (the slack the 8,000 cap held); +1 report plan 6b Task 8: the FigureDocument row says the return runs while parked; −1 report plan 6b Task 7: the FigureDocument row says a parked figure refuses, net of naming FigureEditRefused; +3 report plan 6a Task 8: the FigureDocument row names tripwires 38 and 52; -1 report plan 6a Task 7: the Map names FigureRender and the checkpoint bullet says a figure stream gets a pointer, net of tightening that bullet; +3 report plan 6a Task 6: the Map names FigureDocument, net of the load seam's Task.yield measurement (already in docs/history/oplog.md) and the load-path recipe's restated suspension clause; +9 batch G (#84): the automations bullet names appendLifecycleOp(automation:) and the repair waiting for a claimed piece; plan 5: re-templated (30,412 → this), +228 review fixes (each tripwire names its census, the load's suspension points); the narrative is in docs/history/oplog.md
        "Maugham/Views/AREA.md": 7_997,  // ratchet: actual size, at the 8,000-word cap; +4 report plan 6c Task 6: the PartialRestorePicker row says a project revert winds back the book's figures, net of four why-clauses moved to docs/history/views.md; −2 canvas-keyboard-flow T7 review: the hand-off rule names binderTakesTheKeyboardBack, tightened; −1 canvas-keyboard-flow T7: four why-clauses to docs/history/views.md, net of TreeCanvasKeyboard on the BinderView Map row and the Tab hand-off rule; the Map names ReportSettingsSection and ReferenceIndexHost, and the rules carry New Project and the Report settings section; displaced reason clauses live in docs/history/views.md
        "Maugham/Compiler/AREA.md": 7_891,  // −1 batch G (#83) ratchet; plan 5: re-templated, +117 review fixes (23,782 → 7,741 → 7,858; confinement of a raw spawn, the cross-lane count’s one site, window hand-off), +34 the process-launch census rule; the narrative is in docs/history/compiler.md
        "Maugham/Stores/AREA.md": 7_988,  // −1 report plan 6c final fix wave: six rules back from docs/history/stores.md (a non-person key is never offered; the closed held-lines pass lands nothing if the epoch moved; the single-item moveResearchItem uses the same plan builder; afterStaging: cannot throw; a derive-only read of a promoted piece answers ""; the three live [weak self] instances by name), the promotion rule says what stays reads is copied, grouped Research travels and a moved figure parked outside the piece refuses, net of tightening that rule and the withFigureHost row and the provenance re-stamp's why-clause moved to docs/history/stores.md; −8 report plan 6c Task 6: withFigureHost on the DocumentStore+Figures row, PiecePromotion on the CollectionPieces row and the promotion-carries-figures rule, net of twelve why-clauses moved to docs/history/stores.md; +5 report plan 6b final fix wave: the header and Pointers name tripwire 58 (Task 10 review), the ProjectStore+Figures row says a parked figure is not renamed and a removal always trashes the record, and the Map names ProjectStore+FigureTranslations, net of the device-key why-clause moved to docs/history/stores.md; −1 report plan 6b Task 10: the figure rows name assembledFigures, pinSources, the restore of a removed figure, bringBack's two outcomes and pinSourceRead, ResearchKindInference names the table kind, the starter yield reaches a figure, and the figure text-hold rule, net of eight why-clauses moved to docs/history/stores.md; +10 report plan 6b Task 8 review: the layout row says a parked picture's copy gets a sidecar naming its figure; −6 report plan 6b Task 7: the FigureResearch row names sendToResearch, the Annotations row's why-clause moved to docs/history/stores.md; −10 report plan 6b Task 6 review: the Map names ProjectStore+FigureResearch (useInDocument moves there from the figures row), two why-clauses moved to docs/history/stores.md; +5 report plan 6b Task 6: the ProjectStore+Figures row names useInDocument (re-worded tighter to stay under the 8,000 cap), and the layout table names .maugham/research-tables/; +17 report plan 6b Task 5: the ProjectStore+Figures row names renameFigure (every door first, then the relabel, ruling P-3) and removeFigure, and the TrashSubject list names priorVersion and figure; +6 report plan 6b Task 2 fix round 1: the rule names resolvedProjectPathToChange; +33 report plan 6b Task 2: the rule that a synced path reaches a file call only through resolvedProjectPath (tripwire 58); +12 report plan 6a Task 9: the ProjectStore+Figures row names createImageFigure, which copies the picture into figures/ and writes its hash; +3 report plan 6a Task 8: the ProjectStore+Figures row names tripwire 52, and the verb recipe asks posture for a figure's content too; +31 report plan 6a Task 7: the Map names DocumentStore+Figures (openFigure, the presenter's figure pass, renderFigures, the trust drop); +29 report plan 6a Task 6 (fix round 1: stream before record): the Map names ProjectStore+Figures and createFigure; +14 report plan 4 final fixes (M6): turning a Report's profile off writes the project's title over an "Untitled" config; +8 report plan 4 final fixes: the sent-copy row names the draft-led export id carried in the file and that sent copies are backed up (R-S8, R-S9); +24 report plan 4 Task 8: the Map names ProjectStore+Profile, the profile and switches door, and its profileNotOffered refusal; +22 report plan 4 Task 7: the ProjectFactory row names the Report in either prose shape (profile only) and the profileNotOffered refusal; +41 report plan 4 Task 5: the Map names SentCopyStore and the layout table gains the .maugham/exports/ row (a Word export as sent, its id, out of the backup signature); +17 report plan 3a T3: the Map names ProjectStore+Citation, the citation door; +5 batch I (#103) (the edit added 7 words; 2 were prior slack): the open keeps a changed person key on personKeyChanged; +30 report plan 1 T6: the manifest-door rule; +56 batch F (#92, #90): the manifest.shadow.json layout row, restored-copy identity and the shared ⌘S/⌘⇧S backup call; plan 5: re-templated, +285 review fixes (16,389 → 7,343 → this; tripwires 49/50, inbox promote order, backup-signature step); the narrative is in docs/history/stores.md; +18 final-review fixes (the bible sidecar row, the layout's two exceptions; runtime names un-backticked so the guide joins pathCheckedDocs)
        "Maugham/MCP/AREA.md": 6_069,  // +56 report plan 4 Task 6: list_projects and get_metadata name `kind` in the catalogue, and a Project-reads contract says `kind` comes from ProjectKindName while `type` stays the raw id, with get_metadata's profile, switches and switch_overrides; +28 report plan 4 Task 2: a Publishing rule says every tool's format enum derives from PublishConfig.Format.allCases (MCPFormatEnum), preview_compile's less what the preview refuses; +75 report plan 3a T3: update_research_citation in the Map, the catalogue (61) and the membrane bullet, its contract, and list_research names its citation; +7 report plan 2 Task 8 fix round 1: a problem names its edition (`language`); +30 report plan 2 Task 7: dry_run names the publish-problem gate, and a publish problem carries its ids on the wire; plan 5: re-templated, +193 review fixes (8,687 → 5,651 → this; permit via PostureDoor, tripwire test names, task-op and tripwire 52 censuses), +1 T9: the OpLog pointer names its section; the narrative is in docs/history/mcp.md; +28 final-review fixes (the membrane bullet names the publishing and propose tools' destinations)
        "MaughamPhone/AREA.md": 4_163,  // plan 5: re-templated, +130 review fixes (5,007 → 4,033 → this; tripwires 37–41, 54, 55); the narrative is in docs/history/phone.md
        "Maugham/Editor/AREA.md": 4_381,  // +2 report plan 6a Task 9: the FigureIngest Map line says image figures land in figures/ through createImageFigure; +29 report plan 3b final fixes (I2, I1): the cached-index rule says what runs where (tokens from one ops listing and the parse off the main thread, a moved piece's derive on it) and that a label-minting command walks before the first build; +67 report plan 3b Task 6: the Map names ReferenceLabelOverlay and ManuscriptChecks, and the rule that labels and problem underlines are display-only on a manuscript (checks at the settle, a whole-document paint or a new index version, never per keystroke; underline temporaries only, never the dimming's; publishing's severity and words) (+98), net of the figure thumbnail's burst-lag sentence moved to docs/history/editor.md (−31); +76 report plan 3b Task 5: the +Tables Map line names Edit Table… and tableEditor, and the rule that the table grid saves onto the table it opened on or not at all (host-presented sheet, TableAnchorTracker, refusal sentence, delimiter-row double-click only); +18 report plan 3b Task 4: the Map names CrossReferenceCompletion; +21 report plan 3b Task 3: the Map names CitationCompletion; +17 report plan 3b Task 2 fix round 1: the completion rule names the paste/drop and unclosed-code exclusions and a trigger running past the caret; +111 report plan 3b Task 2: the Map names EditorCoordinator+Completion and CompletionListView, and the rule that the completion list is the one in-editor picker (keys first in doCommandBy only while open, complete: swallowed, typed-character trigger, Route A accept, the eight close paths), replacing "character autocomplete is intentionally absent" (moved to docs/history/editor.md); +53 report plan 3b Task 1 fix round 1 (I2): the D1 ruling that a settle-edge version counter whose values stay behind a provider may live in EditorControl, naming referenceIndexVersion, and that its repaint stays visible-range or temporary attributes; +84 report plan 3b Task 1: the Map names ReferenceIndex, and the rule that project-wide references come from one cached index built off the main thread, never a walk or a per-keystroke build; +168 report plan 3a final fixes: three "Commands that write text" rules (a deferred edit never takes the focus or a moved-on writer's selection and waits out a composition; no offset against stale tokens, the table anchors ride every edit; inserts go to the focused editor) and the trailing-figure room read from the text and re-asserted, the decode bucket; +100 report plan 3a Task 8: two rules, an insert acts on a manuscript only (InsertMenuGate and the membrane) and the prose tokenizer's budget is a scaling ratio, never a wall clock; +55 report plan 3a Task 7 fix round 1: a figure on the last line gets its room from the text view's height, and the space and thumbnail can disagree until the deferred settle; +91 report plan 3a Task 7: the Map names FigureThumbnailOverlay, and the rule that a figure's thumbnail is a decoration whose room is a text-derived paragraph spacing set only by EditorHost, decoded off the main thread and cached; +103 report plan 3a Task 6 fix round 1: a command closes its own undo group outside an event, a mixed drop or text paste keeps today's behaviour on purpose, the Figure… panel runs from the coordinator (recipe exception); +86 report plan 3a Task 6: the Map names FigureIngest and EditorCoordinator+Figure, and the rule that a figure drop or paste never reaches super, asks the membrane before the copy and lands at the carried point; +63 report plan 3a Task 5: the Map names EditorCoordinator+Tables, and the rule that a table tidies only on Tab, Return or leaving, never mid-keystroke or on an undo; plan 5: re-templated, +151 review fixes (3,673 → 3,012 → this; TokenRestyleWindow is test-only, ResearchNoteEditor owns an EditorControl, the scroll-snap premise), −25 T9: the "Editor AREA tripwire 9" bridge line dropped (comments re-pointed); the narrative is in docs/history/editor.md; +20 final-review fixes (tripwire 54's bullet); +79 report plan 3a Task 4 (two new files on the Map, and the "Commands that write text" rules: Route A for commands, and the one host that makes a surface answer the Insert menu)
        "Maugham/Updates/AREA.md": 3_997,  // plan 5: re-templated, +5 review fixes (4,089 → 3,992 → this); the narrative is in docs/history/updates.md
        "Maugham/Publish/AREA.md": 3_573,  // ratchet: actual size; +4 report plan 6a Task 9: FigureImageResolver accepts figures/ beside research (Map line and the one-path-door rule); +5 report plan 4 final fixes (I2, M6): every compiler asks reportTitled, not PDFCompiler alone; +38 report plan 4 final fixes: a Word file is never republished (R-S8), it carries its export id, and an edition renders a version, never a draft (C1); the Map names the Word compiler, package, bookmark names, zip and draft files, and the rules say a Word export is a draft, the zip is Swift, figures rasterise before emission and dry_run cannot see a figure that fails to
        "Packages/MaughamCore/Sources/MaughamCore/AREA.md": 4_726,  // +24 report plan 6c final fix wave: the FigureRestoreDiff row names wentToResearch(since:in:), the FigureCarry row readByWhatStays and stayingReadsOfCarriedResearch; +38 report plan 6c Task 6: the FigureRestoreDiff row says changes takes the parks (a live pin is never replaced by an inert one) and the FigureCarry row names canRecreate and the listed pictures; +40 report plan 6c Task 4: the Map names FigureCarry; +31 report plan 6c Task 1: the Map names FigureRestoreDiff; +1 report plan 6b final fix wave: the PinStatus row names the unpinned status (final review I-1); +49 report plan 6b Task 10: the Permit row names startersPiece(of:), the ResearchItem row its AssetKind and table, the tripwire 58 rule, and the Pointers name row 58; +10 report plan 6b Task 9 review: the PinStatus row names FigurePinChoice, the one pin rule; +47 report plan 6b Task 9: the Map names PinStatus, the FigureCache row says pins are indexed, the FigureInverse row names pin; +26 report plan 6b Task 8: the Map names FigureReturnDiff and FigureReturnMatch; +2 report plan 6b Task 7: the FigureDeriver row says parked folds nothing; +32 report plan 6b Task 6: the Map names ResearchTableSidecar; +2 report plan 6b Task 4: the FigureInverse row names delete and revive; +37 report plan 6b Task 3: the Map names FormulaNames, the Formula row says figures and research items are stored by id, and the FigureCache row says the workbook is keyed by figure id with parked figures assembled and listed; +7 report plan 6b Task 2 fix round 1: the SafeRelativePath row names resolveForChange; +11 report plan 6b Task 2: the SafeRelativePath row says resolve checks the disk and names tripwire 58; +37 report plan 6b Task 1: the Map names ContentHash and the SafeRelativePath row names its three new checks; +29 report plan 6a Task 4: the Map names FigureCache; +56 report plan 6a Task 3: the Map names FigureDeriver and FigureInverse; +28 report plan 6a Task 2: the Map names FigureRecord; +30 report plan 6a Task 1: the Map names FigureOp; +33 report plan 5 Task 9: the Map names TableCSV; +27 report plan 5 Task 8: the Map names CellInput; +52 report plan 5 Task 7: the Map names TableLocale and CellDisplay; +56 report plan 5 Task 6: the Map names DependencyGraph and Workbook; +36 report plan 5 Task 5: the Map names DateSerial and DateFunctions; +26 report plan 5 Task 4: the Map names FinanceFunctions; +51 report plan 5 Task 3: the Map names FormulaEvaluator, FormulaFunctions and ExcelRounding; +43 report plan 5 Task 2: the Map names CellAddress and FormulaParser, and the Formula row says what the tree stores; +77 report plan 5 Task 1: the Map gains the Tables and formulas heading and its five rows; +5 report plan 4 Task 7: the ProjectKindName row names of(profile), the Report choice; +27 report plan 4 Task 6: the Map names ProjectKindName and its census, and the ProjectType recipe names it beside the capabilities (NewProjectSheet's label(for:) no longer switches); +13 report plan 3b T5: the Map names TableClipboard; +11 report plan 3a T5: the Map names TableText; +48 report plan 2 Task 9: the Add a manuscript element recipe's publish step names the real files; +18 report plan 2 T1: the Map names CitationStyle; +13 report plan 1 final fixes: the recipe's step 3 says nothing consumes the layer yet; +106 report plan 1 T6: the manifest-door rule and the Add a manuscript element recipe; +24 report plan 1 T5: the Map names ProjectProfile and encodeForDisk; +16 report plan 1 T4: the Map names CitationInfo; +26 report plan 1 T3: the Map names ManuscriptInlineScanner and ManuscriptIndex; +28 report plan 1 T2: the Map names ManuscriptBlocks and ManuscriptLabel; plan 5: +108, Pointers filled (tripwire rows, tests, neighbours); +28: Statement.Kind recipe gains the Persona.panes and one-writer-census steps; +206: the OpLogStore split's six files, DocumentFormat, ProjectType+Capabilities, the ProjectType recipe rewritten for capabilities; +260 plan 5 final-review fixes: each op-log/trust/permit/person-key Map heading and the first Rules bullet route to the OpLog guide's Rules, every tripwire bullet names its census, tripwire 50's bullet
    ]

    /// Repo-relative path → the longest line it may hold, in characters.
    /// A single 15,000-character bullet cannot be skimmed or cited.
    static let lineCeilings: [String: Int] = [
        "CLAUDE.md": 515,  // ratchet: actual size; the hard cap is 1,000 characters (foundations plan 1) — raise only with a reason
        // Every area guide: the same 1,000-character cap as Core's (plan 5 final-review fixes).
        "Packages/MaughamCore/Sources/MaughamCore/AREA.md": 1_000,
        "Maugham/Canvas/AREA.md": 1_000,
        "Maugham/OpLog/AREA.md": 1_000,
        "Maugham/Views/AREA.md": 1_000,
        "Maugham/Compiler/AREA.md": 1_000,
        "Maugham/Stores/AREA.md": 1_000,
        "Maugham/MCP/AREA.md": 1_000,
        "MaughamPhone/AREA.md": 1_000,
        "Maugham/Updates/AREA.md": 1_000,
        "Maugham/Editor/AREA.md": 1_000,
        "Maugham/Publish/AREA.md": 1_000,
    ]

    /// Docs whose backticked file names must name a file that exists.
    static let pathCheckedDocs: [String] = [
        "CLAUDE.md",
        "docs/INDEX.md",
        "docs/testing/TROUBLESHOOTING.md",
        "docs/tripwires.md",
        "Packages/MaughamCore/Sources/MaughamCore/AREA.md",
        "Maugham/Canvas/AREA.md",
        "Maugham/OpLog/AREA.md",
        "Maugham/Views/AREA.md",
        "Maugham/Compiler/AREA.md",
        "Maugham/Stores/AREA.md",
        "Maugham/MCP/AREA.md",
        "MaughamPhone/AREA.md",
        "Maugham/Updates/AREA.md",
        "Maugham/Editor/AREA.md",
        "Maugham/Publish/AREA.md",
    ]

    /// Docs that must carry no milestone tag (a rule outlives the milestone
    /// that made it; the tag is history and belongs in git or an ADR).
    static let untaggedDocs: [String] = [
        "CLAUDE.md",
        "docs/INDEX.md",
        "Packages/MaughamCore/Sources/MaughamCore/AREA.md",
        "Maugham/Canvas/AREA.md",
        "Maugham/OpLog/AREA.md",
        "Maugham/Views/AREA.md",
        "Maugham/Compiler/AREA.md",
        "Maugham/Stores/AREA.md",
        "Maugham/MCP/AREA.md",
        "MaughamPhone/AREA.md",
        "Maugham/Updates/AREA.md",
        "Maugham/Editor/AREA.md",
        "Maugham/Publish/AREA.md",
    ]

    /// Guides already in the template (Map / Rules / Recipes / Pointers).
    /// Plan 5 adds each area's guide here as it is re-templated.
    static let templatedGuides: [String] = [
        "Packages/MaughamCore/Sources/MaughamCore/AREA.md",
        "Maugham/Canvas/AREA.md",
        "Maugham/OpLog/AREA.md",
        "Maugham/Views/AREA.md",
        "Maugham/Compiler/AREA.md",
        "Maugham/Stores/AREA.md",
        "Maugham/MCP/AREA.md",
        "MaughamPhone/AREA.md",
        "Maugham/Updates/AREA.md",
        "Maugham/Editor/AREA.md",
        "Maugham/Publish/AREA.md",
    ]

    /// Guides still over the hard cap, awaiting their re-template. Shrinks to
    /// empty by the end of plan 5; a member at or under the cap fails the
    /// census so the set cannot go stale.
    static let notYetTemplated: Set<String> = []

    static let areaGuideHardCap = 8_000

    // MARK: - Helpers (pure; the planted controls below exercise them)

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // MaughamCore/
            .deletingLastPathComponent()   // Packages/
            .deletingLastPathComponent()   // repo root
    }

    static func read(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func longestLine(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count).max() ?? 0
    }

    /// Every `AREA.md` in the repo, found by walking from `repoRoot`. Skips
    /// hidden directories (`.git`, `.superpowers`, `.claude`, `.build`…),
    /// build products, and worktree copies.
    static func areaGuides(under root: URL) -> [String] {
        let skipped: Set<String> = ["DerivedData", "build", "node_modules", "worktrees", "Maugham.xcodeproj"]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if name.hasPrefix(".") || skipped.contains(name) || name.hasPrefix("Maugham-") {
                    walker.skipDescendants()
                }
                continue
            }
            if name == "AREA.md" {
                found.append(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        return found.sorted()
    }

    /// The problem with a guide's headings, or nil when `## Map`, `## Rules`,
    /// `## Recipes`, `## Pointers` each appear as a heading line, in that order.
    /// Lines inside a ``` fence are code, not headings, and are dropped first.
    static func templateProblem(in text: String) -> String? {
        var inFence = false
        let headings = text.components(separatedBy: "\n").filter { line in
            if line.hasPrefix("```") { inFence.toggle(); return false }
            return !inFence && line.hasPrefix("## ")
        }
        var from = headings.startIndex
        for want in ["## Map", "## Rules", "## Recipes", "## Pointers"] {
            guard let at = headings[from...].firstIndex(of: want) else {
                return headings.contains(want)
                    ? "\(want) is out of order" : "\(want) is missing"
            }
            from = headings.index(after: at)
        }
        return nil
    }

    /// `Task 4`, `P3a`, `P3c plan 2`, `plan 1`, `fix round`, `M4`, `M1A`, an ISO date.
    /// Text inside backtick spans is ignored: a dated file path is a pointer, not history.
    static func milestoneTags(in rawText: String) -> [String] {
        let text = rawText.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        let pattern = #"\bTask \d+\b|\bP\d[a-c]?\b|\bM\d[A-Z]?\b|\bplan \d+\b|\bfix round\b|\b20\d\d-\d\d-\d\d\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// Every `` `…something.ext` `` (swift, md, yml, sh, json) that names no
    /// file. With a `/`, the token is repo-relative and must exist exactly; a
    /// bare name must exist somewhere under the searched roots. Tokens with
    /// `*`, `<` or a space are patterns, not files, and are skipped.
    static func unresolvedPaths(in text: String, repoRoot: URL) -> [String] {
        let pattern = #"`([A-Za-z0-9_+./-]+\.(?:swift|md|yml|sh|json))`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let names = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        let fm = FileManager.default
        var basenames: Set<String>?
        func allBasenames() -> Set<String> {
            if let basenames { return basenames }
            var found: Set<String> = []
            for root in ["Maugham", "MaughamPhone", "Packages", "MaughamTests",
                         "MaughamPhoneTests", "docs", "scripts", "register", ".github"] {
                let url = repoRoot.appendingPathComponent(root)
                guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil)
                else { continue }
                for case let file as URL in walker { found.insert(file.lastPathComponent) }
            }
            for top in (try? fm.contentsOfDirectory(atPath: repoRoot.path)) ?? [] {
                found.insert(top)
            }
            basenames = found
            return found
        }
        var missing: [String] = []
        for name in Set(names).sorted() {
            if name.contains("/") {
                let trimmed = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
                if !fm.fileExists(atPath: repoRoot.appendingPathComponent(trimmed).path) {
                    missing.append(name)
                }
            } else if !allBasenames().contains(name) {
                missing.append(name)
            }
        }
        return missing
    }

    /// The `.swift` files (repo-relative) a guide's Map must name: every one
    /// under the guide's own folder, recursively.
    static func swiftFiles(besideGuide guide: String) -> [String] {
        let folder = (guide as NSString).deletingLastPathComponent
        let root = repoRoot.appendingPathComponent(folder)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var files: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(folder + "/" + String(url.path.dropFirst(root.path.count + 1)))
        }
        return files.sorted()
    }

    /// The files a Map does not name. A file is named when the guide holds it
    /// in backticks by its bare name (`` `Foo.swift` ``) or by a path ending in
    /// it (`` `Maugham/Views/Publish/Foo.swift` ``).
    static func mapMisses(in guide: String, files: [String]) -> [String] {
        files.filter { path in
            let name = (path as NSString).lastPathComponent
            return !guide.contains("`\(name)`") && !guide.contains("/\(name)`")
        }
    }

    // MARK: - The censuses

    func test_everyBudgetedDocIsWithinItsWordCeiling() throws {
        for (path, ceiling) in Self.wordCeilings.sorted(by: { $0.key < $1.key }) {
            let words = Self.wordCount(try Self.read(path))
            XCTAssertLessThanOrEqual(words, ceiling,
                "\(path) holds \(words) words, over its ceiling of \(ceiling). "
                + "Move detail into the AREA.md, ADR or note it belongs in; "
                + "do not raise the ceiling without a reason beside it.")
        }
    }

    func test_noBudgetedDocHasAnOverlongLine() throws {
        for (path, ceiling) in Self.lineCeilings.sorted(by: { $0.key < $1.key }) {
            let longest = Self.longestLine(try Self.read(path))
            XCTAssertLessThanOrEqual(longest, ceiling,
                "\(path) has a \(longest)-character line, over \(ceiling). Split it.")
        }
    }

    func test_everyBacktickedFileInACheckedDocExists() throws {
        for path in Self.pathCheckedDocs {
            let missing = Self.unresolvedPaths(in: try Self.read(path), repoRoot: Self.repoRoot)
            XCTAssertEqual(missing, [], "\(path) names files that do not exist: \(missing)")
        }
    }

    /// Every Core source file is on the Core map (D3). A new file that is
    /// missing fails here, so the map cannot rot into a partial list.
    func test_everyCoreSourceFileIsOnTheCoreMap() throws {
        let dir = Self.repoRoot.appendingPathComponent("Packages/MaughamCore/Sources/MaughamCore")
        let area = try Self.read("Packages/MaughamCore/Sources/MaughamCore/AREA.md")
        // Recursive: the map promises `Inbox/` (and any later subfolder) too.
        // Matched by file name, as the map spells it.
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var files: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url.lastPathComponent)
        }
        files.sort()
        XCTAssertFalse(files.isEmpty, "the control: no Core files found means the scan reads nothing")
        let missing = files.filter { !area.contains("`\($0)`") }
        XCTAssertEqual(missing, [], "Core files missing from Packages/MaughamCore/Sources/MaughamCore/AREA.md's Map")
    }

    /// Every guide's Map names every Swift file in its folder (Review Focus 2
    /// of plan 5, made a census by its final review). Core's own test above
    /// stays; this one generalises it.
    func test_everyAreaGuidesMapNamesEveryFileInItsFolder() throws {
        for guide in Self.templatedGuides {
            let files = Self.swiftFiles(besideGuide: guide)
            XCTAssertFalse(files.isEmpty, "the control: no Swift files found beside \(guide)")
            let missing = Self.mapMisses(in: try Self.read(guide), files: files)
            XCTAssertEqual(missing, [], "\(guide)'s Map does not name these files in its folder")
        }
    }

    func test_untaggedDocsCarryNoMilestoneTag() throws {
        for path in Self.untaggedDocs {
            let tags = Self.milestoneTags(in: try Self.read(path))
            XCTAssertEqual(tags, [], "\(path) carries milestone tags (history belongs in git or an ADR): \(tags)")
        }
    }

    func test_everyAreaGuideFollowsTheTemplate() throws {
        for path in Self.templatedGuides {
            XCTAssertNil(Self.templateProblem(in: try Self.read(path)),
                "\(path) must have ## Map, ## Rules, ## Recipes, ## Pointers in that order")
        }
    }

    /// Every guide in the repo is in the template (plan 5's end state). The
    /// equality is the census: a new AREA.md the walk finds but the list does
    /// not name fails, and so does a listed guide that no longer exists.
    func test_everyAreaGuideInTheRepoIsTemplated() {
        let guides = Self.areaGuides(under: Self.repoRoot)
        XCTAssertGreaterThanOrEqual(guides.count, 11, "the control: the walk found only \(guides)")
        XCTAssertEqual(Set(Self.templatedGuides), Set(guides),
            "templatedGuides must name exactly the AREA.md files in the repo. "
            + "A new guide is written in the template (## Map, ## Rules, ## Recipes, ## Pointers) "
            + "and added to templatedGuides, untaggedDocs and wordCeilings.")
        XCTAssertEqual(Self.templatedGuides.count, Set(Self.templatedGuides).count,
            "templatedGuides names a guide twice")
    }

    func test_noAreaGuideExceedsTheHardCap() throws {
        let guides = Self.areaGuides(under: Self.repoRoot)
        XCTAssertGreaterThanOrEqual(guides.count, 11, "the control: the walk found only \(guides)")
        for path in guides {
            let words = Self.wordCount(try Self.read(path))
            if Self.notYetTemplated.contains(path) {
                XCTAssertGreaterThan(words, Self.areaGuideHardCap,
                    "\(path) holds \(words) words, within the cap: remove it from notYetTemplated")
            } else {
                XCTAssertLessThanOrEqual(words, Self.areaGuideHardCap,
                    "\(path) holds \(words) words, over the \(Self.areaGuideHardCap)-word cap. "
                    + "Move narrative to docs/history/ and re-template it.")
            }
        }
        for path in Self.notYetTemplated {
            XCTAssertTrue(guides.contains(path), "notYetTemplated names \(path), which is not an AREA.md")
        }
    }

    func test_theCeilingsNameRealDocs() {
        for path in Set(Self.wordCeilings.keys).union(Self.lineCeilings.keys)
            .union(Self.pathCheckedDocs).union(Self.untaggedDocs) {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: Self.repoRoot.appendingPathComponent(path).path),
                "a budget names \(path), which does not exist: the census would read nothing")
        }
    }

    /// AGENTS.md is CLAUDE.md under a generated header (scripts/gen-agents-md.sh);
    /// its budget is CLAUDE.md's. Returns the problem, or nil when it is current.
    static func agentsMdProblem(agents: String, claude: String) -> String? {
        let lines = agents.components(separatedBy: "\n")
        guard let first = lines.first, first.contains("GENERATED from CLAUDE.md") else {
            return "AGENTS.md is stale: run scripts/gen-agents-md.sh"
        }
        let body = lines.dropFirst(2).joined(separator: "\n")
        return body == claude ? nil : "AGENTS.md is stale: run scripts/gen-agents-md.sh"
    }

    func test_agentsMdIsCLAUDEmdWithItsGeneratedHeader() throws {
        let problem = Self.agentsMdProblem(agents: try Self.read("AGENTS.md"),
                                           claude: try Self.read("CLAUDE.md"))
        XCTAssertNil(problem)
    }

    func test_theAgentsMdGuardFiresOnAStaleBody() {
        let header = "<!-- GENERATED from CLAUDE.md by scripts/gen-agents-md.sh -->\n\n"
        XCTAssertNil(Self.agentsMdProblem(agents: header + "# Rules\nA\n", claude: "# Rules\nA\n"))
        XCTAssertNotNil(Self.agentsMdProblem(agents: header + "# Rules\nOLD\n", claude: "# Rules\nA\n"))
        XCTAssertNotNil(Self.agentsMdProblem(agents: "# Rules\nA\n", claude: "# Rules\nA\n"),
                        "a missing header is reported")
    }

    // MARK: - Planted controls (each helper fires, and lets clean text through)

    func test_theHelpersFireOnPlantedOffenders() {
        let good = "# X\n\n## Map\n\n## Rules\n\n## Recipes\n\n## Pointers\n"
        XCTAssertNil(Self.templateProblem(in: good))
        XCTAssertNotNil(Self.templateProblem(in: "## Rules\n## Map\n## Recipes\n## Pointers\n"),
                        "Rules before Map is reported")
        XCTAssertNotNil(Self.templateProblem(in: "## Map\n## Rules\n## Pointers\n"),
                        "a missing Recipes is reported")
        XCTAssertNotNil(Self.templateProblem(in: good.replacingOccurrences(of: "## Rules", with: "### Rules")),
                        "a ### heading is not a ## heading")
        XCTAssertNotNil(Self.templateProblem(in: "## Map\n```\n## Rules\n```\n## Recipes\n## Pointers\n"),
                        "a heading inside a code fence is not a heading")
        XCTAssertNil(Self.templateProblem(in: "## Map\n```\n## not a heading\n```\n## Rules\n## Recipes\n## Pointers\n"))
        XCTAssertEqual(Self.mapMisses(in: "- `A.swift` and `Maugham/Views/Sub/B.swift`; not C.swift",
                                      files: ["Maugham/Views/A.swift", "Maugham/Views/Sub/B.swift",
                                              "Maugham/Views/C.swift", "Maugham/Views/AB.swift"]),
                       ["Maugham/Views/C.swift", "Maugham/Views/AB.swift"],
                       "an unbackticked or partial name is a miss")
        XCTAssertEqual(Self.wordCount("one two\nthree\t four  "), 4)
        XCTAssertEqual(Self.longestLine("ab\nabcde\n"), 5)
        XCTAssertEqual(Self.milestoneTags(in: "Shipped in P3c plan 2, Task 4, fix round 1, on 2026-10-17."),
                       ["P3c", "plan 2", "Task 4", "fix round", "2026-10-17"])
        XCTAssertEqual(Self.milestoneTags(in: "See `docs/superpowers/notes/2026-10-17-foundations-audit.md` and `P3a`."), [],
                       "a backticked dated path is a pointer, not a tag")
        XCTAssertEqual(Self.milestoneTags(in: "See `a.md`, written 2026-10-17."), ["2026-10-17"])
        XCTAssertEqual(Self.milestoneTags(in: "Phase 3d was abandoned; tripwire 36 holds."), [],
                       "Phase 3d and tripwire numbers are not milestone tags")
        XCTAssertEqual(Self.milestoneTags(in: "Shipped in M4, reworked in M1A."), ["M4", "M1A"])
        XCTAssertEqual(Self.milestoneTags(in: "The MCP server follows ADR 0019."), [],
                       "MCP and ADR numbers are not milestone tags")
        let missing = Self.unresolvedPaths(
            in: "See `CLAUDE.md`, `Packages/MaughamCore/Package.swift`, `NoSuchFile.swift`, "
                + "`docs/nope.md` and the pattern `Foo*.swift`.",
            repoRoot: Self.repoRoot)
        XCTAssertEqual(missing, ["NoSuchFile.swift", "docs/nope.md"])
    }
}
