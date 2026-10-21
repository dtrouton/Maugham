# Views — area guide

The SwiftUI view layer of the project window and the app's other windows. The one rule from CLAUDE.md: **ask `Posture` what to offer; never compare a permit rung (tripwires 47, 51).** The area carries tripwires 2–7, 9, 14–16, 21, 22, 33, 43, 47, 49–52 and 55.

## Map

Every file in `Maugham/Views/` appears once, plus the `Maugham/Models/` files CLAUDE.md routes here. **→ Compiler** / **→ Canvas**: that guide's Rules also govern the file (search for its name or types).

### The window family
- `ProjectWindow.swift` — the root view: `body`, the window's `@State`, the pure static decisions (`showsStatusFooter`, `publishCentre`, `inspectorRoute`, `canvasCollapse`, `pressPaletteWallDoor`), `binderColumn`, `detailColumn`, the session lease, and four modifiers: `TopChromeModifier`, `PaletteWallModifier`, `SessionAndNavigationModifier`, `CollectionPieceModifier`.
- `CentreRoute.swift` — `CentreRoute` and `CentreCover`, and `ProjectWindow.centreRoute(…)`: what the centre column shows, as one exhaustive value (tripwires 6, 27, 30).
- `CentreColumn.swift` — the centre column: one `switch` over `centreRoute`, the canvas's one mount (with `CanvasReadOnlyNotice` in a top `.safeAreaInset` over a refused layout file), `manuscriptEditor` (the `EditorHost` + altitude + one cover `ZStack`), the board's open-notes counts and `refreshOpenNotes` (tripwires 2, 6, 30).
- `RightColumn.swift` — the right column: resize handle, study arm, inspector arm (`researchOrSubject` → `inspectorRoute`), hidden arm, and its environment's services.
- `PaletteWallState.swift` — the wall's window state as one value (`showsWall`, `travelPending`, the inspector stash) with its three folds as mutating methods.
- `Maugham/Views/Publish/PublishCentreModel.swift` — what Publish's centre shows, and every rule for changing it as a named method (`publishSelection(after:)`, `adoptVerbAnswer(_:)`, …).
- `ProjectActiveSheet.swift` — the window's one sheet enum.
- `WindowFlashes.swift` / `CompilerFlashSink.swift` — the window's acknowledgments in one `@State`; ⌘R's capsule as a value a suspended caller can hold.
- `CheckpointModifier.swift` — ⌘S / ⌘⇧S delivery; `CheckpointFlashDecision`.
- `RewindModifier.swift` — the `.maughamOpenRewind` receiver and the rewind sheet.
- `PersonaModifier.swift` — the `.maughamSetPersona` handler and `applyPersonaChange`.
- `FocusPostureModifier.swift` — ⌘\ no-chrome and ⌘⌥⇧R review posture.
- `ParagraphNavModifier.swift` — `.maughamNavigateToParagraph` / `.maughamNavigateToScene` receivers.
- `CanvasCollapseModifier.swift`, `CanvasPromotionModifier.swift`, `CanvasClaudeArrivalModifier.swift` — ⌘\ collapse to the canvas; Promote…; Claude's arrival banner and its Show. **→ Canvas** ("`⌘\` gives the canvas the window").
- `TranslationReviewModifier.swift` — this window's translation-review selection and the reveal's window half.
- `EditorControlMirror.swift` — `EditorControlMirror` (the editor's membrane, from the posture, pure), `InsertMenuGate` (whether the Insert menu is enabled, published as the focused value `mayInsertReportElement`) and the modifier.
- `NoteOutcomeAlert.swift`, `ContainerWidthReporter.swift` — the translator's-note outcome alert; a width reporter.
- `CompilerRunModifier.swift` — the run keys' delivery path and the session's teardown (`roster.shutdownAll()`). **→ Compiler**
- `AdmissionModifier.swift`, `NewPieceModifier.swift` — the window's halves of the admission and new-piece questions (below).
- `SubjectValidationModifier.swift` — keeps the subject naming a row that still exists; keyed on the structure.
- `ResearchRevealModifier.swift` — an arriving research subject in Plan reveals the column that shows it.
- `WindowAccessor.swift`, `WindowEscapeArbiter.swift` — the hosting `NSWindow` (cached; never re-nils); one Escape monitor per window, in a fixed priority.
- `WindowFloorFree.swift` — `WindowFloorFreeLayout` / `.doesNotRaiseTheWindowFloor()`: a pane may not raise the window's minimum height.
- The window borrows a `ProjectSession` from `ProjectSessionRegistry` (a `.window` lease) and reaches its `claude` services through its `AgentRoster`: `Maugham/Stores/AREA.md` ("Project sessions").

### Personas and the shell
- `PersonaBar.swift` — the four-persona switcher, a window-toolbar item; posts `.maughamSetPersona` exactly as ⌘1–4 do.
- `ManuscriptNavigation.swift` — where a navigation to a manuscript document decides the persona.
- `TreeTravel.swift` — the double-click travel rule (`treeTravelDestination`, `treeTravelOnDoubleClick`, `TreeTravelModifier`, `TreeTravelClickWatcher`).
- `AssistantColumn.swift` — the study column (`AssistantColumnModel.studied`, `isPresented`, `AssistantColumnModifier`).
- `IntentStrip.swift` — the writer's signature line above the prose.
- `ReviewModeIndicator.swift`, `TranslationReviewIndicator.swift` — the pills over the editor in review / translation review.
- `SaveFlashOverlay.swift` — the ⌘S muscle-memory capsule.
- `MCPBannerModel.swift`, `MCPNoteBanner.swift` — the transient "Claude added a note" banner.
- `BackupRecoveryBanner.swift`, `ManifestRestoredBanner.swift` — the refused-backup banner (Restore); the put-back-manifest note.
- `SharingStatusPill.swift` — *Shared* / *Shared by <owner>*: an indicator, never a role.
- `ViewOnlyShareNotice.swift` — the banner over a read-only iCloud share (`ProjectWindow.shareIsReadOnly`).
- `ProjectShareSheetPresenter.swift` — File → Share Project via iCloud… (`NSSharingServicePicker`).

### The left column: the tree
- `BinderPaneToggle.swift` / `CollectionBinderPaneToggle.swift` — the two left-column shells (`ProjectWindow.BinderShell`): find overlay, one tree, Exports footer, the trash's foot.
- `BinderView.swift` — the novel / short-story tree; `TreeStructureVerbs` (the tree's posture-gated structure verbs); `linkResearchVerb`.
- `SceneNavigatorPane.swift` — a screenplay's tree: the script row and its sluglines.
- `ScreenplayScriptSource.swift` — the parsed script the left column shows when no editor is mounted to parse it.
- `CollectionPiecesPane.swift` — a Collection's flat pieces tree; `StartAPieceDoor`.
- `BinderRow.swift`, `PieceRow.swift`, `ResearchRow.swift` — the tree's row views; the inline-rename shape (tripwire 16).
- `ProjectRowLabel.swift` — the label every project row draws.
- `BinderTreeSections.swift` — the Research and Palette sections at every tree's foot; `BinderTreeSectionsState` (selection, disclosure, `reveal`, `scrollRequest`), `BinderTreeSelection`, `BinderTreeVerbs`, `TreeScrollTarget`, `BinderTreeSectionsPresentations`, `.binderTreeSections(…)`, `consumingTreeScrollRequests`.
- `BinderPieceFold.swift` — a piece row's fold onto its own research.
- `TreeSectionDerivation.swift` — pure derivations: `sharedResearchRoots`, `pieceFold`.
- `TreeDropIntent.swift` — what a drag onto the tree means (`classify`, `classifyExternal`).
- `BinderTreeDrops.swift` — performs what `TreeDropIntent` decided (the `route…Drop` family).
- `DropIntent.swift` — top/middle/bottom drop position → structural action.
- `DropClassification.swift` — one dropped `NSItemProvider`: file URL over image data.
- `ResearchTree.swift` — the recursive research node (`ResearchTreeNode`, `ResearchTreeActions`, `ResearchSelectionSync`).
- `ResearchPasteImporter.swift` — ⌘V into research (`TreePasteRouting`).
- `ResearchLinkPickerSheet.swift` — "Link Research…" on a document row.
- `AddResearchLinkSheet.swift` — the Add Link sheet.
- `TrashView.swift` — the trash list and `TrashDisclosure`, the tree's foot.
- `RemovedElsewhereDisclosure.swift` — pieces removed on another Mac, with Restore, at the tree's foot.
- `ProjectSearchView.swift` — Find in Project, an overlay of the tree; `ReplaceGate`.
- `TreeScrollProbe.swift` — a dev-build-only diagnostic.

### Research and the palette
- `ResearchSubjectColumns.swift` — what each column does with a `.research` subject: `researchSubjectPlacement`, `researchCentreRoute`, `revealResearchColumn`, `ResearchSubjectCentre`, `ResearchSubjectInspector`.
- `ResearchNoteEditor.swift` — the research-note editor (`lockEditing` for read-only).
- `ResearchNotePreviewPane.swift` — rendered Markdown preview of a note, inline images included.
- `ResearchPreview.swift` — routes an item to its preview by kind.
- `Maugham/Views/research/AudioPreview.swift`, `Maugham/Views/research/ImagePreview.swift`, `Maugham/Views/research/LinkPreview.swift`, `Maugham/Views/research/PDFPreview.swift`, `Maugham/Views/research/TextPreview.swift` — per-kind previews.
- `InspectorResearchPanel.swift` — title, caption, tags, URL and citation editor for a research item.
- `NewResearchNoteSheet.swift` — title prompt for a new note.
- `Maugham/Views/Palette/PaletteWallView.swift` — `PaletteWallCentre`, the full-column grid of palette cards.
- `Maugham/Views/Palette/PaletteCardTile.swift` — one card on the wall; no I/O in `body`.
- `Maugham/Views/Palette/PaletteCardEditor.swift` — the visual palette-card editor, one debounced persist.
- `Maugham/Views/Palette/PaletteCardReadView.swift` — `PaletteCardReadView` / `PaletteCardReadHost`, one card read-only.
- `PalettePickerSheet.swift`, `PromoteTargetPickerSheet.swift` — the inbox's Promote to Palette Card… / Promote to Research for… pickers.
- `ReferencesPane.swift` — the shelf (⌘⌥E): what this piece is pinned to.

### The centre's editor and altitude
- `EditorHost.swift` — mounts the editor on the subject's document; the single-binding contract (tripwires 2, 3, 6, 7, 22); the recovery pane wiring and `recoveryActionIsCurrent`; `quarantineAndContinue`.
- `DocumentRecoveryPane.swift` — `RecoveryPaneModel` and the refusal pane before a document opens.
- `RecoveryBanner.swift` — `RecoveryBannerModel` and the banner over a read-only open document.
- `ProjectAltitudePane.swift` — the project at altitude (corkboard / outline) in the centre column.
- `CorkboardGrid.swift`, `OutlineTable.swift` — altitude's two layouts; `OutlineTable` reads the writers once.
- `ReferencePlaceholderCard.swift` — the centre's placeholder for a Collection's reference piece.
- `EditorStatusFooter.swift` — the status row under the editor.
- `ReferenceIndexHost.swift` — the window's cached `ReferenceIndex`, its token listing and parse off the main thread; `EditorHost` owns it.
- `TableGridEditor.swift` — Edit Table…'s grid sheet over a pure `TableGridModel`, and the presenter `EditorHost` awaits.
- `StatusSwatch.swift` — the one place a `ReviewStatus` becomes a `Color`.

### The right column's panes
- `DetailPaneToggle.swift` — the pane picker and `segmentContent`, the exhaustive per-`DetailSegment` arm.
- `InspectorView.swift` — the selected document's inspector.
- `PieceInspector.swift` — a Collection loose piece's inspector.
- `ReferencePieceInspector.swift` — a Collection reference piece's inspector.
- `InspectorLinksSection.swift`, `InspectorCitationSection.swift`, `InspectorTagsField.swift` (with `FlowLayout`), `IntentAffordanceRow.swift` — inspector sections.
- `PassLadder.swift` — the inspector's per-piece pass ladder; `offersRulings`.
- `TasksPane.swift`, `TaskRow.swift` — the tasks pane (`TaskDropIntent`, `TaskRowVerbs`).
- `InboxPane.swift` — phone captures triage; `InboxByline.swift` — who a capture is from.
- `AdaptiveFilterRow.swift` — the filter row that degrades labels to icons.

### Annotations queue and Review
- `AnnotationsPane.swift` — the queue: rows (`AnnotationRow`, `AnnotationRowVerbs`, `AnnotationRowPolicy`), the cockpit mount, `PassOrderNudgeRow`, `letterVoice`.
- `AnnotationAuthorPresentation.swift` — how an annotation's author is shown; `AnnotationAuthorFilter`.
- `AnnotationBulkActions.swift` — multiselect's plan, honest counts and executor.
- `AnnotationQueueOrder.swift` — queue order and `AnnotationTriageFilter`.
- `PassOrderAdvice.swift` — the advisory nudge.
- `Maugham/Views/Review/AnnotationsQueueToolbar.swift` — the queue's toolbar, measured to fit its column.
- `Maugham/Views/Review/AnnotationScope.swift` — This Piece / All Pieces (`AnnotationScope`, `AnnotationScopePolicy`, `AnnotationScopeSections`).
- `Maugham/Views/Review/AnnotationPassFilter.swift` — the queue's pass filter.
- `Maugham/Views/Review/ReviewRoundCockpit.swift` — the round cockpit strip; `BoundedHeightLayout`. **→ Compiler**
- `Maugham/Views/Review/ReviewBoardPane.swift` — Review's pieces × passes board; `ReviewBoardChipVerbs`, `ReviewBoardOpenNotes`.
- `Maugham/Views/Review/ReviewBoardRows.swift` — the board's pre-order row flattening.
- `Maugham/Views/Review/RunWhenDocumentOpens.swift` — wait for a piece to open, then run its round.
- `ReviewPassEditorLogic.swift` — pure array transforms behind Project Settings' Review Passes editor.

### Statements, the letter and the ledger
- `StatementPane.swift` — the Intent / Visual Language / What I've Learned / First Reader panes and an edition brief; `effectiveScope`, `proposalSlot`.
- `StatementEditorHost.swift` — the statement's editor host; `StatementTextTarget`.
- `RulingsStratum.swift` — the rulings under a statement's essay; `StatementSurfaceVerbs`. **→ Compiler**
- `BibleStratum.swift` — what Claude read off the manuscript, the Intent pane's third stratum. **→ Compiler**
- `StatementProposalBanner.swift` / `StatementProposalDiff.swift` — the proposal gate's view and line diff.
- `LetterSection.swift` — the editorial letter on screen, one view with two hosts. **→ Compiler**
- `TurnClauseOffer.swift`, `LetterKeep.swift` — *Add to intent* and *Keep this letter*. **→ Compiler**
- `LessonLedgerVerbs.swift` — the ledger's three verbs and `LessonOffer`. **→ Compiler**
- `QueueLedgerVerbs.swift` — the queue's two doors into the ledger.
- `QueryRuling.swift` — answer a translator's query as a ruling (`QueryRulingSheet`).
- `FirstReaderRuling.swift` — answer the first reader's note into her statement; `RulingDestination`. **→ Compiler**

### Compiler surfaces (→ Compiler: "Ingest, the sidecar and the mint", "Streaming and the preview", "The derivation trigger and the bible")
- `DiagnosticsPane.swift` — Author's compiler report; the reader picker; `DiagnosticsPostures`.
- `AskField.swift` — Ask about…, one field shape in two homes.
- `CompilerModelMenu.swift` — the depth picker in both homes.

### Publish (`Publish/`)
- `Maugham/Views/Publish/PublishPreviewCentre.swift` — `PublishCentre`, `PublishCentreNotice`, the book preview, the notice banner, `PublishPreviewModifier`.
- `Maugham/Views/Publish/DepartmentPane.swift` — the department desk (⌘⌥K), values in.
- `Maugham/Views/Publish/DepartmentPaneHost.swift` — the desk's disk work and verbs.
- `Maugham/Views/Publish/DepartmentRunState.swift`, `Maugham/Views/Publish/DepartmentDesignRow.swift`, `Maugham/Views/Publish/DepartmentCompileState.swift` — the desk's run, design and compile decisions as values. **→ Compiler**
- `Maugham/Views/Publish/DepartmentCastSheet.swift` — name / add a language / rename on the desk.
- `Maugham/Views/Publish/DepartmentCompileSheet.swift`, `Maugham/Views/Publish/DeskCompileRunner.swift` — the desk's Compile… and its runner.
- `Maugham/Views/Publish/DesignGateView.swift` / `Maugham/Views/Publish/DesignGateVerbs.swift` — the design gate and its four verbs. **→ Compiler**
- `Maugham/Views/Publish/TranslationRoundReport.swift`, `Maugham/Views/Publish/TranslationRoundReportView.swift`, `Maugham/Views/Publish/TranslationRoundReportHost.swift`, `Maugham/Views/Publish/TranslationRoundActions.swift`, `Maugham/Views/Publish/DepartureRow.swift`, `Maugham/Views/Publish/RoundRuleSheet.swift` — the round report: pure rows and copy, view, host, verbs, departure row, *Make it a rule*.
- `Maugham/Views/Publish/PublishProblemsView.swift` — Show Problems' list (`PublishProblems`), each row reveals its paragraph.
- `Maugham/Views/Publish/ExportsListView.swift` — the tree's Exports footer.
- `Maugham/Views/Publish/InspectorPublishSection.swift` — per-piece publish overrides in the inspector.
- `Maugham/Views/Publish/PublishStatusPill.swift` — the compiling pill.

### Translation
- `TranslationReviewPane.swift` — the translation pane (⌘⌥L): queries, spot-check (Gloss / Ask the Collator).
- `TranslationReveal.swift` — a round-report row as a way back into the manuscript.
- `TranslatorsNote.swift` — Translator's note… (⌘⌥C).

### History, rewind, checkpoints, restore
- `HistoryPane.swift` — the forensic timeline, its notices, the project section; `HeldLineNoticeRow`, `SetAsideRecordsDisclosure`. Tripwire 50.
- `RecoveredHistorySheet.swift` — the copyable orphan report with Append to End.
- `RewindWindow.swift`, `RewindTickLayout.swift`, `RewindAction.swift`, `RewindScope.swift` — the per-doc rewind modal, its scrubber decimation, its terminal actions, its scope.
- `PartialRestorePicker.swift` — per-doc vs project picker for checkpoint-row reverts.
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
- `Persona.swift` — the four personas and their predicates (`panes`, `defaultPane`, `centresTheCanvas`, `showsManuscriptDocuments`, `previewsThePublishedBook`, `showsTheReviewBoard`, `editsResearchInTheCentre`, `showsPaletteWall`, `showsExports`, `showsIntentStrip`).
- `DetailSegment.swift` — the right-pane modes, with icon and help text.
- `PersonaMemory.swift` — each persona's remembered right-pane segment, in `UIState`.
- `BinderSubject.swift` — the window's one subject: `.project`, `.item(id)`, `.research(id)`.
- `TreePane.swift` — which tree the left column mounts (`TreePane(for:)`).

## Rules

### Tripwires this area carries
- **No SwiftUI ↔ AppKit two-way sync guarded by flags** (tripwire 2): `.onChange` fires after the flag clears. Every `@State` a column writes arrives as a `Binding`; a copy drifts. Prose only (`Maugham/Editor/AREA.md`).
- **No heavy work inside a synchronous SwiftUI binding setter** (tripwire 3): `EditorIntegrationHarnessTests`.
- **No uncached per-row computation in list rows or on a body path** (tripwire 4): panes take values; hosts do store, disk and walk work in `.task`. Prose only; source censuses guard named panes (`ReviewBoardPaneTests.test_theSourceReadsNoStoreAtAll`, `DepartmentPaneTests.test_theSourceReadsNoStoreAtAll`).
- **No `NSPopover` for editor autocomplete** (tripwire 5). Prose only (`Maugham/Editor/AREA.md`).
- **No parallel observable state on `EditorHost`; one `Binding` writes `displayText` exactly once** (tripwire 6): `EditorIntegrationHarnessTests`.
- **No fourth caller of `EditorSurface.applyExternalText`** (tripwire 7): `TripwireGrepTests.test_applyExternalTextHasExactlyOneProductionCallSite`.
- **No `.onTapGesture` for clickable rows inside `List(.sidebar)`; use `Button(.plain)`** (tripwire 9). A gesture attaches to a row's label leaf, never its container: a whole-row `.simultaneousGesture` ate drag initiation. Prose only.
- **Move or delete user-editable content only through `DocumentStore`'s typed mover** (`relocate(plan:)`, `relocateUserContent(affectedPaths:perform:)`, `trash(relativePath:using:…)`), which closes and flushes before the FS call; never hand-roll it (tripwire 14): `TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover`.
- **A pane that may show a `ContentUnavailableView` chains `.frame(maxWidth: .infinity, maxHeight: .infinity)` on it, and its outer `VStack` takes `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`** (tripwire 15): otherwise the parent centres the pane and the toolbar floats. `TripwireGrepTests.test_contentUnavailableViewAlwaysChainsFullFrame`.
- **A rename-capable row copies `BinderRow`'s shape verbatim**: a `claimFocus()` that sleeps 30ms before focusing, fired from both `.onAppear` and `.onChange(of: renamingItemId)` (tripwire 16). Prose only; `BinderRow.claimFocus()` is canonical.
- **No raw `maugham.*` NotificationCenter traffic outside `MaughamEvent`; every post declares its scope** (tripwire 21): `TripwireGrepTests.test_noRawMaughamPostsOrSubscriptionsOutsideWrapper`.
- **Key a Document-binding reload on the doc's PATH, not its id** (tripwire 22): a renamed or restored file keeps its id. `EditorHostReloadPredicateTests` pins `EditorHost.needsReload`.
- **No test presses a mounted control and then waits for its effect, and none synthesises a click, outside the named allow-lists** (`pressThenWaitRepresentatives`, `clickRepresentatives`); pin the decision as a pure value and assert only that the control is drawn (tripwire 33): `TripwireGrepTests.test_noNewTestPressesAControlAndThenWaitsForItsEffect`, `test_noNewTestClicksOutsideTheNamedRepresentatives`.
- **Whose piece is whose reads the permit TIMELINE, never `PersonRecord.role`/`.scope`/`.pieces`** (`PieceWriters`, over `TrustTable.myChain`) (tripwire 43): `TripwireGrepTests.test_theRoleCheckReadsTheTimelineAndNotTheRecordsField`.
- **No permit rung is compared in a view; ask `Posture`** (tripwire 47): `TripwireGrepTests.test_aPermitRungIsComparedOnlyInThePermitLayer`.
- **`PermitControl` is the one place a surface builds a `Permit`** (`Permit.permit(offering:pieces:)` / `Permit.rung(of:)`), and holds only the WORDS for each rung (tripwire 49): `TripwireGrepTests.test_aSurfaceBuildsAPermitInOnePlace`.
- **What a Mac may offer is asked of `Posture` through one door**: a surface draws from `DocumentStore.posture(forDocId:)`, a verb acts on `settledPosture(forDocId:as:)`, then `.allows(.someVerb)`; no surface names a permit or builds a `Posture` (tripwire 51): `TripwireGrepTests.test_postureIsAskedOfThePermitInOnePlace`.
- **A manuscript writer outside the editor asks its posture first, and each call is a named site in `manuscriptWriterCallSites`** (tripwire 52): `TripwireGrepTests.test_everyManuscriptWriterOutsideTheEditorIsANamedSite`, `test_everyGuardedDocumentMutatorIsClassified`.
- **Ask a project's kind or a document's format by capability or an exhaustive switch, never by equality** (tripwire 55): `TripwireGrepTests.test_projectKindAndFormatAreAskedByCapabilityNotByEquality`.

### The window body and its family
- **When `ProjectWindow.body` hits "unable to type-check this expression in reasonable time", extract a `ViewModifier`**: the body is at the Release type-check ceiling, so window behaviour lives in modifiers and a column arm is a call.
- **A census reading "the window's code" reads the family BY TYPE**: `SourceTree.windowFamilyTypes` names the members, so moving a modifier between files never shrinks what a census reads; a member nothing declares throws. Absence checks still widen to the directory.
- **`CentreColumn` and `RightColumn` are mounted once each, as the content and detail columns' roots**, so `EditorHost` and the canvas keep their identities across every route change.
- **A column reads values and takes verbs as closures**; `CentreColumn` owns one piece of state, the board's open-notes counts.
- **`canvasModel` is a `let`, and nothing in the window or columns reads `.scene`** (tripwire 30): `CanvasModel` rewrites its scene on every drag frame. `RegionInspectorPane` resolves the region one leaf down.
- **The window's stores and `claude` services are the session's**: it gives its lease back in `.onDisappear`, and `CompilerRunModifier` runs `roster.shutdownAll()`, pipeline first; a merely released session is a live, billing process.
- **The `NavigationSplitView`'s `columnVisibility:` is written by `CanvasCollapseModifier` and `PersonaModifier` and nothing else.** `.detailOnly` hides the canvas, which is the CONTENT column.
- **A hidden detail arm renders `Self.hiddenDetailColumn` (`Color.clear.navigationSplitViewColumnWidth(0)`), never no view**: an arm with no width hands the leftover to an empty detail column. ⌘⌥I's hidden case uses the same static (`DetailColumnWidthTests`).
- **Never put permanent chrome in a top `safeAreaInset` around the `NavigationSplitView`**: it is not propagated into the columns and occludes their tops. The persona bar is a window-toolbar item (`TopChromeModifier`, hidden in ⌘\ focus); only the zero-height-when-idle banners live in the inset.
- **`ProjectWindow.detailColumn` frames its content to the width it declares**: one width, bound once, from `detailColumnWidth` (the persisted wish, written only by the resize handle, clamped to `UIState.detailColumnWidthRange`, 240–480).

### The centre column
- **`centreRoute` answers once, as a value, and `CentreColumn` renders it with one `switch` per level — never by layer order** (`CentreRouteTests`, over the whole product: the board and Publish's surface are never both offered).
- **`CentreRoute`'s case order is load-bearing for view identity**: the canvas stays the third branch, its one mount (tripwires 27, 30; `RegionBindingTests` counts it).
- **Every altitude or cover change happens inside `.editor(altitude:cover:)`, never as a new branch**: a branch is a view identity, and a second one would run `EditorHost`'s `.onDisappear` on every project ↔ chapter hop (tripwire 6). `ProjectAltitudeCentreTests` counts the host's lifetimes.
- **In `CentreColumn.manuscriptEditor`'s `ZStack`, `EditorHost` is first and always present, altitude second whenever the subject names no document, then at most ONE cover chosen by `centreRoute`.** Count the layers in the arm scans of `ProjectAltitudeCentreTests` and `PublishPreviewCentreTests`, never a number in prose.
- **Altitude shows where `ProjectWindow.subjectShowsAltitude(persona:subject:structure:)` is true**: no subject resolving to one document, in a persona whose centre is the editor. Clicking a card or table row writes `selectedSubject`, which lands on the same `EditorHost`.
- **Publish's surfaces and Review's board compose `subjectShowsAltitude`, never a second document-resolution rule**: a chapter subject in Publish or Review shows the editor. The one exception is a translation round, which draws over its chapter too.
- **Problems outrank a round, which outranks a proposal, which outranks the book** (`publishCentre`); the desk's Shows clear each other, so the centre holds one.
- **`showsStatusFooter` refuses under altitude, the palette wall and a research subject in the centre**; Publish needs no clause of its own because its cover only covers altitude (`PublishPreviewCentreTests.test_theBookOnlyEverCoversAltitudeSoTheFooterNeedsNoClauseOfItsOwn`).
- **`ScreenplayScriptSource` is a second PRODUCER of `lastParsedScript`, never a second value** (tripwire 6): `needsDerivation` is false once anything has parsed, so the mounted editor always wins. It derives from the op log, never the `.fountain` (tripwire 20) (`ScreenplayScriptSourceTests`).

### Personas
- **Ask a persona by a named predicate in `Persona.swift`, never compare it by name** — the centre question is `centresTheCanvas` / `showsManuscriptDocuments`, the wall `showsPaletteWall`, Exports `showsExports`, Publish `previewsThePublishedBook`, Review's read-only centre `editsResearchInTheCentre`: `TripwireGrepTests.test_noViewComparesAPersonaByName` (allowances in `personaComparisonAllowed`, file plus spelling).
- **The window's persona is written only from the closed set of decision sites** (count `personaDecisionSites`: `ManuscriptNavigation`, `PersonaModifier`, `ProjectWindow`'s `pressPaletteWallDoor`, `CanvasClaudeArrivalModifier`, `TreeTravel`): `TripwireGrepTests.test_theWindowsPersonaIsWrittenOnlyFromTheClosedSetOfDecisionSites`.
- **The automatic persona writes call `PersonaModifier.applyPersonaChange` directly, never post `.maughamSetPersona`** — posting would rest correctness on SwiftUI delivery order (tripwire 2). `CanvasClaudeArrivalModifier.show` does not record the departing segment (a look is not a choice); `ManuscriptNavigation.go` does.
- **`PersonaMemory` records the persona being LEFT and restores the one entered**, at departure time only; never add per-click recording. Transient segments ride through unrecorded.
- **`panes` is ONE canonical order filtered four ways**: a persona chooses membership, never position, and a new pane takes a place in `PersonaPaneRegistryTests.canonicalPaneOrder`. `.inspector` is last everywhere so `defaultPane = panes.first` holds.
- **The window publishes its persona to the menu bar from `PersonaModifier.body` alone** (`.focusedSceneValue(\.persona, …)`, read by `MaughamApp`'s run items): `RunMenuTitlesTests.test_theWindowPublishesItsPersonaFromThePersonaModifierAlone`. A title only ([ADR 0031](../../docs/adr/0031-the-persona-is-an-input-to-the-run.md)).
- **A navigation to a manuscript document decides the persona in `ManuscriptNavigation`**, guarded on `Persona.showsManuscriptDocuments`, so a reviewer is never ejected into Author. Every navigation receiver routes through it; count the array in `ManuscriptForceCensusTests.test_everyNavigationReceiverStillRoutesThroughTheNavigation`, never a number in prose.
- **A double-click on a tree row travels to Author only where the centre is the canvas** (`TreeTravel.treeTravelDestination`), through `applyPersonaChange`, never `ManuscriptNavigation`. It posts `.maughamTreeTravel` with the row's own tag, never `state.selection`. The rows it reaches are `TreeTravelGestureAttachmentTests.expectations`.

### The subject and the tree
- **The tree is the window's single subject-picker** (`BinderSubject`, no `rawValue`, no `init(String)`): a second picker beside it is two controls that can disagree.
- **Every tree's `List` selects through `BinderTreeSelection`, never `List(selection: $selectedSubject)`**: AppKit writes `nil` when an untagged placeholder row is clicked, and the binding refuses it (`BinderTreeSectionsTests.test_clickingAnEmptySectionsPlaceholderLeavesTheSubjectAlone`).
- **The subject is DERIVED from the tree's selection set**: an anchor that leaves is replaced by the first remaining row in tree order (`ordered`, never `Set.first`). There is no sweep of the set; `SubjectValidationModifier` is the one rule about dead ids.
- **Only a homogeneous research selection batches**: a set holding the project row or a chapter degrades every research verb to the row it was aimed at.
- **The five dead strip spellings — `BinderSegment`, `binderSegments(`, `binderHome(`, `findActive`, `selectedResearchId` — never return to production code**: `TripwireGrepTests.test_noProductionSpellingOfTheDeadStripSurvives`.
- **Find is `ProjectWindow.treeFindActive`, window `@State` a persona switch does not touch, replacing the left column**; `ProjectSearchView.close()` (✕ and Escape) is its one exit, reaching `applyCloseFind`. Closing find moves nobody.
- **⌘⌥O selects the project row; ⌘⌥R / ⌘⌥P reveal the tree's Research / Palette sections** — none opens a `DetailSegment`. ⌘⌥R/⌘⌥P are no-ops while find covers the tree; ⌘⌥O still acts (`AltitudeKeyspaceTests.test_cmdOptOStillActsWhileFindCoversTheColumn`).

### Tree furniture
- **Mounting the sections takes both halves**: the rows inside the host's `List`, and the presentations (sheets, alert, deferred rename) outside it via `.binderTreeSections(…)`, because a sheet on a lazy row is presented from a view the list may unmount: `TripwireGrepTests.test_everyBinderTreeMountsBothHalvesOfTheSections`.
- **Every tree sheet mounts from `BinderTreeSectionsPresentations`, never from a row**; a row only sets state.
- **Every row acts through the one `BinderTreeVerbs` value**, including a fold's; `perform` surfaces a store failure in the shared alert, never `try?`.
- **`create` selects what it makes and defers the rename until the manifest shows the new row** (`pendingRenameId`); `refuseDrop` returns `false` and logs why.
- **`reveal` only ever OPENS, and asks OWNERSHIP of `TreeSectionDerivation`, never existence or a path prefix**: it answers the row the tree can now show (the shared row, or the owning piece's row for a piece-scoped note).
- **Arrival is visible**: every tree host calls `consumingTreeScrollRequests` right after the `ScrollViewReader` wrapping its `List`, with both triggers (`.onChange` and `.task`), because find replaces the column: `TripwireGrepTests.test_everyBinderTreeHostConsumesTheScrollRequest`.
- **A piece fold's rows carry no `.id`**: a linked fold draws a tag twice in one `List`, and `scrollTo` over two identical ids is ambiguous.
- **A `.linked` fold offers no rename and refuses a reorder drop** (`ResearchTreeNode.offersRename`; `TreeDropIntent.Reason.linkedFoldHasNoOrder`): its rows are shared items drawn twice, and two rename fields race tripwire 16's focus claim.
- **New Group at a piece's root has no store API** (`ResearchScope` routes note / asset / link only); a `+` menu on a fold row must not offer it until one exists.
- **A drop is classified by LOOKUP in the manifest, never by the shape of an id**, and an unknown id refuses loudly (`TreeDropIntentTests.test_theGridCanTellALookupApartFromAGuessAtTheIdsShape`). Every mounted drop target calls the classifier (`TripwireGrepTests.test_everyDropTargetInTheTreeReachesTheClassifier`).
- **External drops route through `TreeDropIntent.classifyExternal`** to the same creation verbs as Add File and paste.
- **Every drop closure returns `Bool` down to the row's `.dropDestination`**; a `Void` closure accepts and discards: `TripwireGrepTests.test_everyDropDestinationInTheResearchSurfacesDeclaresItsBool`, `test_theResearchRowNeverAcceptsADropOnItsOwnAuthority`.
- **`TreeSectionDerivation` takes manifest values only** (no store, no disk); use the by-item overload on the body path (tripwire 4). A Collection's piece-scoped roots never leak into the shared list (`TreeSectionDerivationTests`).
- **Link Research… is offered only where `researchRouting(for:)` answers `.sharedPlusLink`** (`ResearchLinkPickerTests`).
- **`TreeScrollProbe` installs only in a dev build outside xctest** (`MAUGHAM_TREE_SCROLL_PROBE=0` disables it); trust its `settled` lines, never `installed`.

### Research subjects and the palette wall
- **A subject may only reach a column the writer can point somewhere else again from**: `ProjectSubjectReachabilityTests.test_everyWindowStateThatLetsAResearchSubjectStandCanAlsoClearIt`.
- **Where the centre is the canvas, a research subject never swaps the centre out**; it previews in the right column. Elsewhere it takes the centre.
- **Both columns route a research item through `researchCentreRoute`** (`test_bothColumnsAskTheSameRoutingFunction`).
- **Review's research centre is read-only** via `ResearchSubjectCentre.readOnly` off `editsResearchInTheCentre` (a locked editor, not an unmounted one).
- **A placement is not a mount**: `revealResearchColumn` moves the right column to the inspector when an arriving subject previews there; `openResearchItem` and `handleShowLatestMCPNote` call it explicitly, because re-selecting the current subject fires no `onChange`. `load()`'s restore does not force the pane.
- **The palette wall never draws over Plan's board** (`showsPaletteWallCentre`), and is window `@State`, not persisted.
- **Any persona change closes the wall, from any writer** (`PaletteWallState.closePaletteWallOnPersonaChange`, in `PaletteWallModifier`), and drops the stash rather than restoring it.
- **In Plan the Open Wall door travels**: `pressPaletteWallDoor` arms `travelPending`, writes the persona, opens nothing and writes no subject; `PaletteWallModifier`'s `.onChange(of: persona)` consumes it immediately AFTER `closePaletteWallOnPersonaChange`, in the same handler. Swap them and the wall opens and shuts in one pass.
- **The door's tooltip and its press ask one spelling, `paletteWallDoorTravels`** (`PaletteWallDoorTests`, driven with real mouse events).

### Layout and sizing
- **A pane's growing content is a reason to compress or scroll THAT pane, never to raise the window's minimum height** (`ProjectWindow.windowHeightFloor`, 540): `TreeScrollStabilityTests.test_theWindowsMinimumHeightIsProjectWindowsOwnFloor`. `.doesNotRaiseTheWindowFloor()` measures the first subview only.
- **A strip in a non-scrolling pane stack demands its height as a MINIMUM**; bound inline content with a ceiling (`BoundedHeightLayout`, `ReviewRoundCockpit.letterDisclosureMaxHeight`) (`ReviewRoundCockpitLetterScrollTests`).
- **No control on a narrow-column toolbar carries writer-typed text on its critical path; labels are icons**, with the name in `.help`. `.frame(maxWidth:)` does not bound a `.fixedSize()` label's ideal.
- **Every `ViewThatFits` variant must be reachable inside the column's own width range**: `AnnotationsQueueToolbarWidthTests.test_everyVariantIsReachableInsideTheColumnsOwnRange`. Measure with `NSHostingController.sizeThatFits(in:)`, never a frame walk.
- **`ViewThatFits` draws its last child whether it fits or not**: the last variant must fit (the queue row's tight spacing).
- **A long unbreakable string truncates in the middle, whole in its tooltip, and its row declares an ideal width** (`SetAsideRecordsDisclosure`, `HeldLineNoticeRow`).
- **No `fixedSize` on a header menu** (`DiagnosticsPaneColumnHeightTests`).
- **The study column stands IN PLACE OF the picker and pane, at the same width**, never beside them. Dismiss (✕/Escape, document, subject, a pane change without a persona change) clears `studied`; hide (persona veto, ⌘⌥I, ⌘\) only takes it off screen.
- **Re-check dark-mode propagation to side panes after theme changes.**

### Events, modals and sheets
- **Pick an event's scope at the post site** (`.keyWindow` for menu commands, `.project(id:)` for data events, `.allWindows` for genuine fan-out) **and subscribe with the matching helper** (`.onKeyWindowCommand`, `.onProjectEvent`, `.onGlobalEvent`); never hand-roll a filter or an `isKeyWindow` guard in a receiver ([ADR 0021](../../docs/adr/0021-scoped-window-events.md)).
- **A pane that needs its window's liveness resolves it through `WindowAccessor`**, never a cached `NSWindow?` read as "closed" when nil (`MaughamEvent.isLive`).
- **Modal state is owned by the window**: subviews post (`.maughamOpenRewind`) and the window presents.
- **A `.keyWindow` post from inside a sheet is dropped** — the sheet's window holds key until after `onDismiss`. A sheet's hand-off records the press and the presenter acts directly through the shared function (`ProjectWindow.selectDetailSegment`).
- **The window's one `.sheet(item:onDismiss:)` fires one callback for every sheet**, so a dismissal hand-off is guarded on WHICH sheet closed (`opensFirstReader(requested:dismissed:)`), and every presentation clears a standing request.
- **Show one sheet per stranger, sequentially, with `queue` and `presented` held apart**: swapping a presented `sheet(item:)` to another item in one pass drops the second sheet; the next goes up from `onDismiss`.
- **A context-menu verb is also drawn as a visible control**. Verb wiring inside a `Menu` is censused from source, never pressed.
- **New Project's kind is a menu, and a Report asks its shape beneath it**, worded by `ProjectKindName`. **Project Settings' Report section is the pure `ReportSettingsModel`**, written only through `ProjectStore.setProfile`/`setSwitch`: absent for a screenplay, its toggle disabled with the reason for a Collection or a newer build's profile, and its caption says re-initialising the template is a request to Claude that replaces the template files.

### Posture surfaces
- **Hide, don't disable**: a verb the posture forbids is not drawn. The editor stays and refuses mutation; the File menu's piece items disable (a menu-bar item greys).
- **Each verb's offer is a pure value pinned in `PostureSurfaceTests`** (`AnnotationRowVerbs.decide`, `AnnotationBulkActions.offers`, `ReviewCardActions.actions(for:isOwn:posture:)`, `PassLadder.offersRulings`, `StatementSurfaceVerbs.offered(under:)`, `TurnClauseOffer.mayFile`, `LessonOffer.mayWriteTheLedger`, `DiagnosticsPostures`, `TreeStructureVerbs.decide`, `TaskRowVerbs`, `TranslationAuthorVerbs`, `HistoryPane.offersRevert`).
- **A queue row asks ITS OWN document's posture**, never the window's selection; a statement asks the statement's own (its piece's, or the book's); the letter asks the destination statement's.
- **A nil posture draws the fail-closed card**: her own note's Edit and Delete, no disposition.
- **The standing line is keyed on `reason`, never `isRestricted`**; Edit Anyway is `DocumentStore.overrideYield(docId:)`, per window, per piece, for the session.
- **Find asks the posture once per document per body pass** (`ProjectSearchView.ReplaceGate`).
- **A refused press is said in words, never swallowed with `try?`** (`AnnotationsPane.sayRefused`).
- **No `static let/var <name>IsAvailable` gate is left standing in production**: a constant gate feeding `.disabled(!…)` is dead code dressed as live (`TripwireGrepTests.test_noAvailabilityFlagIsLeftStandingInProduction`).

### The register's surfaces
- **Every decision about who may write is the MODEL's, as a pure function** (`AdmissionDecision`, `PeopleAndDevicesModel`, `ClaimDecision`, `LoadQuestions`, `SetAsideDoor`); the views draw and decide nothing (`PeopleAndDevicesModelTests`, `AdmissionDecisionTests`, `AdmissionQueueTests`).
- **A merge is never the default**: a proposed label never merges into an existing person (`AdmissionDecisionTests.test_theProposedLabelNeverMerges`), and the pre-fill (`claimedLabel`) is never a known label. Nothing goes up from a queue an admission has overtaken (`awaitingSettlement`) or while a sheet is closing (`isClosing`).
- **A device with no proposed name keeps Admit refused until the writer types a label.**
- **Who is never offered is one classification**, `AdmissionDecision.standing(ofHolder:streams:registry:)`; a stranger's device record raises the question as a held line does, as one request.
- **A claim hint asks `Recognition.recognise`, never a second opinion**; the saved-by name never pre-fills or merges.
- **A narrowing rung asks the book its cost before Admit is pressable** (`AdmissionModifier.checkTheBook`), detached; a book that cannot be read says nothing it cannot stand behind.
- **`Permit.rung(of:)` answers nil for a permit a later build wrote; never draw that as a rung.**
- **Admit… in People & Devices posts and dismisses the settings sheet**: a sheet is not the presenter of another sheet.
- **The admission's dismissal memory resets when the `DocumentStore`'s identity changes**: a closed scene's modifier `@State` outlives `onDisappear`.
- **The inbox recount runs on a registry settle, never a document open.**
- **The admission and new-piece questions are asked only on a Mac holding the book's own root record** (`AdmissionDecision.askingRoot`).
- **The admission queue is built from `DocumentStore.heldLinesByDevice()`** (open docs, closed docs' swept provenance, and the capture stream), never from open documents alone, and People & Devices reads the same derivation, so the two never disagree.
- **`recompute` admits before it asks**: recognised devices, then remembered ones, then re-read, then resolve the registry (`AdmissionDecision.refreshedRequests`).
- **`.maughamAdmissionRequested` may raise a sheet; `.maughamAdmissionSettled` must never** — two events, never one with a flag.
- **A vanished request takes its sheet down**; pressing Admit on a settled record would relabel it.
- **`AdmissionDecision.refusal(_:)` is the one place a `RegistryAdmissionError` becomes a sentence**, exhaustive with no `default`.
- **A refused verb keeps its disabled button with the reason in tooltip and `accessibilityHint`**; a root's row draws no Revoke at all.
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
- **The person key's surfaces stay dark in a Debug or ad-hoc build**: the keychain reads as unavailable there.

### Review: the queue and the board
- **The board and the desk take values and closures, never a store**; every verb is the MOUNT's.
- **A chip click writes `selectedSubject` and `recordActivePass`, never the persona**; a count click opens the queue in project scope and moves neither subject nor persona (`ReviewBoardRoutingTests.test_theCountIsWiredToTheQueueAndMovesNeitherSubjectNorPersona`).
- **`ProjectWindow.recordActivePass(forPiece:passId:)` is the window's one `ActivePassMemory` writer**; the columns receive it as a closure.
- **A round is a stage's or it is refused** (`RoundEditor`); the empty queue names the round the button would actually run.
- **A chip's round waits for the piece to open** (`RunWhenDocumentOpens`, bounded, then a flash), because `runRequested` refuses in silence while the document is not open.
- **`refreshOpenNotes` is the one writer of the open-notes counts**, from the board's `.task` and `.maughamAnnotationsChanged`, never a body, reading the aggregation once.
- **The per-piece pass-state writers are the files in `PersonaPaneRegistryTests.passStateWritingFiles`** (`InspectorView.swift`, `PieceInspector.swift`, `type:CentreColumn`, `type:RightColumn`); the nudge's buttons thread to an existing site. `setReviewPasses` writes the list and is deliberately not a member.
- **`StatusSwatch` is the one place a status becomes a colour.** `StructureItem.status` is a legacy read fallback, never written.
- **Reorder rows with `.draggable`/`.dropDestination`, never `.onMove`**, which does not reliably fire in a macOS `List(.sidebar)`.
- **An open-notes cell draws nothing for zero, and an em dash that is not a button for an unreadable piece**; reference rows get no chip verbs and no count.
- **A bulk verb reaches exactly where the row's own verb reaches**: a stale suggestion and a `.query` are out of accept. The executor opens no undo group (ADR 0023) and collects refusals into one alert.
- **Bulk is document scope only**; project scope reads `listAnnotationsAcrossProject` and refreshes on `noteChanged()`, the document's `annotationsVersion` and `.maughamAnnotationsChanged`.
- **In project scope, travel writes only `selectedSubject`** (`AnnotationScopeTests`).
- **Queue order is `AnnotationQueueOrder.sorted`, pane-side**; it does not change the deriver's projection.
- **Pane-side filters (triage, author) apply after `AnnotationFilter`**, whose shape reaches MCP and never widens.
- **The pass filter defaults to following the active pass, a fallback not a write**; a retired pass's selection heals to All Passes.
- **A selected pass also shows every unstamped note and every note in the coach's lane** (`ReviewPass.coachPreset.id`, never `effectiveCoach`).
- **The nudge keys on the RECORDED active pass and takes no filter argument**, document scope only.
- **A held triage mark is checked and disabled**; re-applying appends an op whose ⌘Z undoes nothing visible.
- **Four resolutions — Accept / Reject… / Stet / Archive — with Stet offered wherever Archive is; triage is a mark, not a resolution.** `AnnotationRow.showsReopen` is an exhaustive switch, so a new status must decide.
- **`AnnotationScope` is window state, never persisted**; project scope lays out by the board's rows (`ReviewBoardRows.derive`), skips reference pieces, and never walks twice.
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
- **A picture dropped into a scope with no statement leaves the empty draft showing until the pane is next opened there**; never bind the pane to close that gap, because the next keystroke would `setFullText` over the ref.
- **Visual language takes pictures; intent does not** (`StatementImageIngestTests.test_intentTakesNoPicturesAtAll`). The drop target is a well BESIDE the editor, never over it.
- **A finished ingest names its destination** (`ProjectStore.appendToStatement` on the returned `Statement`); it never reads view state to find one.
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
- **A text field that writes a file commits on submit, focus loss, Done and `.onDisappear`, never per keystroke**, behind a trimmed `nameNeedsCommitting` guard. `AskField` likewise, takes its verbs as one `AskField.Input`, and never starts a run.
- **The coach's Vacate / Restore calls `setCoachVacated` directly; the coach is never in `setReviewPasses`'s array.**
- **A `ReviewPass.id` never changes on rename**; a deleted pass's `passStates` linger and reappear on re-add.
- **`DocumentStore.setAuthorReaderChoice` is the reader choice's one writer.** Describe… asks the manifest's statement, never `FirstReader.statement`.
- **The Diagnostics reader menu offers a reader only while their premise stands**, and its check follows the RESOLVED choice; nothing in it travels.
- **A standing run's letter is signed `run.readerName ?? reader.editorName`**; the header reads the live reader.

### Publish and translation
- **An unreadable catalog is never presented as empty**: its own notice names the file (RULING-7). The notice banner takes no hits.
- **`PublishPreviewResolver.readablePDFs` is both the picker's rows and the drawn book**; the pick is never persisted.
- **`PublishPreviewModifier` is the resolution's only writer.**
- **A proposal is a VALUE read once**, cleared on any persona change *before* `PublishPreviewModifier`'s `previewsThePublishedBook` guard, so leaving Publish clears it.
- **The desk has no empty state**: the Design row's Run must always be reachable. A language row is `EditionStatus.LanguageRow`, the derivation `translation_status` reports.
- **Name, Add Language and Rename are asks of one sheet**; adding a language the book has says so and stops.
- **Every desk refusal folds into one `notice`** (`DepartmentRunTests.test_theDeskCarriesOneMessageChannelAndNotTwo`).
- **The desk's run gate reads the pipeline first** (`DepartmentRunSession.read`); a round's leg never joins `ReloadKey`.
- **An unlisted language's first Run asks for a name.**
- **The desk runs the OPEN document only** (`DepartmentRunTarget`); Run Whole Book uses the row's own `scopedDocumentIds`.
- **A language tag is lowercased before it is judged, unioned or sent**: `ES` beside `es` would draw one edition as two rows.
- **Desk pre-flight asks the briefing's own gates** (`PublishStarter.isInitialized`, `publishablePieces()`), never a second disk probe.
- **A refused desk verb is disabled with its reason, except Show, which hides.**
- **Gate refusals are read from the error types, never recomposed** (`DesignGate.refusalSentence`); Finalize confirms; nothing on the gate reaches `NSUndoManager` (`DesignGateTests.test_nothingAboutTheGatesVerbsReachesTheUndoManager`).
- **A verb answering from a `Task` updates the surface only if the same proposal / round is still on it** (`PublishCentreModel.adoptVerbAnswer`).
- **The round report is pure rows and copy; the host does all disk work in `.task`.** Its verbs are closures on `TranslationRoundActions` with a standing `notWired` refusal; count them on the type.
- **The report's and the problems list's `onReveal` clear their own selection**: neither arm is project-level, so no subject change does.
- **The report host takes its window**: a nil-window subscription never fires (`MaughamEvent.isLive(nil)` is false).
- **A skipped leg and a failed query read are drawn as themselves**, never as good news (RULING-7).
- **The gate's verbs are a pure function of the proposal's status** (`DesignGate.verbs`); a verb posts `.maughamDesignProposalsChanged` so the desk re-derives.
- **A dismissed departure is a separate fact from the pipeline's outcome.**
- **The reveal waits for the translated surface between its two posts** (a source reveal, `language == nil`, waits for the source), and a pending reveal is taken on the next `activeDocId` change: `TripwireGrepTests.test_theTranslationRevealIsPostedByTheReportArmAndHandledByTheWindow`.
- **A spot-check answer belongs to the paragraph it was asked about** (`TranslationReviewPaneLogic.answerStillBelongs`); spot-check mints nothing. The reveal's `revealTask` is cancelled `.onDisappear`.

### History, recovery and rewind
- **`HistoryPane` is `documentStore.sendHeldWordsToInbox(`'s one counted caller** (tripwire 50, `TripwireGrepTests.test_theP3bCountedListsAreExactlyTheNamedArrays`).
- **Every History notice is a `static`**, pinnable without mounting; count them, never a number in prose.
- **History never performs a load of its own**: provenance counts are read off the open `Document`.
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
- **Rewind snapshots the op log at open time, and its restore is per-doc**; `PartialRestorePicker` never trusts a checkpoint's `activeDoc` to name a document (`CheckpointCapture.documentSubject(of:in:)`).
- **Row rendering branches on the `SynthesisSource` enum, never strings** (tripwire 12).

### Statistics
- **Practice derives in two halves**: `@MainActor` `Plan(store:)` reads the manifest; `nonisolated` `derive(plan:projectURL:now:)` reads every byte on a detached task, cancelling the previous one. No `derive(store:)` convenience.
- **Practice reads CLOSED documents only** (`loadSyncMerged` + `deriveWithSequenceFallback`); an unreadable doc is skipped and named.
- **A Practice row promises only what it can do**: it opens the chapter, never scrolls.

## Recipes

### Add a persona pane (a `DetailSegment`)
1. `Maugham/Models/DetailSegment.swift` — add the case, its `systemImageName` and `helpText` (both exhaustive).
2. `Maugham/Models/Persona.swift` — add it to `panes` for each persona that offers it (membership only).
3. `MaughamTests/PersonaPaneRegistryTests.swift` — give it a place in `canonicalPaneOrder`.
4. `Maugham/Views/DetailPaneToggle.swift` — its arm in `segmentContent` (exhaustive, no `default`). Nothing changes in the picker or `ProjectWindow`.
5. `Maugham/MaughamApp.swift` — one `Button` posting `postSegment(.<case>)` in the View menu with a free ⌘⌥ letter (never S).
6. `docs/guide/reference.md` — the shortcut row (`DocSyncTests`), and the guide page describing the pane.
7. If the pane can show an empty state: tripwire 15's two frames. If it shows verbs: Recipe 5.

Checks: the compiler, `PersonaPaneRegistryTests`, `DetailPaneTogglePersonaTests`, `DocSyncTests`.

### Add a centre route
1. `Maugham/Views/CentreRoute.swift` — a new surface over the editor is a `CentreCover` case; a new top-level surface is a `CentreRoute` case placed after `.canvas` (never before it).
2. Same file, `ProjectWindow.centreRoute(…)` — answer it from a named predicate (a `Persona` predicate, composed with `subjectShowsAltitude` if it is project-level), never a persona name.
3. `Maugham/Views/CentreColumn.swift` — draw it in `editorPane`'s switch, or for a cover in `manuscriptEditor`'s cover switch. Pass values and closures; reach no store from the surface's body.
4. `Maugham/Views/ProjectWindow.swift` — `showsStatusFooter` if the surface hides the document.
5. `MaughamTests/CentreRouteTests.swift` — the product assertion; `ProjectAltitudeCentreTests` if it touches the `ZStack`.

Checks: `CentreRouteTests`, `ProjectAltitudeCentreTests` (host lifetimes), `RegionBindingTests` (one canvas, one `EditorHost(`).

### Add a right-column inspector
1. `Maugham/Views/ProjectWindow.swift` — a case in `InspectorRoute` and its answer in `inspectorRoute(persona:projectType:)`, keeping the canvas check above the project-type split.
2. `Maugham/Views/RightColumn.swift` — its arm in `researchOrSubject`'s switch, handing the view `posture(id)` if it offers verbs.
3. The view in its own file; it reads values, resolves heavy state one leaf down (never `canvasModel.scene`).
4. If it writes pass states: join `PersonaPaneRegistryTests.passStateWritingFiles`.
5. `MaughamTests/Canvas/CanvasRouteTests.swift` — exhaustive over persona × project type.

Checks: `CanvasRouteTests`, `ProjectSubjectReachabilityTests`.

### Add window behaviour (a modifier on `ProjectWindow.body`)
1. A `ViewModifier` in its own file under `Maugham/Views/`, holding its own `@State` and taking the window's state as `Binding`s.
2. One line on `ProjectWindow.body`.
3. If a census reading "the window's code" must see it, add its type to `SourceTree.windowFamilyTypes` (`MaughamTests/TestSupport/SourceTree.swift`).
4. If it writes the persona, it is a new decision site: add it to `TripwireGrepTests.personaDecisionSites` by name.
5. Receive events through the `MaughamEvent` helpers, scope chosen at the post site; declare a new name in `Maugham/Models/MaughamNotifications.swift`.
6. Run a local Release build (`-configuration Release`).

### Add a verb on a posture-gated surface
1. Decide the offer as a pure value over a `Posture` (a static beside the view, or a `…Verbs` type) and pin it in `MaughamTests/Views/PostureSurfaceTests.swift`.
2. Draw it from `DocumentStore.posture(forDocId:)` of the row's own document; hide it when refused.
3. Act through `settledPosture(forDocId:as:)` and the store or `Document` door, and say a refusal in words.
4. If it writes manuscript text outside the editor, add the call to `TripwireGrepTests.manuscriptWriterCallSites` with its gate (`Maugham/OpLog/AREA.md`, "Add a permit-checked writer").
5. If it hides in a `.contextMenu` or `Menu`, also draw a visible control; census the wiring from source.

Checks: `PostureSurfaceTests`, `TripwireGrepTests.test_postureIsAskedOfThePermitInOnePlace`, `test_aPermitRungIsComparedOnlyInThePermitLayer`.

## Pointers
- `docs/history/views.md` — the old guide, word for word: every rule's why and where it came from.
- ADR 0005 as amended by ADR 0025 (personas); ADR 0021 (window events); ADR 0023 (undo); ADR 0030 (the department desk, the round report, the reveal); ADR 0031; ADR 0032 (posture and register surfaces).
- `docs/tripwires.md` rows 2–7, 9, 14–16, 21, 22, 33, 43, 47, 49–52, 55.
- Specs: `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`, `docs/superpowers/specs/2026-08-08-shell-finish-design.md`.
- Neighbouring guides: `Maugham/Editor/AREA.md`, `Maugham/Canvas/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/OpLog/AREA.md`, `Maugham/Compiler/AREA.md`, `Maugham/Publish/AREA.md`.
- Tests worth knowing: `EditorIntegrationHarnessTests`, `CentreRouteTests`, `PersonaPaneRegistryTests`, `ProjectSubjectReachabilityTests`, `PostureSurfaceTests`, `RewindDensityTests`, `RewindEntryPointsTests` (both rewind entry points reach one modal), and the Views censuses in `TripwireGrepTests`.
