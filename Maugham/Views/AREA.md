# Views — area guide

The SwiftUI views of every window. The one rule from CLAUDE.md: **ask `Posture` what to offer; never compare a permit rung (tripwires 47, 51).** The area carries tripwires 2–7, 9, 14–16, 21, 22, 33, 43, 47, 49–52 and 55.

## Map

Every file in `Maugham/Views/` appears once, plus the `Maugham/Models/` files CLAUDE.md routes here. **→ Compiler** / **→ Canvas**: that guide's Rules govern the file (search for its name or types).

### The window family
- `ProjectWindow.swift` — root view: `body`, the window's `@State`, the pure static decisions (`showsStatusFooter`, `publishCentre`, `inspectorRoute`, `canvasCollapse`), `binderColumn`, `detailColumn`, four modifiers: `TopChromeModifier`, `PaletteWallModifier`, `SessionAndNavigationModifier`, `CollectionPieceModifier`.
- `CentreRoute.swift` — `CentreRoute`, `CentreCover`, `ProjectWindow.centreRoute(…)`: centre as one value (tripwires 6, 27, 30); `CentreItem.swift`, `CentreItemCover.swift`: a statement or History as cover; `CentreKeys.swift`, keys under covers.
- `CentreColumn.swift` — the centre column: one `switch` over `centreRoute`, the canvas's one mount, `manuscriptEditor` (`EditorHost`, Book's view, one cover), `statusBoard` (the board's one mount) and open-notes counts, the Inbox (tripwires 2, 6, 30).
- `RightColumn.swift` — resize handle, control over one arm, hidden arm; `RightColumnToggle.swift`, toolbar button; `RightColumnControl.swift`, three positions; `RightColumnContent.swift`, what each shows; `PulledUpView.swift`, pulled-up thing (`PulledUpRegionView.swift`, a region; `PulledUpHistory.swift`, Back); `PulledUpEscape.swift`, its Esc; `RightColumnSubjectLine.swift`, faces' title; `BriefFocus.swift`, ⌘⌥I/⌘⌥N's field, Going for's height.
- `PaletteWallState.swift` — the wall's window state (the right column's stash, the subject it was opened over), its fold and its Close. Open is the subject's `open == .palette`.
- `Maugham/Views/Publish/PublishCentreModel.swift` — an edition's centre and its compile; each rule a named method.
- `ProjectActiveSheet.swift`, `FirstReaderHandoff.swift` — the window's one sheet enum; the Describe… hand-off.
- `WindowFlashes.swift`, `CompilerFlashSink.swift` — the window's acknowledgments in one `@State`; ⌘R's capsule as a value a suspended caller can hold.
- `CheckpointModifier.swift` — ⌘S / ⌘⇧S delivery; `CheckpointFlashDecision`.
- `RewindModifier.swift` — the `.maughamOpenRewind` receiver and sheet.
- `ReadThrough.swift`, `ReadThroughModifier.swift`, `ReadThroughLine.swift` — `ReadThrough.isOn`, `ReadThroughGate`, `ReadThroughOffer` (routes post only what it gives), the verbs, the receiver, the line, the mark.
- `FocusPostureModifier.swift` — ⌘\ no-chrome.
- `ParagraphNavModifier.swift` — `.maughamNavigateToParagraph`, `.maughamNavigateToScene` receivers.
- `CanvasCollapseModifier.swift`, `CanvasPromotionModifier.swift`, `CanvasClaudeArrivalModifier.swift` — ⌘\ collapse to the canvas; Promote…; Claude's arrival banner and its Show. **→ Canvas** ("`⌘\` gives the canvas the window").
- `ReadingLanguageModifier.swift`, `ReadingLanguage.swift` — the language a piece is read in, and the reveal's window half.
- `EditorControlMirror.swift` — `EditorControlMirror` (the editor's membrane, pure, from the posture), `InsertMenuGate` (the Insert menu's enablement, focused value `mayInsertReportElement`), the modifier.
- `NoteOutcomeAlert.swift`, `ContainerWidthReporter.swift` — the translator's-note outcome alert; a width reporter.
- `CompilerRunModifier.swift` — the run commands' delivery path (`RunCommand`) and the session's teardown (`roster.shutdownAll()`). **→ Compiler**
- `AdmissionModifier.swift`, `NewPieceModifier.swift` — the window's halves of the admission and new-piece questions (below).
- `SubjectValidationModifier.swift` — repairs the whole subject (`validatedSubject`) on a structure, research or figure change, and when a figure's stream parks it.
- `ResearchRevealModifier.swift` — an item arriving beside reveals the right column.
- `WindowAccessor.swift`, `WindowEscapeArbiter.swift` — the hosting `NSWindow` (cached; never re-nils); one Escape monitor per window, fixed priority, let go when the window closes.
- `WindowFloorFree.swift` — `WindowFloorFreeLayout`, `.doesNotRaiseTheWindowFloor()`: a pane may not raise the window's minimum height.
- The window borrows a `ProjectSession` from `ProjectSessionRegistry` (a `.window` lease) and its `claude` services through `AgentRoster`: `Maugham/Stores/AREA.md` ("Project sessions").

### The shell
- `ReadThroughToggle.swift` — the open piece's padlock.
- `ManuscriptNavigation.swift` — going to a place opens its piece.
- `TreeTravel.swift` — the double-click: the row mark (`treeTravelOnDoubleClick`, also drawing the outlined state), `TreeTravelClickWatcher`, `TreeTravelModifier`.
- `IntentStrip.swift`, `CentreTopLines.swift` — the signature line; the centre's top lines.
- `LanguageSwitch.swift`, `RunningRoundIndicator.swift` — the toolbar's language switch, running round.
- `SaveFlashOverlay.swift` — the ⌘S muscle-memory capsule.
- `MCPBannerModel.swift`, `MCPNoteBanner.swift` — Claude's note banner.
- `BackupRecoveryBanner.swift`, `ManifestRestoredBanner.swift` — the refused-backup banner (Restore); the put-back-manifest note.
- `SharingStatusPill.swift` — *Shared* / *Shared by <owner>*: an indicator, never a role.
- `ViewOnlyShareNotice.swift` — the banner over a read-only iCloud share (`ProjectWindow.shareIsReadOnly`).
- `ProjectShareSheetPresenter.swift` — File → Share Project via iCloud… (`NSSharingServicePicker`).

### The left column: the tree
- `BinderPaneToggle.swift` / `CollectionBinderPaneToggle.swift` — the two left-column shells (`ProjectWindow.BinderShell`): find overlay, one tree, Exports footer, the trash's foot.
- `BinderView.swift` — the novel / short-story tree; `TreeStructureVerbs` (the tree's posture-gated structure verbs); `linkResearchVerb`; `TreeCanvasKeyboard`.
- `SceneNavigatorPane.swift` — a screenplay's tree: the script row and its sluglines.
- `ScreenplayScriptSource.swift` — the parsed script the left column shows when no editor is mounted to parse it.
- `CollectionPiecesPane.swift` — a Collection's flat pieces tree; `StartAPieceDoor`.
- `BinderRow.swift`, `PieceRow.swift`, `ResearchRow.swift` — the tree's row views; the inline-rename shape (tripwire 16).
- `ProjectRowLabel.swift` — every project row's label.
- `FigureSection.swift` — the Figures section (shown unless parked with no legacy line) and its cached rows, piece counts and filter; `FigureSectionVerbs` (the row menu over `FigureActions`, the drops, `moveIntoFigures`, `PendingFigureSend`/`TreeAlert`), `FigureSectionWiring` (the tree's own card cache).
- `FigureActions.swift` — the one helper the menus and inspectors share: Open in Window, Send to Research, Rename, Import/Refresh through the grid, Use in Document; the posture and `refusesWrites(to:)` gate the writes.
- `FigureRow.swift` — a figure's tree row, a piece row's count button, `LegacyFigureRow` (a line into Research; selects nothing).
- `TreeTopRows.swift` — `TreeRowSlot` (row order), the Inbox and Canvas rows, `TreeRowStateMark`.
- `TreeEditionRows.swift` — the Editions rows, the source language first.
- `BinderTreeSections.swift` — the Figures, Research, Palette (the wall's door) and Editions sections; `TreeSectionColumn.swift`, the titles' column; `BinderTreeSectionsState`, `BinderTreeSelection`, `BinderTreeVerbs`, `TreeScrollTarget`, `TreeAlert` (one alert; an error waits for a send question), `.binderTreeSections(…)`, `consumingTreeScrollRequests`; `TreeWindowWiring.swift`, its window-mounted half.
- `BinderPieceFold.swift` — a piece's fold; `PieceFoldContents.swift`, its whole contents (`PieceFoldIndex`).
- `TreeSectionDerivation.swift` — pure: `sharedResearchRoots`, `pieceFold`; `ResearchHomeMenu.swift`, row menus.
- `TreeDropIntent.swift` — what a drag onto the tree means (`classify`, `classifyExternal`).
- `BinderTreeDrops.swift` — performs what `TreeDropIntent` decided (the `route…Drop` family).
- `DropIntent.swift` — top/middle/bottom drop position → structural action.
- `DropClassification.swift` — one dropped `NSItemProvider`: file URL over image data; `ProviderDropRoute.swift`, a whole drop by type.
- `ResearchTree.swift` — the recursive research node (`ResearchTreeNode`, `ResearchTreeActions`, `ResearchSelectionSync`).
- `ResearchPasteImporter.swift` — ⌘V into research (`TreePasteRouting`).
- `ResearchLinkPickerSheet.swift` — "Link Research…" on a document row.
- `AddResearchLinkSheet.swift` — the Add Link sheet.
- `TrashView.swift` — the trash list and `TrashDisclosure`, the tree's foot.
- `RemovedElsewhereDisclosure.swift` — pieces removed on another Mac, with Restore, at the tree's foot.
- `ProjectSearchView.swift` — Find in Project, an overlay of the tree; `ReplaceGate`.
- `TreeScrollProbe.swift` — a dev-build-only diagnostic.

### Research and the palette
- `FigureSubjectColumns.swift` — `figureSubjectPlacement` (centre / beside the canvas / nothing) and `FigureSubjectSurface`: a table's grid (`FigureCentreGrid`), an image large (`FigureImageSubject`, via `SafeRelativePath`), else name and number.
- `FigureInspector.swift` — name, number and section, Used-in links (`FigureUseTravel`, the source reveal), pins by source (`FigureInspectorModel`, off the body), the figure stream's notes (`ProjectStore.figureNotes`, never the project walk), actions.
- `FigurePinsCompare.swift` — Compare: old and new per pinned cell; Refresh as one step on the open grid's stack.
- `ResearchSubjectColumns.swift` — what each column does with a `.research` subject: `researchSubjectPlacement`, `researchCentreRoute`, `revealPulledUp`, `ResearchSubjectCentre`, `ResearchSubjectInspector`.
- `ResearchNoteEditor.swift` — the research-note editor: saves through the note door; re-reads on `researchNoteReloadCount`; read-through or a view-only share locks it.
- `ResearchNotePreviewPane.swift` — rendered Markdown preview of a note, inline images included.
- `ResearchPreview.swift` — routes an item to its preview by kind.
- `Maugham/Views/research/AudioPreview.swift`, `Maugham/Views/research/ImagePreview.swift`, `Maugham/Views/research/LinkPreview.swift`, `Maugham/Views/research/PDFPreview.swift`, `Maugham/Views/research/TextPreview.swift` — per-kind previews.
- `InspectorResearchPanel.swift`, `ResearchVersionsSection.swift` — a research item's fields, citation and versions.
- `NewResearchNoteSheet.swift` — title prompt for a new note.
- `Maugham/Views/Palette/PaletteWallView.swift` — `PaletteWallCentre`, the full-column grid of cards.
- `Maugham/Views/Palette/PaletteCardTile.swift` — one wall card; no I/O in `body`.
- `Maugham/Views/Palette/PaletteCardEditor.swift` — the palette-card editor: types through `scheduleNoteSave`, renames through `renamePaletteCard`, re-reads on `researchNoteReloadCount`.
- `Maugham/Views/Palette/PaletteCardReadView.swift` — `PaletteCardReadView` / `PaletteCardReadHost`, one card read-only.
- `PalettePickerSheet.swift`, `PromoteTargetPickerSheet.swift` — the inbox's Promote to Palette Card… / Promote to Research for… pickers.

### The centre's editor and altitude
- `EditorHost.swift` — mounts the editor on the subject's document; the single-binding contract (tripwires 2, 3, 6, 7, 22); the recovery pane wiring and `recoveryActionIsCurrent`; `quarantineAndContinue`.
- `DocumentRecoveryPane.swift` — `RecoveryPaneModel` and the refusal pane before a document opens.
- `RecoveryBanner.swift` — `RecoveryBannerModel` and the banner over a read-only open document.
- `ProjectAltitudePane.swift` — the Book's Cards, Outline, Status; `CentreViewSwitch.swift`, their toolbar switch.
- `CorkboardGrid.swift`, `OutlineTable.swift` — altitude's two layouts; `OutlineTable` reads the writers once.
- `ReferencePlaceholderCard.swift` — the centre's placeholder for a Collection's reference piece.
- `EditorStatusFooter.swift`, `PieceTargetMenu.swift` — the status row under the editor, its target menu.
- `ReferenceIndexHost.swift` — the window's cached `ReferenceIndex`, its token listing and parse off the main thread; the window owns it, `EditorHost` is handed it.
- `ReferenceIndexWiring.swift` — attaches the window's index and carries its project edges with no editor mounted; `FigureListingModel`, the Figures rows.
- `FigureCardCache.swift` — the window's figure cards, filled off the typing path and read from memory only; `EditorHost` owns it.
- `StatusSwatch.swift` — the one place a `ReviewStatus` becomes a `Color`.

### The right column's panes
- `ReferencePieceInspector.swift` — a Collection reference piece's inspector.
- `PieceRowMenus.swift` — a piece row's Tags…, Add Link…, Target…, Publishing… (a sheet each), History; `PieceLinkSearch.swift`, `InspectorTagsField.swift` (with `FlowLayout`) serve its sheets, `InspectorCitationSection.swift` the research panel.
- `PassLadder.swift` — the per-piece pass ladder; `offersRulings`.
- `TaskRow.swift` — one to-do's row, drawn in To resolve.
- `InboxPane.swift` — phone captures triage; `InboxByline.swift` — who a capture is from.
- `RowThumbnails.swift` — the row-thumbnail cache (tree, Inbox) and `RowThumbnail`.
- `AdaptiveFilterRow.swift` — the filter row that degrades labels to icons.

### Annotations queue and Review
- `AnnotationRow.swift` — one note's row, drawn in To resolve.
- `AnnotationAuthorPresentation.swift` — how an annotation's author is shown.
- `AnnotationBulkActions.swift` — multiselect's plan, honest counts and executor.
- `AnnotationQueueOrder.swift` — the order inside a To resolve group (triaged Do first); `AnnotationTriageFilter`.
- `PassOrderAdvice.swift` — the advisory nudge.
- `Maugham/Views/Review/ReviewRoundCockpit.swift` — the round cockpit strip; `BoundedHeightLayout`. **→ Compiler**
- `Maugham/Views/Review/ReviewBoardPane.swift` — Review's pieces × passes board; `ReviewBoardChipVerbs`, `ReviewBoardOpenNotes`.
- `Maugham/Views/Review/ReviewBoardRows.swift` — the board's pre-order row flattening.
- `Maugham/Views/Review/RunWhenDocumentOpens.swift` — wait for a piece to open, then run its round.
- `ReviewPassEditorLogic.swift` — pure array transforms behind Project Settings' Review Passes editor.
- `Maugham/Views/Resolve/ResolveScope.swift`, `ResolveItem.swift`, `ResolveReader.swift`, `ResolveFigureSource.swift`, `ResolvePresence.swift`, `ResolveChunkedWalk.swift` — To resolve's scope, items, loadless reader, changed figures; the tree's marks, walked off-main.
- `Maugham/Views/Resolve/ResolveGrouping.swift`, `ParagraphOffsets.swift` — grouping by paragraph, scene or piece; display-text offsets placing a closed screenplay's paragraphs among scenes.
- `Maugham/Views/Resolve/ResolveFilter.swift`, `ResolveTriage.swift`, `ResolveRefresh.swift` — To resolve's sources and chips, the triage choice (offered while a note carries a mark; ANDs with the chips), density past twelve, the caret's and open groups; its refresh key and its may-be-incomplete notice.
- `Maugham/Views/Resolve/ResolveVerbGate.swift`, `ResolveNavigation.swift` — act only on the open piece; a row's click goes to its piece and paragraph.
- `Maugham/Views/Resolve/ResolveNoteVerbs.swift`, `ResolveNoteStatics.swift`, `ResolveDialogs.swift`, `AnnotationRowHost.swift`, `ResolveTaskVerbs.swift`, `NewTaskSheet.swift` — note verbs and sheets, one note row, to-do verbs and sheet.
- `Maugham/Views/Resolve/AnnotationRowWiring.swift`, `FigureRowGate.swift`, `AnnotationsBulkBar.swift` — a row's closures, a figure note's gate, the multiselect bar.
- `Maugham/Views/Resolve/ResolveHead.swift`, `ResolveHeadStatics.swift` — the head; the shared letter host, cockpit mount and nudge row.
- `Maugham/Views/Resolve/ResolvePane.swift`, `ResolveListDecisions.swift`, `ResolveFilterBar.swift`, `ResolveSettledSection.swift` — the list (⌘1), decisions, chips, Settled section.
- `Maugham/Views/Resolve/ResolveEditionItems.swift` — an edition's list: changes, glossary, design, compile; rows, verbs, head.
- `Maugham/Views/Resolve/ResolvePieceInLanguage.swift`, `PieceInLanguageCaretSection.swift` — a piece read in a language: head, caret paragraph.
- `Maugham/Views/Brief/BriefScope.swift`, `BriefLine.swift`, `BriefDecisions.swift`, `ClauseMarks.swift`, `BriefReader.swift` (model); `BriefPane.swift`, `BriefPieceView.swift`, `GoingForView.swift`, `BriefDecidedSection.swift`, `BriefPartView.swift`, `BriefBookView.swift`, `BriefEditionView.swift`, `FiledUnder.swift`, `BriefDetails.swift` (the foot, proposal notice) (views).

### Statements, the letter and the ledger
- `StatementPane.swift` — the Intent / Visual Language / What I've Learned / First Reader panes and an edition brief; `effectiveScope`, `proposalSlot`.
- `StatementEditorHost.swift` — the statement's editor host; `StatementTextTarget`.
- `RulingsStratum.swift` — the rulings under a statement's essay; `StatementSurfaceVerbs`. **→ Compiler**
- `BibleStratum.swift` — what Claude read off the manuscript (Confirm). **→ Compiler**
- `StatementProposalBanner.swift` / `StatementProposalDiff.swift` — the proposal gate's view and line diff.
- `LetterSection.swift` — the editorial letter on screen, one view with two hosts. **→ Compiler**
- `TurnClauseOffer.swift`, `LetterKeep.swift` — *Add to intent* and *Keep this letter*. **→ Compiler**
- `LessonLedgerVerbs.swift` — the ledger's three verbs and `LessonOffer`. **→ Compiler**
- `QueueLedgerVerbs.swift` — the queue's two doors into the ledger.
- `QueryRuling.swift` — answer a translator's query as a ruling (`QueryRulingSheet`).
- `FirstReaderRuling.swift` — answer the first reader's note into her statement; `RulingDestination`. **→ Compiler**

### Compiler surfaces (→ Compiler: "Ingest, the sidecar and the mint", "Streaming and the preview", "The derivation trigger and the bible")
- `Maugham/Views/Resolve/CheckNarrative.swift`, `CheckNarrativeCopy.swift`, `CheckNarrativeVerbs.swift` — the check's statics; `DiagnosticsPaneHeader.swift`, `DiagnosticsPaneSections.swift` — its header, row and cold-start offer.
- `AskField.swift` — Ask about…, one field shape in two homes.
- `CompilerModelMenu.swift` — the depth picker in both homes.

### Publish (`Publish/`)
- `Maugham/Views/Publish/PublishPreviewCentre.swift` — `PublishCentre`, `PublishCentreNotice`, an edition's book and Compile… bar, the notice cover, `PublishPreviewModifier`.
- `Maugham/Views/Publish/EditionStatusView.swift`, `Maugham/Views/Publish/EditionStatusRows.swift` — an edition's Status.
- `TranslationRunState.swift`, `TranslationRunStart.swift`, `DesignRoundState.swift`, `CompileRunState.swift` — runs, design, compile as values. **→ Compiler**
- `EditionCastSheet.swift`, `EditionCastVerbs.swift`, `EditionWiring.swift` (Add/Remove Edition, ⌘⌥K), `PublishImprint.swift`.
- `Maugham/Views/Publish/CompileSheet.swift`, `Maugham/Views/Publish/CompileRunner.swift` — Compile… and the window's runner.
- `Maugham/Views/Publish/DesignGateView.swift` / `Maugham/Views/Publish/DesignGateVerbs.swift` — the design gate and its four verbs. **→ Compiler**
- `Maugham/Views/Publish/TranslationRoundReport.swift`, `Maugham/Views/Publish/TranslationRoundReportView.swift`, `Maugham/Views/Publish/TranslationRoundReportHost.swift`, `Maugham/Views/Publish/TranslationRoundActions.swift`, `Maugham/Views/Publish/DepartureRow.swift`, `Maugham/Views/Publish/RoundRuleSheet.swift` — the round report: pure rows and copy, view, host, verbs, departure row, *Make it a rule*.
- `Maugham/Views/Publish/PublishProblemsView.swift` — Show Problems' list (`PublishProblems`), each row reveals its paragraph.
- `Maugham/Views/Publish/ExportsListView.swift` — the tree's Exports footer.
- `Maugham/Views/Publish/PiecePublishSettings.swift` — per-piece publish overrides from row menus.
- `Maugham/Views/Publish/PublishStatusPill.swift` — the compiling pill.

### Translation
- `TranslationCellsSection.swift` — a table's cells in a language.
- `TranslationReveal.swift` — a round-report row as a way back into the manuscript.
- `TranslatorsNote.swift` — Translator's note… (⌘⌥C).

### History, rewind, checkpoints, restore
- `HistoryPane.swift` — forensic timeline. Children: `HistoryPaneNotices.swift` (`HeldLineNoticeRow`, `SetAsideRecordsDisclosure`), `HistoryPaneTimeline.swift`, `HistoryRow.swift`, `HistoryPaneVerbs.swift` (tripwire 50), `HistoryPaneStatics.swift`.
- `RecoveredHistorySheet.swift` — the copyable orphan report with Append to End.
- `RewindWindow.swift`, `RewindTickLayout.swift`, `RewindAction.swift`, `RewindScope.swift` — the per-doc rewind modal, its scrubber decimation, its terminal actions, its scope.
- `PartialRestorePicker.swift` — checkpoint-row reverts, per document or project: winds back each registered figure with a pointer behind its `.editFigure` door (`withFigureHost`); reopens accepts it takes back, said before and after (`RevertNotes`);
- `CheckpointLabelPromptSheet.swift` — the label sheet for ⌘⇧S and Snapshot here.
- `RestoreWindow.swift` — restore from a backup generation.

### The register and the posture
- `AdmissionDecision.swift`, `AdmissionQueue.swift`, `AdmissionSheet.swift`, `AdmissionWaiting.swift` — one device, one sheet: decisions, queue, sheet, what is waiting.
- `PermitControl.swift` — the one place a surface turns a display choice into a `Permit`.
- `PeopleAndDevicesModel.swift`, `PeopleAndDevicesSection.swift`, `PeopleAndDevicesConfirmation.swift` — Project Settings' People & Devices.
- `ClaimDecision.swift`, `ClaimSheet.swift` — This Book Is Mine….
- `LoadQuestions.swift` — the load's questions (*Sam started X — is it hers?*).
- `SetAsideDoor.swift` — the one way a set-aside paragraph comes back.
- `PieceWriters.swift` — whose piece is whose.
- `PostureStandingLine.swift` — the editor's standing line.
- `ProjectSettingsSheet.swift`, `ReportSettingsSection.swift` — Project Settings: Coach, First reader, Review Passes, People & Devices, Report; `StrandedPieces`.

### Statistics (`statistics/`) and other windows
- `ProjectStatisticsWindow.swift` — the Statistics window, a `.reader` borrow.
- `Maugham/Views/statistics/ProjectPractice.swift`, `Maugham/Views/statistics/PracticeSection.swift` — the Practice section: derivation and view.
- `Maugham/Views/statistics/ProjectStatisticsView.swift`, `Maugham/Views/statistics/ProjectTotalSection.swift`, `Maugham/Views/statistics/WordsByChapterSection.swift`, `Maugham/Views/statistics/RecentSessionsSection.swift`, `Maugham/Views/statistics/DailyHeatmapSection.swift` — the other sections.
- `WelcomeView.swift`, `WelcomeCarousel.swift`, `NewProjectSheet.swift` — launch window, first-run tour, new project.
- `HelpWindow.swift`, `GuideMarkdownView.swift`, `SyntaxHelpSheet.swift`, `KeyboardCheatsheetView.swift`, `HelpClaudeDesktopSheet.swift`, `AcknowledgementsWindow.swift` — help surfaces.
- `SettingsView.swift`, `Maugham/Views/SettingsTabs/GeneralSettingsTab.swift`, `Maugham/Views/SettingsTabs/EditorSettingsTab.swift`, `Maugham/Views/SettingsTabs/ThemeSettingsTab.swift`, `Maugham/Views/SettingsTabs/TypographySettingsTab.swift`, `Maugham/Views/SettingsTabs/VoiceSettingsTab.swift`, `Maugham/Views/SettingsTabs/BackupSettingsTab.swift`, `Maugham/Views/SettingsTabs/AboutSettingsTab.swift` — app Settings.

### `Maugham/Models/` files routed here
- `RightColumnPosition.swift`, `PulledUp.swift` — the right column's three positions; the pulled-up thing.
- `BinderSubject.swift` — the window's one subject: `.project`, `.item(id)`, `.research(id)`, `.figure(id)`.
- `TreePane.swift` — which tree the left column mounts (`TreePane(for:)`).

## Rules

### Tripwires this area carries
- **No SwiftUI ↔ AppKit two-way sync guarded by flags** (tripwire 2): `.onChange` fires after the flag clears. Every `@State` a column writes arrives as a `Binding`; a copy drifts. Prose only (`Maugham/Editor/AREA.md`).
- **No heavy work inside a synchronous SwiftUI binding setter** (tripwire 3): `EditorIntegrationHarnessTests`.
- **No uncached per-row computation in list rows or on a body path** (tripwire 4): panes take values; hosts do store, disk and walk work in `.task`. Prose only; `ReviewBoardPaneTests.test_theSourceReadsNoStoreAtAll` guards a named pane.
- **No `NSPopover` for editor autocomplete** (tripwire 5): `TripwireGrepTests.test_noPopoverInEditorAutocomplete`.
- **No parallel observable state on `EditorHost`; one `Binding` writes `displayText` exactly once** (tripwire 6): `EditorIntegrationHarnessTests`.
- **No second caller of `EditorSurface.applyExternalText`** (tripwire 7): `TripwireGrepTests.test_applyExternalTextHasExactlyOneProductionCallSite`.
- **No `.onTapGesture` for clickable rows inside `List(.sidebar)`; use `Button(.plain)`** (tripwire 9). A gesture attaches to a row's label leaf, never its container: a whole-row `.simultaneousGesture` ate drag initiation. `TripwireGrepTests.test_noTapGestureInASidebarListFile`, `TreeTravelGestureAttachmentTests.test_noTreeRowCarriesASwiftUITapGesture`.
- **Move or delete user-editable content only through `DocumentStore`'s typed mover** (`relocate(plan:)`, `relocateUserContent(affectedPaths:perform:)`, `trash(relativePath:using:…)`), which closes and flushes before the FS call (tripwire 14): `TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover`.
- **A pane that may show a `ContentUnavailableView` chains `.frame(maxWidth: .infinity, maxHeight: .infinity)` on it, and its outer `VStack` takes `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`** (tripwire 15), or the toolbar floats. `TripwireGrepTests.test_contentUnavailableViewAlwaysChainsFullFrame`.
- **A rename-capable row copies `BinderRow`'s shape verbatim**: a `claimFocus()` that sleeps 30ms before focusing, fired from `.onAppear` and `.onChange(of: renamingItemId)` (tripwire 16). Prose only; `BinderRow.claimFocus()` is canonical.
- **No raw `maugham.*` NotificationCenter traffic outside `MaughamEvent`; every post declares its scope** (tripwire 21): `TripwireGrepTests.test_noRawMaughamPostsOrSubscriptionsOutsideWrapper`.
- **Key a Document-binding reload on the doc's PATH, not its id** (tripwire 22): a renamed or restored file keeps its id. `EditorHostReloadPredicateTests` pins `EditorHost.needsReload`.
- **No test presses a mounted control then waits for its effect, or synthesises a click, outside the named allow-lists** (`pressThenWaitRepresentatives`, `clickRepresentatives`) (tripwire 33): `TripwireGrepTests.test_noNewTestPressesAControlAndThenWaitsForItsEffect`, `test_noNewTestClicksOutsideTheNamedRepresentatives`.
- **Whose piece is whose reads the permit TIMELINE, never `PersonRecord.role`/`.scope`/`.pieces`** (`PieceWriters`, over `TrustTable.myChain`) (tripwire 43): `TripwireGrepTests.test_theRoleCheckReadsTheTimelineAndNotTheRecordsField`.
- **No permit rung is compared in a view; ask `Posture`** (tripwire 47): `TripwireGrepTests.test_aPermitRungIsComparedOnlyInThePermitLayer`.
- **`PermitControl` is the one place a surface builds a `Permit`** (`Permit.permit(offering:pieces:)` / `Permit.rung(of:)`), and holds only the WORDS for each rung (tripwire 49): `TripwireGrepTests.test_aSurfaceBuildsAPermitInOnePlace`.
- **What a Mac may offer is asked of `Posture` through one door**: a surface draws from `DocumentStore.posture(forDocId:)`, a verb acts on `settledPosture(forDocId:as:)`, then `.allows(.someVerb)`; no surface names a permit or builds a `Posture` (tripwire 51): `TripwireGrepTests.test_postureIsAskedOfThePermitInOnePlace`.
- **A manuscript writer outside the editor asks its posture first, and each call is a named site in `manuscriptWriterCallSites`** (tripwire 52): `TripwireGrepTests.test_everyManuscriptWriterOutsideTheEditorIsANamedSite`, `test_everyGuardedDocumentMutatorIsClassified`.
- **Ask a project's kind or a document's format by capability or an exhaustive switch, never by equality** (tripwire 55): `TripwireGrepTests.test_projectKindAndFormatAreAskedByCapabilityNotByEquality`.

### The window body and its family
- **When `ProjectWindow.body` hits "unable to type-check this expression in reasonable time", extract a `ViewModifier`**: window behaviour lives in modifiers and a column arm is a call.
- **A census reading "the window's code" reads the family BY TYPE**: `SourceTree.windowFamilyTypes` names the members: a member nothing declares throws. Absence checks still widen to the directory.
- **`CentreColumn` and `RightColumn` are mounted once each, as the content and detail columns' roots**, so `EditorHost` and the canvas keep their identities across every route change.
- **A column reads values and takes verbs as closures**; `CentreColumn` owns one piece of state, the board's open-notes counts.
- **`canvasModel` is a `let`, and nothing in the window or columns reads `.scene`** (tripwire 30): `CanvasModel` rewrites its scene on every drag frame. `RegionInspectorPane` resolves the region one leaf down.
- **The window's stores and `claude` services are the session's**: it gives its lease back in `.onDisappear`, and `CompilerRunModifier` runs `roster.shutdownAll()`, pipeline first; a merely released session is a live, billing process.
- **The `NavigationSplitView`'s `columnVisibility:` is written by `CanvasCollapseModifier` and nothing else.** `.detailOnly` hides the canvas, which is the CONTENT column.
- **A hidden detail arm renders `Self.hiddenDetailColumn` (`Color.clear.navigationSplitViewColumnWidth(0)`), never no view**: an arm with no width hands the leftover to an empty detail column. ⌘⌥0's hidden case uses the same static (`DetailColumnWidthTests`).
- **Never put permanent chrome in a top `safeAreaInset` around the `NavigationSplitView`**. The padlock is a window-toolbar item (`TopChromeModifier`, hidden in ⌘\ focus); only the zero-height-when-idle banners live in the inset.
- **`ProjectWindow.detailColumn` frames its content to the width it declares**: one width, bound once, from `detailColumnWidth` (the persisted wish, written only by the resize handle, clamped to `UIState.detailColumnWidthRange`, 240–480).

### The centre column
- **`centreRoute` answers once, from the window's `subject: WindowSubject`, as a value; `CentreColumn` renders it with one `switch` per level, never by layer order** (`CentreRouteTests`).
- **`CentreRoute`'s case order is load-bearing for view identity**: the canvas stays the fourth branch, its one mount (tripwires 27, 30; `RegionBindingTests`); `.inbox` is last.
- **Every view or cover change happens inside `.editor(altitude:cover:)`, never as a new branch** (tripwire 6). Cards, Outline, Status are its `BookView`.
- **`manuscriptEditor`'s `ZStack`: `EditorHost` first, always; the Book's view second whenever `open` names no document, then at most ONE cover** (`ProjectAltitudeCentreTests`).
- **The Book's view is `altitudeView`'s answer**: the Book, a Part (`altitudeScope`) or an edition (its own Status). Status is a view, never a cover nor covered by a book; the board's one mount is `statusBoard`.
- **Covers, in order: an edition's** (`publishCentre`, whatever the faces are on: problems, a round, a proposal, the book), then a centre item.
- **A covered editor never holds the keys** (`CentreKeys`); a place closes the centre item first.
- **A click on a piece while the canvas or an edition is the centre moves the faces, never `open`** (`ClickRule`).
- **`showsStatusFooter` shows where `open` is a document** (`PublishPreviewCentreTests`).
- **`ScreenplayScriptSource` is a second PRODUCER of `lastParsedScript`, never a second value** (tripwire 6): `needsDerivation` is false once anything has parsed. It derives from the op log (tripwire 20).

### The subject decides, never a mode
- **No production source names a persona** (`NoPersonaCensusTests`): the window's subject decides what it shows.
- **The right column is three positions in one order** (`RightColumnMountingTests`): the pulled-up one hidden while it would show nothing. One remembered position in `UIState`.
- **Run is the command's**: each File menu item posts its own `RunCommand` (`RunKindTests`).
- **Going to a place opens its piece via `ManuscriptNavigation.go`**, whatever the centre; every receiver routes through it (`ManuscriptForceCensusTests.test_everyNavigationReceiverStillRoutesThroughTheNavigation`).

### Brief, the pulled-up thing and the fold
- **Brief never loads a manuscript `Document`** (`BriefReaderTests.test_noBriefSourceLoadsAManuscriptDocument`), so it edits an unopened piece: the line asks `TreeStructureVerbs.mayRestructure`, the intent and decisions their own posture.
- **Clause marks are drawn only in Brief's Going for**: never in the cover or on `IntentStrip`. A mark carries no model text (`GoingForTests.test_aMarkCarriesNoModelText`) and applies only while the run's `intentSnapshot` hashes to the statement's text (`ClauseMarks.applies`).
- **A verb that files into a statement says where** (`FiledUnder`, from the write's own `FiledDestination`); the line links to any Brief it names.
- **A statement host asks `statementIsInTheCentre` before it mounts** (`Maugham/Stores/AREA.md`, the gate).
- **`PulledUpView.centreShows` is the one rule against a second editor on what the centre shows.** Open in Centre MOVES every kind; a canvas card or region is read-only beside (`PulledUpViewTests`, `PulledUpTests`). Back's `PulledUpHistory` never answers `beside`.
- **On the canvas, a selection made after the last pull-up covers it** (`RightColumnContent.canvasDetailsCover`, `PulledUpMemory.canvasSelectionIsNewer`); only `CanvasDetailsCover` and `PulledUpWatch` read `selection`; Show it clears it; Esc declines while covered. Other centres' details stand above, collapsed.
- **A fold is `PieceFoldIndex`, built per `Key` in `.task`**; a region row holds its palette cards; a Collection script's Scenes lead. Pull-up rows tag `TreeRowTag.pullUp` (per piece): a key landing selects, then settles (`TreeRowSettle`); a click is the button's.
- **The old Inspector's fields live in `PieceRowMenus` and the status line** (`PieceTargetMenu`, over the OPEN piece), each asking `TreeStructureVerbs`; Brief's foot shows the set ones, opening the row's sheets (`PieceRowMenusTests`, `PieceTargetMenuTests`, `BriefAppraisalTests`).
- **The ⌘⌥ keys are declared in `MaughamApp` alone**, grouped by destination (`RightColumnAppraisalTests`); ⌘⌥L is To resolve on Questions, ⌘⌥K the reading edition's To resolve (`EditionWiring`); ⌘⌥I/⌘⌥N's field consumes `briefFocus`.
- **To resolve and Brief lead with the faces' title** (`RightColumnSubjectLine`).

### The subject and the tree
*Why each rule: [`docs/history/views.md`](../../docs/history/views.md).*
- **The tree binds the window's `WindowSubject`**: a click is `ClickRule.resolve(_, .click)`. The `List` selects the row last clicked; the open row is tinted, the faces or `beside` outlined. Clicking the row beside puts it away.
- **A verb pointing the window somewhere** uses `ClickRule.navigate`, which never dismisses.
- **Every tree's `List` selects through `BinderTreeSelection`, never the subject directly** (`BinderTreeSectionsTests.test_clickingAnEmptySectionsPlaceholderLeavesTheSubjectAlone`). A double-click is `.openInCentre` (`TreeTravelModifier`), posting the row's own tag, never `state.selection`.
- **Plan's Tab from the tree reaches the canvas only through `TreeCanvasKeyboard`** (`PromotionCommandTests`, `PlanBinderTabTests`).
- **A live research multi-selection is the one set**, anchored on `beside`; `SubjectValidationModifier` is the one rule about dead ids.
- **Only a homogeneous research selection batches**.
- **The dead strip spellings never return to production code**: `TripwireGrepTests.test_noProductionSpellingOfTheDeadStripSurvives`.
- **Find is `ProjectWindow.treeFindActive`, window `@State`**; `ProjectSearchView.close()` is its one exit.
- **⌘⌥O selects the project row; ⌘⌥R / ⌘⌥P reveal the tree's Research / Palette sections** (`AltitudeKeyspaceTests.test_cmdOptOStillActsWhileFindCoversTheColumn`).

### Tree furniture
*Why each rule: [`docs/history/views.md`](../../docs/history/views.md).*
- **Mounting the sections takes both halves** (rows inside the `List`, presentations outside via `.binderTreeSections(…)`): `TripwireGrepTests.test_everyBinderTreeMountsBothHalvesOfTheSections`.
- **Every tree sheet mounts from `BinderTreeSectionsPresentations` or `TreeWindowWiring`, never from a row**; a row only sets state.
- **Every row acts through the one `BinderTreeVerbs` value**; `perform` surfaces a store failure, never `try?`.
- **`create` selects what it makes and defers the rename until the manifest shows the new row** (`pendingRenameId`).
- **`reveal` only ever OPENS, and asks `ResearchHomes`, never existence or a path prefix**.
- **Arrival is visible** (`consumingTreeScrollRequests`, both triggers): `TripwireGrepTests.test_everyBinderTreeHostConsumesTheScrollRequest`.
- **Research is the book's or a piece's: every tree surface and the gate ask `ResearchHomes`**; a fold row tags `TreeRowTag.inFold`.
- **New Group at a piece's root has no store API** (`ResearchScope` routes notes, tables, assets, links; *New Table* is `ResearchTree`'s, not offered on a view-only share).
- **A drop is classified by LOOKUP, never by an id's shape**, at every target (`TreeDropIntentTests.test_theGridCanTellALookupApartFromAGuessAtTheIdsShape`, `TripwireGrepTests.test_everyDropTargetInTheTreeReachesTheClassifier`).
- **External drops route through `TreeDropIntent.classifyExternal`** to the same creation verbs as Add File and paste.
- **A drop target's hover asks its drop's own rules at `DropIntent.Position.of`** (`dropAnswers`, `TreeCanvasRowDrop.verdict`); its dashed look is no standing mark's (`TreeDropFeedbackTests`).
- **Every drop closure returns `Bool` to its `.dropDestination`**: `TripwireGrepTests.test_everyDropDestinationInTheResearchSurfacesDeclaresItsBool`.
- **`TreeSectionDerivation` takes manifest values only** (`TreeSectionDerivationTests`).
- **Link Research… is offered only where `researchRouting(for:)` answers `.sharedPlusLink`** (`ResearchLinkPickerTests`).
- **`TreeScrollProbe` installs only in a dev build outside xctest** (`MAUGHAM_TREE_SCROLL_PROBE=0` disables it).

### Research subjects and the palette wall
*Why each rule: [`docs/history/views.md`](../../docs/history/views.md).*
- **A subject may only reach a column the writer can point somewhere else again from**: `ProjectSubjectReachabilityTests.test_aNoteBesideCanBePutAwayFromItsOwnRow`.
- **A research item `beside` shows in the right column whatever the centre; `open` takes the centre** (`ResearchSubjectRoutingTests`).
- **Both columns route a research item through `researchCentreRoute`** (`test_bothColumnsAskTheSameRoutingFunction`).
- **A piece in read-through reads its own research and figures** off `ReadThroughGate.refusesEdits`, beside the posture; a figure's pieces are its record's and its lines'; every refusal names the piece (`ReadThroughGate.refusal`; `ReadThroughResearchSurfaceTests` counts both).
- **A placement is not a mount**: the subject's observer shows the pulled-up position when something arrives beside; a restore does not. A figure asks `figureSubjectPlacement` in both columns.
- **The Figures section** is drawn only while a figure is not parked; a piece's count filters it, its header chip clears it.
- **The tree's cards come from its own `FigureCardCache`**, never the editor's.
- **A drag onto Figures or Research is classified by `TreeDropIntent`, never in the row.** Research onto Figures is `useInDocument`, unasked; a figure onto Research or a group asks once (`PendingFigureSend`) and cannot be undone. Figures take no figure-on-figure drop.
- **A legacy row is listed, never selected**: *Move into Figures* dry-runs the line, makes the figure, then `retargetFigureLine`s it; a parked copy named otherwise than the line's label is refused.
- **The figure listing lives at window level** (`ReferenceIndexHost`, `FigureListingModel` in `ProjectWindow`), so rows need no mounted editor.
- **The palette wall is the subject's `open == .palette`, asked only through `showsPaletteWallCentre`** (`PaletteWallDoorTests.test_thePaletteIsComparedOnlyInTheOneQuestion`).
- **Any subject change that takes `open` off the palette closes the wall and restores the inspector** (`PaletteWallState.applyPaletteWallChange`, in `PaletteWallModifier`); the wall's own Close returns to the subject it was opened over (`closingWall`).
- **The Palette row is the wall's door**; nothing travels.

### Layout and sizing
- **A pane's growing content compresses or scrolls THAT pane, never raises the window's minimum height** (`ProjectWindow.windowHeightFloor`, 540): `TreeScrollStabilityTests.test_theWindowsMinimumHeightIsProjectWindowsOwnFloor`. `.doesNotRaiseTheWindowFloor()` measures the first subview only.
- **A strip in a non-scrolling pane stack demands its height as a MINIMUM**; bound inline content with a ceiling (`BoundedHeightLayout`, `ReviewRoundCockpit.letterDisclosureMaxHeight`) (`ReviewRoundCockpitLetterScrollTests`).
- **No control on a narrow-column toolbar carries writer-typed text on its critical path; labels are icons**, with the name in `.help`. `.frame(maxWidth:)` does not bound a `.fixedSize()` label's ideal.
- **Every `ViewThatFits` variant is reachable in range; the last, drawn regardless, fits** (`RightColumnPaneWidthTests`). Measure with `NSHostingController.sizeThatFits(in:)`, never a frame walk.
- **Every `RightColumn` arm fits the floor less `RightColumn.resizeHandleWidth`, no `minWidth`** (`RightColumnPaneWidthTests`), leading-clipped; the lists it names hide their background.
- **A long unbreakable string truncates in the middle, whole in its tooltip; its row declares an ideal width** (`SetAsideRecordsDisclosure`, `HeldLineNoticeRow`).
- **No `fixedSize` on a header menu** (`DiagnosticsPaneColumnHeightTests`).

### Events, modals and sheets
- **Pick an event's scope at the post site** **and subscribe with the matching helper** (`.onKeyWindowCommand`, `.onProjectEvent`, `.onGlobalEvent`); never hand-roll a filter in a receiver ([ADR 0021](../../docs/adr/0021-scoped-window-events.md)).
- **A pane that needs its window's liveness resolves it through `WindowAccessor`**, never a cached `NSWindow?` read as "closed" when nil (`MaughamEvent.isLive`).
- **Modal state is owned by the window**: subviews post (`.maughamOpenRewind`) and the window presents.
- **A `.keyWindow` post from inside a sheet is dropped** — the sheet's window holds key until after `onDismiss`. A sheet's hand-off records the press and the presenter acts through `ProjectWindow.pullUp`.
- **The window's one `.sheet(item:onDismiss:)` fires one callback for every sheet**, so `FirstReaderHandoff` acts only when Project Settings closed, and every presentation clears a standing request.
- **Show one sheet per stranger, sequentially, with `queue` and `presented` held apart**: swapping a presented `sheet(item:)` to another item in one pass drops the second sheet; the next goes up from `onDismiss`.
- **A context-menu verb is also drawn as a visible control**. Verb wiring inside a `Menu` is censused from source, never pressed.
- **New Project's kind is a menu, and a Report asks its shape beneath it**, worded by `ProjectKindName`. **Project Settings' Report section is the pure `ReportSettingsModel`**, written only through `ProjectStore.setProfile`/`setSwitch`: absent for a screenplay, disabled with the reason for a Collection or a newer build's profile.

### Posture surfaces
- **Hide, don't disable**: a verb the posture forbids is not drawn. The editor stays and refuses mutation; the File menu's piece items disable (a menu-bar item greys).
- **Each verb's offer is a pure value pinned in `PostureSurfaceTests`** (`AnnotationRowVerbs.decide`, `AnnotationBulkActions.offers`, `ReviewCardActions.actions(for:isOwn:posture:)`, `PassLadder.offersRulings`, `StatementSurfaceVerbs.offered(under:)`, `TurnClauseOffer.mayFile`, `LessonOffer.mayWriteTheLedger`, `ResolvePane.findingOffers`/`offersNotThis`, `TreeStructureVerbs.decide`, `TaskRowVerbs`, `TranslationAuthorVerbs`, `HistoryPane.offersRevert`).
- **A queue row asks ITS OWN document's posture**, never the window's selection; a statement asks the statement's own (its piece's, or the book's); the letter asks the destination statement's.
- **A nil posture draws the fail-closed card**: her own note's Edit and Delete, no disposition.
- **The standing line is keyed on `reason`, never `isRestricted`**; Edit Anyway is `DocumentStore.overrideYield(docId:)`, per window, per piece, for the session.
- **Find asks the posture once per document per body pass** (`ProjectSearchView.ReplaceGate`).
- **A refused press is said in words, never swallowed with `try?`** (`ResolveNoteVerbs.sayRefused`).
- **No `static let/var <name>IsAvailable` gate is left standing in production**: a constant gate feeding `.disabled(!…)` is dead code (`TripwireGrepTests.test_noAvailabilityFlagIsLeftStandingInProduction`).

### The register's surfaces
- **Every decision about who may write is the MODEL's, as a pure function** (`AdmissionDecision`, `PeopleAndDevicesModel`, `ClaimDecision`, `LoadQuestions`, `SetAsideDoor`); the views draw and decide nothing (`PeopleAndDevicesModelTests`, `AdmissionDecisionTests`, `AdmissionQueueTests`).
- **A merge is never the default**: a proposed label never merges into an existing person, and the pre-fill (`claimedLabel`) is never a known label.
- **A device with no proposed name keeps Admit refused until the writer types a label.**
- **Who is never offered is one classification**, `AdmissionDecision.standing(ofHolder:streams:registry:)`; a stranger's device record raises the question as a held line does, as one request.
- **A claim hint asks `Recognition.recognise`, never a second opinion**; the saved-by name never pre-fills or merges.
- **A narrowing rung asks the book its cost before Admit is pressable** (`AdmissionModifier.checkTheBook`), detached; a book that cannot be read says nothing it cannot stand behind.
- **`Permit.rung(of:)` answers nil for a permit a later build wrote; never draw that as a rung.**
- **Admit… in People & Devices posts and dismisses the settings sheet**: a sheet presents no other sheet.
- **The admission's dismissal memory resets when the `DocumentStore`'s identity changes**: a closed scene's modifier `@State` outlives `onDisappear`.
- **The inbox recount runs on a registry settle, never a document open.**
- **The admission and new-piece questions are asked only on a Mac holding the book's own root record** (`AdmissionDecision.askingRoot`).
- **The admission queue is built from `DocumentStore.heldLinesByDevice()`** (open docs, closed docs' swept provenance, and the capture stream), never from open documents alone; People & Devices reads the same derivation.
- **`recompute` admits before it asks**: recognised devices, then remembered ones, then re-read, then resolve the registry (`AdmissionDecision.refreshedRequests`).
- **`.maughamAdmissionRequested` may raise a sheet; `.maughamAdmissionSettled` must never** — two events, never one with a flag.
- **A vanished request takes its sheet down**; pressing Admit on a settled record would relabel it.
- **`AdmissionDecision.refusal(_:)` is the one place a `RegistryAdmissionError` becomes a sentence**, exhaustive with no `default`.
- **A refused verb keeps its disabled button with the reason in tooltip and `accessibilityHint`**; a root's row draws no Revoke.
- **Only the root that admitted a person may revoke or rename them.**
- **Merge is disabled on a Mac with no root of its own; Forget This Person Key is drawn only where `Person.mayForgetPersonKey`.**
- **An adopted root is drawn as *merged*, never also as a claimant; a record outside the chain is never named.**
- **A multi-record group compares `PermitWords` sentences for display, never rungs.**
- **`ClaimDecision.offer` answers nil unless this Mac has no root, the book has one, and this Mac can sign and write the registry.**
- **An unreadable registry draws the read's refusal sentence and no rows** (RULING-54).
- **Restore of a malformed record is a press, never automatic**, through `RegistryCache.restore(_:in:)`.
- **People & Devices presses `DocumentStore.changePermit(everyRecordOf:to:)`, never the single-record verb**: `TripwireGrepTests.test_noViewPressesTheSingleRecordPermitVerb`.
- **The claim sheet is presented from People & Devices alone**; no Mac is asked at open (`ClaimDecisionTests.test_theClaimSheetIsPresentedFromPeopleAndDevicesAlone`).
- **The saved-by key is read by `SavedByReader` only**: `TripwireGrepTests.test_theSavedByKeyIsReadBySavedByReaderOnly`.
- **A §7.4 door offers what is LEFT, remembered by lines** (`<opId>#<paragraphId>`), never by holder.
- **The Deleted section's Restore is decided by key** (`AnnotationRowVerbs.restoresDeleted` over `Document.restoreStanding`).
- **The person key's surfaces stay dark in a Debug or ad-hoc build**: the keychain reads unavailable there.

### Review: the queue and the board
- **The board and the edition head take values and closures, never a store**; every verb is the MOUNT's.
- **A chip click navigates the subject and `recordActivePass`**; a count click opens To resolve on the Book with the piece's group focused and leaves the subject (`ReviewBoardRoutingTests.test_theCountIsWiredToTheQueueAndDoesNotMoveTheSubject`).
- **`ProjectWindow.recordActivePass(forPiece:passId:)` is the window's one `ActivePassMemory` writer**; the columns receive it as a closure.
- **A round is a stage's or it is refused** (`RoundEditor`); the empty queue names the round the button would run.
- **A chip's round waits for the piece to open** (`RunWhenDocumentOpens`, bounded, then a flash).
- **`refreshOpenNotes` is the one writer of the open-notes counts**, from the board's `.task` and `.maughamAnnotationsChanged`, never a body, reading the aggregation once.
- **The per-piece pass-state writers are the files in `PassStateWriterCensusTests.passStateWritingFiles`** (`type:CentreColumn`, `type:RightColumn`); the nudge's buttons thread to an existing site. `setReviewPasses` writes the list and is deliberately not a member.
- **`StatusSwatch` is the one place a status becomes a colour.** `StructureItem.status` is a legacy read fallback, never written.
- **Reorder rows with `.draggable`/`.dropDestination`, never `.onMove`**, which misfires in a macOS `List(.sidebar)`.
- **An open-notes cell draws nothing for zero, and an em dash that is not a button for an unreadable piece**; reference rows get no chip verbs and no count.
- **A bulk verb reaches exactly where the row's own verb reaches**: a stale suggestion and a `.query` are out of accept. The executor opens no undo group (ADR 0023) and collects refusals into one alert.
- **Bulk acts on the open piece only.** To resolve holds the walks (`ResolveWalkHold`); open pieces splice live.
- **A row's click in a Book or Part list keeps the faces** (`ClickRule.openInsideTheFaces`).
- **Inside a group, notes take `AnnotationQueueOrder.sorted` (Do first)**; it does not change the deriver's projection.
- **To resolve filters by source chip (`ResolveFilter`), view-side**; `AnnotationFilter`'s shape reaches MCP and never widens.
- **A note has one source** (`ResolveFilter.source`): unstamped is Mine or Others, a coach-lane note its own pass; never another pass.
- **The nudge keys on the RECORDED active pass and takes no filter argument**, document scope only.
- **A held triage mark is checked and disabled**; re-applying appends an op whose ⌘Z undoes nothing visible.
- **Four resolutions — Accept / Reject… / Stet / Archive — with Stet offered wherever Archive is; triage is a mark, not a resolution.** `AnnotationRow.showsReopen` is an exhaustive switch, so a new status must decide.
- **A figure note's row acts through the figure's host** (`FigureRowGate`, `withFigureHost`): Reject, Stet, Archive, Reopen, Got it and Reply work; a suggestion's Accept travels to its cell (off once deleted or in Research); ⌘Z only where the window holds the figure. A piece's figures follow its section; the board counts them on `FigureRecord.piece`.
- **`ResolveScope` is derived from the faces**; the Book lays out by `TreeWalk.collect` and skips reference pieces.
- **The cockpit reaches for the coach's seat nowhere** (`ReviewRoundCockpitTests.test_theProductionMountNeverReachesForTheSeat`); with no pass, both run buttons disable with `noEditorReason`.
- **A wide pass set scrolls inside the board** (`ReviewBoardPaneTests.test_aWidePassSetScrollsInsideThePaneAndNeverWidensTheWindow`).

### Statements, the letter and rulings
- **A statement host mounts `EditorSurface`, never `EditorHost`**, with the sanctioned binding; it is a second editor in the window (`Maugham/Editor/AREA.md`, "Two editors in one window").
- **Text goes through `StatementTextTarget`, and the pre-file draft is keyed by scope** (`StatementDraftHandoffTests`).
- **A load is refused on both sides of `Document.load`**: `gateArrival` before (is this statement already bound?), `loadMayBind` after (does the pane still want this scope?). Neither refusal drops the WORDS: each deposits them into that scope's file.
- **The rulings verbs take `kind` undefaulted, before scope**: a brief and the craft intent share `.project` scope.
- **"Carries rulings" and "is the bible" are separate questions** (`StatementEssay.carriesRulings`, `BibleStratum.belongsTo`).
- **`liveParagraphIds == nil` is UNKNOWN and manufactures no orphan**; the `.task` resolving it is keyed on the directive ids AND the open documents' paragraph sequences.
- **`RulingsStratum.partition` returns plain `[Ruling]`**, so a row re-derives its index in the ORIGINAL array before `revoke(_:at:)`/`edit`.
- **A proposal slot is read in a `.task` and on `.maughamStatementProposalsChanged`**; Adopt writes into the pane's live `Document` when one is bound.
- **The statement host is not remounted on a scope change, so every `@State` on it outlives one**: clear per-scope state in `reconcile`/`leave()`.
- **A picture dropped into a scope with no statement leaves the empty draft showing until the pane is next opened there**; never bind the pane to close that gap.
- **Visual language takes pictures; intent does not** (`StatementImageIngestTests.test_intentTakesNoPicturesAtAll`). The drop target is a well BESIDE the editor, never over it.
- **A finished ingest names its destination** (`ProjectStore.appendToStatement` on the returned `Statement`); it never reads view state.
- **A ruling is written FIRST, then the annotation op**, so a refusal cannot settle a note whose decision was lost (`QueryRuling`, `FirstReaderRuling`, `QueueLedgerVerbs`).
- **`RulingDestination` is the one decision the row, sheet and commit all ask**.
- **The second stet searches the whole project's UNFILTERED list** (`Document.annotations()` defaults to open); Escape on its dialog abandons.
- **`FirstReaderRuling` is the only file that names `.firstReader` to `RulingPerformer`**: `TripwireGrepTests.test_theFirstReadersStatementIsWrittenFromOneFile`.
- **`LessonLedgerVerbs` is the only file that writes the ledger**: `TripwireGrepTests.test_theLessonsLedgerIsWrittenFromOneFile`. Retire edits in place, never revokes; filing is find-or-create by heading.
- **A habit's ledger heading is `Letter.Habit.ledgerHeading`'s answer**, so one habit has one identity.
- **The letter's two writing verbs are shared by both hosts** (`ReviewRoundCockpitTests.test_bothHostsKeepThroughTheOneVerb`); research-note filing callers are `TripwireGrepTests.test_filingAResearchNoteHasAKnownSetOfCallers`.
- **`freshEyes` is a stated input, never inferred from wired closures.**
- **A refused write clears the press memory** so the control comes back, and each verb has its own failure line.
- **The cockpit letter's voice is the standing round's own pass**, never the selected one (`ReviewRoundCockpitTests.test_theLettersVoiceIsTheStandingRoundsOwnEditor`).
- **`DraftStage.laneWord` is read in `LetterKeep.swift` and `LetterSection.swift` only**: `TripwireGrepTests.test_theStageWordIsReadFromTwoViewFilesOnly`.
- **On-screen copy is the writer's register, never the schema's.**
- **A text field that writes a file commits on submit, focus loss, Done and `.onDisappear`, never per keystroke**, behind a trimmed `nameNeedsCommitting` guard; `AskField` likewise, taking its verbs as one `AskField.Input`, never starting a run.
- **The coach's Vacate / Restore calls `setCoachVacated` directly; the coach is never in `setReviewPasses`'s array.**
- **A `ReviewPass.id` never changes on rename**; a deleted pass's `passStates` linger and reappear on re-add.
- **`DocumentStore.setAuthorReaderChoice` is the reader choice's one writer.** Describe… asks the manifest's statement, never `FirstReader.statement`.
- **The Diagnostics reader menu offers a reader only while their premise stands**, and its check follows the RESOLVED choice; nothing in it travels.
- **A standing run's letter is signed `run.readerName ?? reader.editorName`**; the header reads the live reader.

### Publish and translation
- **An unreadable catalog is never presented as empty**: its own notice names the file (RULING-7). The notice banner takes no hits.
- **`PublishPreviewResolver.readablePDFs` is both the picker's rows and the drawn book**; the pick is never persisted.
- **`PublishPreviewModifier` is the resolution's only writer.**
- **A proposal is a VALUE read once**, cleared on any change of `open` *before* `PublishPreviewModifier`'s edition guard, so leaving the edition clears it.
- **An edition's rows call the round report's and the gate's verbs**; round verbs rewrite the stored record (`TranslationRoundStore.mutate`) and announce it; filing settles.
- **Name, Add Language and Rename are asks of one sheet** (`EditionCastVerbs`; the cast on its edition's Brief, asked of that brief's posture); a language the book has says so and stops.
- **A run's gate reads the pipeline first** (`TranslationRunSession.read`).
- **An unlisted language's first Run asks for a name.**
- **Run Whole Book runs the imprint's `scopedDocumentIds`.**
- **A language tag is lowercased before it is judged, unioned or sent.**
- **Design pre-flight asks the briefing's own gates** (`PublishStarter.isInitialized`, `publishablePieces()`), never a second disk probe.
- **A refused run verb is disabled with its reason, except Show, which hides.**
- **Gate refusals are read from the error types, never recomposed** (`DesignGate.refusalSentence`); Finalize confirms; nothing on the gate reaches `NSUndoManager` (`DesignGateTests.test_nothingAboutTheGatesVerbsReachesTheUndoManager`).
- **A verb answering from a `Task` updates the surface only if the same proposal / round is still on it** (`PublishCentreModel.adoptVerbAnswer`).
- **The round report is pure rows and copy; the host does all disk work in `.task`.** Its verbs are closures on `TranslationRoundActions` with a standing `notWired` refusal; count them on the type.
- **The report's and the problems list's `onReveal` clear their own selection**: neither arm is project-level, so no subject change does.
- **The report host takes its window**: a nil-window subscription never fires (`MaughamEvent.isLive(nil)` is false).
- **A skipped leg and a failed query read are drawn as themselves**, never as good news (RULING-7).
- **The gate's verbs are a pure function of the proposal's status** (`DesignGate.verbs`); a verb posts `.maughamDesignProposalsChanged` so To resolve re-reads.
- **A dismissed departure is a separate fact from the pipeline's outcome.**
- **The reveal waits for the translated surface between its two posts** (a source reveal, `language == nil`, waits for the source), and a pending reveal is taken on the next `activeDocId` change: `TripwireGrepTests.test_theTranslationRevealIsPostedByTheReportArmAndHandledByTheWindow`.
- **A piece read in a language is a To resolve scope**, never a pane; a spot-check answer belongs to its paragraph. The reveal's `revealTask` is cancelled `.onDisappear`.

### History, recovery and rewind
- **`HistoryPaneVerbs` is `documentStore.sendHeldWordsToInbox(`'s one counted caller** (tripwire 50, `TripwireGrepTests.test_theP3bCountedListsAreExactlyTheNamedArrays`).
- **Every History notice is a `static`**, pinnable without mounting; count them, never a number in prose.
- **History performs no load of its own**: provenance counts are read off the open `Document`.
- **Disk reads happen in `reload()`, never `body`** (tripwire 4).
- **History reloads on `.maughamQuarantineRecordsChanged`, and resolves events and banners in ONE off-actor `reloadChain` read.**
- **Set-aside counts CHANGES** (op lines, deduped by identity, minus applied ops), asked once over every record and grouped by reason afterwards; acknowledging puts down the sentence, never the forensics.
- **The project section's events are pure**, at the top of the timeline, never interleaved, and no sentence carries a date. Count `TrustEvent.Kind.allCases`, never a number in prose. `readUnsigned(…, onlyIfNarrowed: true)` is a cost rule.
- **Append to End lands orphans against the OPEN document only.**
- **The recovery models own behaviour; their views are thin** (`RecoveryPaneModelTests`, `RecoveryBannerTests`).
- **Recovery pollers are cancelled in `onDisappear` / `stopWatching`**; the pane is mounted `.id(ObjectIdentifier(paneModel))`.
- **The pane auto-opens; the banner only offers a reopen**: an open read-only view is never yanked away.
- **Both minted recovery actions check `recoveryActionIsCurrent` before acting** (`EditorHostRecoveryActionGuardTests`).
- **Writer-facing recovery copy never says "quarantine"** (`RecoveryPaneModelTests.test_thePaneSaysSetAside_neverQuarantine`).
- **Rewind snapshots the op log at open time, and restores only the post's open piece**; `PartialRestorePicker` never trusts a checkpoint's `activeDoc` to name a document (`CheckpointCapture.documentSubject(of:in:)`).
- **Row rendering branches on the `SynthesisSource` enum, never strings** (tripwire 12).

### Statistics
- **Practice derives in two halves**: `@MainActor` `Plan(store:)` reads the manifest; `nonisolated` `derive(plan:projectURL:now:)` reads every byte on a detached task, cancelling the previous one. No `derive(store:)` convenience.
- **Practice reads CLOSED documents only** (`loadSyncMerged` + `deriveWithSequenceFallback`); an unreadable doc is skipped and named.
- **A Practice row promises only what it can do**: it opens the chapter, never scrolls.

## Recipes

### Add a centre route
1. `Maugham/Views/CentreRoute.swift` — a new surface over the editor is a `CentreCover` case; a new top-level surface is a `CentreRoute` case after `.canvas` — except a subject that takes the centre (`.research`, `.figure`), placed before it by a `*SubjectPlacement` answer for `open`.
2. Same file, `ProjectWindow.centreRoute(…)` — answer it from a named question about the window's subject (composed with `altitudeView` if it is Book-level), never a mode.
3. `Maugham/Views/CentreColumn.swift` — draw it in `editorPane`'s switch, or for a cover in `manuscriptEditor`'s cover switch. Pass values and closures; reach no store from the surface's body.
4. `Maugham/Views/ProjectWindow.swift` — `showsStatusFooter` if the surface hides the document.
5. `MaughamTests/CentreRouteTests.swift` — the product assertion; `ProjectAltitudeCentreTests` if it touches the `ZStack`.

Checks: `CentreRouteTests`, `ProjectAltitudeCentreTests` (host lifetimes), `RegionBindingTests` (one canvas, one `EditorHost(`).

### Add something to pull up
1. `Maugham/Models/PulledUp.swift` — the case and its coding; `PullUpRequest` and an item in `Maugham/MaughamApp.swift` (through `MaughamEvent`) if a key pulls it up; `PieceFoldEntry.pulledUp` if a fold row does.
2. `Maugham/Views/PulledUpView.swift` — its `Face` and arm, and `centreShows` for what the centre may already hold. Read-only unless an editor beside is safe (tripwires 26–28); read-through and posture apply.
3. For the centre's own details instead: a `CentreDetails` case and its answer in `RightColumnContent.centreDetails`, from `open` alone, and its arm in `centreDetailsView`.
4. `MaughamTests/TestSupport/RightColumnFixture.swift` — its kind in `kind(of:)` and `arms`, so the width and height censuses walk it.

Checks: `PulledUpTests`, `PulledUpViewTests`, `RightColumnMountingTests`, `RightColumnContentTests`.

### Add window behaviour (a modifier on `ProjectWindow.body`)
1. A `ViewModifier` in its own file under `Maugham/Views/`, holding its own `@State` and taking the window's state as `Binding`s.
2. One line on `ProjectWindow.body`.
3. If a census reading "the window's code" must see it, add its type to `SourceTree.windowFamilyTypes` (`MaughamTests/TestSupport/SourceTree.swift`).
4. Receive events through the `MaughamEvent` helpers, scope chosen at the post site; declare a new name in `Maugham/Models/MaughamNotifications.swift`.
5. Run a local Release build (`-configuration Release`).

### Add a verb on a posture-gated surface
1. Decide the offer as a pure value over a `Posture` (a static beside the view, or a `…Verbs` type) and pin it in `MaughamTests/Views/PostureSurfaceTests.swift`.
2. Draw it from `DocumentStore.posture(forDocId:)` of the row's own document; hide it when refused.
3. Act through `settledPosture(forDocId:as:)` and the store or `Document` door, and say a refusal in words.
4. If it writes manuscript text outside the editor, add the call to `TripwireGrepTests.manuscriptWriterCallSites` with its gate (`Maugham/OpLog/AREA.md`, "Add a permit-checked writer").
5. If it hides in a `.contextMenu` or `Menu`, draw a visible control; census the wiring from source.

Checks: `PostureSurfaceTests`, `TripwireGrepTests.test_postureIsAskedOfThePermitInOnePlace`, `test_aPermitRungIsComparedOnlyInThePermitLayer`.

## Pointers
- `docs/history/views.md` — the old guide verbatim: each rule's why and origin.
- ADRs 0035–0038 (the shell: subject, To resolve, Brief, Status and editions); 0021 (window events); 0023 (undo); 0030 (the round report, the reveal); 0032 (posture surfaces).
- `docs/tripwires.md` rows 2–7, 9, 14–16, 21, 22, 33, 43, 47, 49–52, 55.
- Specs: `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md`, `docs/superpowers/specs/2026-08-08-shell-finish-design.md`.
- Neighbouring guides: `Maugham/Editor/AREA.md`, `Maugham/Canvas/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/OpLog/AREA.md`, `Maugham/Compiler/AREA.md`, `Maugham/Publish/AREA.md`.
- Tests worth knowing: `EditorIntegrationHarnessTests`, `CentreRouteTests`, `RightColumnMountingTests`, `ProjectSubjectReachabilityTests`, `PostureSurfaceTests`, `RewindDensityTests`, `RewindEntryPointsTests`, and the Views censuses in `TripwireGrepTests`.
