# MaughamPhone — area guide

The iOS companion app: a four-tab SwiftUI app (**Capture / Read / Annotations / Settings**) that reads and writes a security-scoped-bookmarked iCloud Drive projects folder, sharing `Packages/MaughamCore` with the Mac. It captures into the inbox, reads manuscripts, palette cards and statements, disposes of annotations, and declares itself to the Mac's admission. The one rule from CLAUDE.md: **AppKit never; WhisperKit is Mac-only.** The area carries tripwires 4, 13, 15, 17, 18, 19, 20, 24, 35, 37, 38, 39, 40, 41, 46, 51, 53, 54 and 55. The narrative and history behind the rules below are in `docs/history/phone.md`.

## Map

Every source file in `MaughamPhone/` appears once.

### App and identity
- `MaughamPhoneApp.swift` — owns the shared stores (`ProjectsRoot`, `RecentsTracker`, one `DownloadCoordinator`, `ProjectsBrowser`, `LaunchAuthGate`) and runs the cold-launch sequence; all four tabs get the SAME instances.
- `BuildVariantPhone.swift` — the phone's variant knobs; the one sanctioned home for the bundle-id literals (`com.Maugham.MaughamPhone[.dev]`). Tripwire 13.
- `Info.plist` — the usage descriptions (camera, Face ID, microphone, photo library, speech recognition) that capture and the launch gate need; `Assets.xcassets` — the app icon and colours.
- `MaughamPhone.entitlements` — `keychain-access-groups` = `$(AppIdentifierPrefix)com.maugham.person`, wired in `project.yml` under Release only.

### `Storage/` — the substrate
- `DownloadCoordinator.swift` — actor: per-URL download state, dedup, the 50 MB cold-launch budget, the `observe` AsyncStream.
- `CoordinatedFileIO.swift` — the `UbiquitousDownloader` conformer: download/poll (`isLocallyReady`) and `NSFileCoordinator` read/write/ensureDirectory, with **no append primitive**. Tripwire 18.
- `UbiquitousDownloader.swift`, `UbiquitousFileSystem.swift` — the two download seams the tests fake.
- `ProjectsRoot.swift` — the security-scoped bookmark's lifecycle. Tripwire 18.
- `ProjectsBrowser.swift` — project id → decoded manifest.
- `RecentsTracker.swift` — recently opened or captured-into projects.
- `ColdLaunchDownloader.swift` — the cold-launch prefetch (`liveEnumerateOpLogs`). Tripwire 18.
- `DocumentPickerView.swift` — the folder picker that hands `ProjectsRoot` its bookmark.
- `PhoneDeviceRecord.swift` — the phone's half of admission: `ensure`, the per-write memo, `findPersonKey(canSign:)`, `deviceName`. Tripwires 19, 53.
- `PhonePersonKeyAccess.swift` — the phone's one construction of a `PersonKeyStore`. Tripwire 53.

### `Capture/`
- `InboxCaptureWriter.swift` — text/photo/voice → `.maugham/inbox/`; manifest rows chained and sealed through `JSONLAppendStore`. Tripwires 17, 24.
- `CaptureView.swift`, `TextCaptureSheet.swift`, `PhotoCaptureSheet.swift`, `VoiceCaptureSheet.swift` (and its `VoiceRecorder`) — the capture UI.
- `ProjectPickerSheet.swift` — the project pill's picker (`ProjectPickerSections`).
- `CapturePermissions.swift` — async wrappers for voice capture's two authorizations (microphone, speech recognition); photo permission is the system pickers'.

### `Read/`
- `ProjectsListView.swift`, `BinderView.swift` — the projects list and the binder (with its Palette section and Craft Intent row).
- `BinderRouting.swift` — where a binder row navigates.
- `DocumentReaderView.swift` — the download-gated reader of the on-disk clean `.md`.
- `MarkdownBlocks.swift` — the block split, so paragraphs and headings survive. (The anchor strip is Core's `MarkdownDisplayFilter`.)
- `FountainLineStyle.swift` (`FountainStyler`), `FountainSemanticRenderer.swift` (`FountainAlignMapper`, `FountainInlineEmphasisRenderer`) — the phone's Fountain renderer. Tripwire 4.
- `PaletteLoading.swift`, `PaletteCardView.swift` — the read-only palette section.
- `StatementLoading.swift` — the Craft Intent row's statement-first lookup (`intentRow(statements:research:)`).
- `PhoneImageLoader.swift` — the eviction-safe image seam.
- `ReadIcons.swift` — row icons (`paletteRowSymbol`).

### `Annotations/`
- `AnnotationsStore.swift` — `@Observable` load and grouped tree; the one source of truth.
- `AnnotationsListView.swift` → `ProjectChaptersView.swift` → `ChapterAnnotationsView.swift` → `AnnotationDetailView.swift` — the project → chapter → notes drill-down (Projects root, Open/All toggle, single-doc skip; chapters in binder order with group-header sections; a chapter's OPEN and dimmed RESOLVED notes).
- `AnnotationLoading.swift` — the pure core: `loadJudged`, `groupByChapter`, `allAnnotations`, `AnnotationsMode` and the visibility filters. Tripwire 20.
- `AnnotationStatusChip.swift` — a note's status chip; `AnnotationsBanner.swift` — the pure map from op-log download states to the tab's header banner.
- `ResolvedEntryDecision.swift` — the race-versus-review decision (`openedResolved`).
- `AnnotationWriter.swift` — lifecycle ops (`makeAccept`, reject, reopen, revert) through `JSONLAppendStore`. Tripwires 17, 24.
- `PhonePosture.swift` — the phone's one posture door. Tripwires 19, 46, 51.

### `Auth/` and `Settings/`
- `MaughamPhone/Auth/LaunchAuthGate.swift` — opt-in Face ID.
- `MaughamPhone/Settings/SettingsView.swift` — Settings, including **This Device** (the code, the person-key line, one standing row per book).
- `MaughamPhone/Settings/PersonKeyLine.swift` — the person-key sentence, a pure model over `PersonKeyFinding`.
- `MaughamPhone/Settings/BookStandingRow.swift` — the pure half of a book's standing and role line.

## Rules

### Tripwires this area carries
- **4 — No per-row computation in list rows**: cache the `FountainScript` in `.task`; a palette row's icon stays generic (`ReadIcons.paletteRowSymbol`) because a card's `kind` lives in the file, and kind icons appear only in card detail, where the file is parsed. Prose only.
- **13 — No hardcoded `"maugham"`/`"Maugham"` outside `BuildVariantPhone.swift`** (`TripwirePhoneGrepTest.test_noHardcodedIdentityStringsInPhoneSources`).
- **15 — An empty state chains `.frame(maxWidth: .infinity, maxHeight: .infinity[, alignment: .top])`**: SwiftUI otherwise sizes it to its content. Prose only on the phone.
- **17 — A file more than one device writes is partitioned per device**, and the inbox's `writtenAt` is monotonic, `max(now, createdAt+1ms)`, to survive clock skew. The phone never seals or hand-rolls a segment name (`TripwirePhoneGrepTest.test_phoneNeverSealsOrHandRollsSegmentNames`).
- **18 — Don't assume a file is evicted; `startAccessing == false` is not a denial; don't prefix a docId twice**: each assumption broke browsing or annotation loading on a device. The three gotchas are under *iCloud and the folder* below; `test_noReachAroundOpLogFilenameParsing` keeps the filename parse in Core.
- **19 — Anything both the Mac and the phone touch goes through one MaughamCore implementation**: a stricter local doc-id parser shipped a phone that showed "No open annotations". `TripwirePhoneGrepTest` holds the reach-around censuses; the real net is the round-trip tests. Registry: `docs/superpowers/notes/cross-surface-contracts.md`.
- **20 — Annotations derive from the op log, never the `.md`** (`TripwirePhoneGrepTest.test_noManuscriptFileReadsOutsideReconciler`). The Read tab's display of the clean `.md` is the one contracted exception (below).
- **24 — Filenames take a `DeviceSlug`**: enforced by the compiler.
- **35 — No hand-built device id**: the phone's id is `DeviceIdentity.author.deviceId`, never a `phone:<uuid>` of its own (`TripwirePhoneGrepTest.test_noHandBuiltDeviceIdOutsideDeviceIdentity`).
- **51 (46 by way of Core's `PostureDoor`) — The phone asks its posture in one place**, `PhonePosture.swift`, through Core's `PostureDoor`: no other phone file names `PostureDoor.` or `Posture.settling` (`test_thePhoneAsksItsPostureInOnePlace`, `test_captureNeverAsksAPosture`; the Mac's `test_postureIsAskedOfThePermitInOnePlace` scans this target too).
- **37 — The phone recognises no seal line**: `OpLogChain` is the one recogniser (`TripwirePhoneGrepTest.test_noSealLineRecogniserOnThePhone`).
- **38 — No `device:` string at a `Document.load`**: the Mac census scans this target (`TripwireGrepTests.test_noDeviceStringAtAProductionDocumentLoad`).
- **39, 40, 41 — The phone makes no trust decision and writes no registry record**; it reaches the writer only through `PhoneDeviceRecord` → `RegistryPresence` (`TripwirePhoneGrepTest.test_noTrustDecisionOrRegistryWriteOnThePhone`, `test_thePhoneWritesNoRegistryRecord`).
- **53 — `PhonePersonKeyAccess.swift` is the phone's one `PersonKeyStore` construction**, and `PhoneDeviceRecord.findPersonKey` its one find (`PersonKeyCensusTests`, keyed `MaughamPhone/<file>`).
- **54, 55 — No `"fountain"` literal and no kind/format equality**: ask `DocumentFormat`/`ProjectType`'s capabilities or switch exhaustively; the Mac censuses scan this target (`TripwireGrepTests.test_theFountainExtensionIsSpelledInDocumentFormatOnly`, `test_projectKindAndFormatAreAskedByCapabilityNotByEquality`).

### Build and shape
- **No AppKit, and never WhisperKit**: WhisperKit is a Mac-target-only dependency.
- **Tests `@testable import MaughamPhone` and `import MaughamCore`**; `MaughamPhoneTests` hosts into the app target.
- **A simulator "Busy / failed preflight checks" is a flake: re-run.** Never `simctl shutdown all` right before a launch; that *causes* the Busy state.
- **A store is `@Observable` with injected dependencies, never `@AppStorage`**: `@AppStorage`'s change tracking fires only in a `View` and cannot be retargeted to a test `UserDefaults` suite. `RecentsTracker`, `ProjectsRoot` and `LaunchAuthGate` take an injected `UserDefaults`, a `now: () -> Date` clock where time matters, and a `BookmarkResolving`/`BiometricEvaluating` seam.
- **Logic sits behind seams; views are build-verified.** `DownloadCoordinator` is tested against a fake `UbiquitousDownloader`, `CoordinatedFileIO`'s poll loop against a fake `UbiquitousFileSystem`; neither touches real iCloud.
- **A test names no temp directory but `TestTemp`** (`TripwirePhoneGrepTest.test_noTestNamesTheTempDirectoryButTestTemp`).
- **Scan a directory without `.skipsHiddenFiles`** (`test_noSkipsHiddenFilesInPhoneScans`).

### iCloud and the folder
- **The download gate treats already-local and non-ubiquitous files as ready; only an evicted placeholder (`.notDownloaded`) fetches.** `isLocallyReady`: `.current`/`.downloaded`, or a nil-status file that exists. Treating every file as a placeholder made `startDownloadingUbiquitousItem` throw on local files and broke browsing.
- **`startAccessingSecurityScopedResource() == false` is NOT a denial**: it means no scope was needed. `ProjectsRoot` adopts the folder regardless; only a thrown resolve or a stale bookmark re-prompts.
- **An op-log filename is `<docId>.<deviceSlug>.jsonl`, and the docId already carries its prefix** (`doc-<hex>`/`scene-<hex>`, ADR 0008), never `d_<ULID>`: never prepend another. The docId is the component before the first dot; the only non-doc stream in `.maugham/ops/` is `__project__` (tasks and checkpoints, no annotations). Match `OpLogStore.store(forDocId:deviceSlug:)`, which never format-validates the id.
- **Never invent a stricter id predicate** (`hasPrefix("d_")`, a 26-character ULID check): it matches zero real files and silently shows "No open annotations" or prefetches nothing.
- **Every read inside the bookmarked folder is `ensureDownloaded` then `coordinatedRead`**; every write is coordinated, and only ever into `.maugham/inbox/*` or `.maugham/ops/*.jsonl` (plus the device record Core writes). **The phone never writes a `.md`.**
- **Phone-written rows are byte-compatible with the Mac's reader**: encode with `JSONLAppendStore.dateEncoding`, and prove it by round-tripping through the Mac's `JSONLAppendStore`/`OpLogStore` in a test, never by eyeballing JSON.
- **No live cross-device updates (no `NSFilePresenter`).** Lists reflect Mac changes only on appear, pull-to-refresh, after a phone-side resolve, or when a detail's re-derive finds a remote resolution. The detail's re-derive-on-appear is the guard that stops the phone clobbering a resolution another device made.
- **Test anything touching iCloud, the op log or a system primitive through the real I/O path on a running build**: every device-only bug so far lived at a seam the unit tests mocked away.

### Identity and keys
- **The phone is the `author` and holds that ONE key**: the device id is `DeviceIdentity.author.deviceId`, the same one the Mac's writer reads, and the phone needs no code of its own to be it.
- **`LocalIdentities` is lazy: enumerating mints nothing, only naming an actor mints.** Its enumerating members (`all`, `fingerprints`, `identity(forDeviceId:)`) answer over the keys already on disk; only `subscript` or a named property mints. The phone's writers name `.author` and nothing on it names the other three, so nothing mints them, however many `OpLogStore`s it builds (`OpLogStore(projectURL:)` defaults its `identities:`). The guard is a measurement: `PhoneOneKeyTests.test_openingTheAnnotationsPathMintsNoKeyThePhoneWillNeverSignWith` (`PhoneDeviceIdentityTests.swift`) runs the real read path and lists `DeviceState.directory`.
- **The device key's blob lives under `~/Library/Application Support/<supportFolderName>/device/`, outside every project folder, because it must never sync** (`DeviceState.directory`). It is no keychain item; the app's one entitlement is the person key's group.
- **The Apple Silicon simulator exposes the host's enclave**, so `PhoneDeviceIdentityTests` mints and reloads a real key; its skip measures `SecureEnclave.isAvailable`, and firing means the simulator changed.

### Capture
- **The writer takes a `DeviceIdentity`, never a device-id string**: the id, the manifest's filename slug and the key that seals a capture are one name, injectable for tests.
- **Manifest rows go through `JSONLAppendStore` with a `ChainPolicy`** (`docId: InboxManifest.chainDocId`, the project as `projectURL`): chained onto the head this phone verified and sealed on the spot, one signature per capture. The store owns the encoding, so the phone cannot drift from the Mac's reader. Only the ASSET writes use `CoordinatedFileIO`.
- **An unsigned phone writes the row and no seal**: a state, not a failure.
- **There is no capture aim.** A capture lands in the inbox plain, and the Mac aims it at a palette card on promote. `InboxEntry.paletteSubject`/`sense` stay on the wire, decoded and tolerated, and the Mac's `InboxPane`/`PalettePickerSheet` still read them, but nothing on the phone writes them (`TripwirePhoneGrepTest.test_noPaletteAimWriterOnThePhone`).
- **Inbox subdirectories are Core's `InboxConvention`**, never a literal (`test_noRawInboxSubdirLiteralsInInboxCaptureWriter`).
- **Capture is on every rung** (an inbox row is the reviewer row), so nothing under `Capture/` consults a posture.

### Reading
- **The Read tab displays the on-disk clean `.md`**: a contracted Tier-2 divergence from ADR 0018 (registry: `docs/superpowers/notes/cross-surface-contracts.md`). Annotations derive from the op log, so the two can briefly disagree while iCloud syncs; that is designed behaviour.
- **`MaughamPhone`'s `FountainStyler` and the Mac's `ScreenplayMode` are two independent renderers whose emphasis is pinned by Core's `ScreenplayEmphasis`** and `ScreenplayEmphasisContractTests` in both targets.
- **The Palette section is read-only**: cards are plain files, not op-logged, and concurrent phone and Mac writes through iCloud would make conflict twins. It is shown only when non-empty.
- **`PaletteLoading.paletteCards(in:)` mirrors the Mac's `ProjectStore.paletteCardItems()`, and `excludingPalette(_:research:statements:)` keeps palette cards and the shown legacy craft-intent note out of Research**, so nothing shows twice.
- **`groupedNotes(_:)` is a phone-local twin of the Mac's `PaletteCardReadView.groupedNotes` and is NOT parity-tested**: one bucket per `PaletteCard.Sense.allCases` member, non-empty only, untagged last. `PaletteCardReadViewTests.test_groupedNotes_ordersTaggedBySenseThenUntagged` and `PaletteLoadingTests` each assert their own expectations, so a drift on one side fails neither suite. The fix is promoting it into MaughamCore, a known gap.
- **`PhoneImageLoader.load(_:downloads:io:)` is `ensureDownloaded`, `coordinatedRead`, then `UIImage(data:)`**, and is eviction-tolerant: a thrown error or nil image shows a placeholder, never an error screen, because a card's text must render without its image.
- **The Craft Intent row is statement-first with the legacy note as fallback, and the fallback is load-bearing.** Intent lives in `ProjectManifest.statements`, its content at the project root (`<project>/intent.md`), but adoption of the legacy `<project>/research/craft-intent.md` is Mac-only (`ProjectStore+StatementAdoption.swift`, run from `ProjectStore.load`); the phone writes no manifest, so a project not yet opened on an updated Mac has no `statements` section, and reading only that would show nothing (`PhoneStatementReadTests.test_theReadTabStillShowsAnUnadoptedNote`). Keep it until every shipped project has been opened on a Mac, which nobody can know.
- **Both Craft Intent arms are shared Core lookups** (`StatementLookup.statement(in:kind:scope:)`, `PaletteLookup.craftIntentItem(in:researchPrefix:)`): no phone-local path constant, filename test or scope parser.
- **Project scope only, both arms**: a document-scoped statement and a Collection piece's own note are somebody else's; per-piece intent display is deferred.
- **The Research exclusion follows the ROW, not the note's existence**: an adopted project whose note survived keeps it visible in Research, because it is drawn nowhere else.
- **The phone shows a statement and never edits one.**

### Annotations
- **`store.projects` holds ALL statuses**; mode filtering is a pure view step, and the leaf and middle views re-slice from the store by id, so mid-stack counts stay fresh after a resolve.
- **Resolved-note review is read-only.** `AnnotationDetailView` gates on the note's status at open time (`openedResolved`): an already-resolved note shows its outcome and calls neither the race collapse nor `onResolved()`. Only a note OPEN at load that became resolved triggers the cross-device race guard (`ResolvedEntryDecision`). Never merge the two cases.
- **Reopen and Reopen & Revert follow the undo conventions** (ADR 0023): rejected/archived → `annotationReopen`; accepted → a full `claudeAcceptRevert` with a drift confirm.
- **`claudeAccept` on a `suggestedChange` carries the FULL resulting paragraph as `next`** (`AnnotationWriter.makeAccept`), or the Mac's `Deriver` replay materializes nothing. The op stores the bare suggested text; `makeAccept` splices it into `annotation.span` against the live `currentParagraph` through Core's `SuggestionSplice.apply`, the same one `Document.acceptAnnotation` uses. No span replaces the whole paragraph; other kinds carry empty `changes`; a malformed suggestedChange **throws** rather than emitting a no-op accept.
- **The annotation writer takes a `DeviceIdentity` and appends through `JSONLAppendStore` with a `ChainPolicy`** (`docId:` the annotation's document), sealed after every op. The identity is the `author`'s: a phone decision is the writer's own. An unsigned phone writes chained ops and no seals.
- **Both writers' stores only WRITE**, so their `ChainPolicy` keeps the default single-signer trust (`PhoneChainPolicyTests`). Neither writer file may declare or return a `JSONLAppendStore` (each builds a function-local `let store`), and no other phone file reaches a `.store` member; `.store(`, the `OpLogStore` method, is left alone (`test_thePhonesChainedStoresOnlyWrite`; its control plants both).
- **Every annotation read is judged.** `AnnotationLoading.loadJudged` is the phone's one op-log read for notes: `OpLogStore.loadDiagnosed(docId:amendmentPermits:)` then `annotationAmendments(from:documentClass:)`, returning a `JudgedOps` (the ops and the ownership rule they are read under). The list, the detail's re-derive and the accept guard (`AnnotationWriter.makeAccept(…verifyingAgainst: JudgedOps)`) all take it (`test_everyAnnotationReadOnThePhoneIsJudged`).
- **No phone derive has a permissive default**: the bare-op wrappers take `amendments:` as a required argument, so a caller wanting the un-narrowed answer names `.honourEverything`.

### What the detail offers: the posture
- **`PhonePosture.swift` is a per-load cache over Core's `PostureDoor`**, the table warmed off the main actor (`OpLogStore.prepareTrust`) before the permit is asked. It keeps ONE `OpLogStore` per project (built through an injectable `makeStore`) and ONE warm-up in flight per project (`warming: [URL: Task<OpLogStore, Never>]`): a second ask awaits that task.
- **The phone keeps no trust signature of its own**: the store's `trust()` returns its resolved table while `TrustResolution.signature(of:)` is unchanged, so a permit change or revocation is seen at the next ask. `refresh()` drops the in-flight warm-ups too.
- **Pull-to-refresh makes a new `PhonePosture`** (`AnnotationsStore.reload()`); returning to the front calls `refresh()` on the SAME instance, so a detail view holding it sees the refresh.
- **The cache is made by `PhonePosture.forANewLoad()`**, because the census reads any `…Posture(` as a posture being built.
- **Accept / Mark answered, Reject… / Reply… and Reopen & Revert follow `Posture.Verb.acceptOrReject`; Archive and Reopen follow `.dispose`** (the phone has no withdraw).
- **A refused verb is HIDDEN, never disabled**, and until the door answers `PhonePosture.unanswered` (the door's `settling`) offers no disposition.
- **Every perform re-asks (`askAgain`) before it writes, says a refusal (`PhonePosture.refusal`), and hands the fresh answer to the view BEFORE the write** (`perform(…onAnswer:write:)`), so a write that throws cannot leave drawn a verb the fresh answer refuses (`test_aWriteThatThrowsStillHandsBackTheFreshAnswer`).
- **A book author's phone LOCKS in a piece somebody else started that nobody has claimed.** Her manuscript-text line there (even a Reject that changes nothing) would claim the piece and set the starter's words aside on every Mac, so `PhonePosture` asks `PostureDoor.postureYieldingToItsStarter`, which yields wherever the permit carries `unsettledStarter`. The Mac lifts that with *Edit Anyway*; the phone has none. Accept, Reject and Reopen & Revert are hidden, and a write refuses with *<Sam> started this piece and it isn't settled whose it is yet, so nothing was written — settle it from your Mac.* (`PhonePostureRoundTripTests.test_aBookAuthorsPhoneOffersNoDispositionInAPieceSomebodyElseStarted`).
- **The phone DOES write manuscript text**: Accept, Reject and Reopen & Revert write `claudeAccept`/`claudeReject`/`claudeAcceptRevert` ops (never the `.md`).
- **One asymmetry, stated**: the builder's `unownedPiece` walk skips an op-log file iCloud has not downloaded (`readCoordinated` answers nil → `continue`), so the phone can answer `.waitingToBeClaimed` where her Mac says *not your piece*, and may offer an Accept or Reject her Mac refuses. Dispositions are refused either way, and a line her permit does not cover is set aside by the partition and moves nobody else's words.
- **The verb decisions are pure functions over a `Posture`** (`PhonePostureTests`); the Mac↔phone round trips are `PhonePostureRoundTripTests`.

### This Device: declaration and standing
- **The phone decides nothing about admission**: it writes a record saying who it is and reads back what the Mac decided.
- **The record is written by MaughamCore, never here.** `PhoneDeviceRecord.ensure` calls `RegistryPresence.ensureDeviceRecord`, and both phone writers reach it on every write. No `.maugham/` path, fingerprint or signature is spelled in this target (`TripwirePhoneGrepTest.test_noTrustDecisionOrRegistryWriteOnThePhone`, `test_thePhoneWritesNoRegistryRecord`, `test_noSealLineRecogniserOnThePhone`).
- **`ensure`'s `name` defaults to nil and the body reads `UIDevice.current.name`**: a default argument is evaluated in the caller's isolation.
- **The phone never mints a person key**: a phone-minted item crossing a Mac's in iCloud Keychain would fork the person. `ensure` finds the key off the main actor (`Task.detached` → `findPersonKey(canSign:)` → `PersonKey.finding(in:)`, which never creates or names an item). A phone whose key has not synced makes no claim and claims on a later write; a phone that cannot sign never looks.
- **The claim rule is Core's** (`RegistryPresence.claimIntent`: a key → `.set`, no key → `.keep`, never `.remove`; `RegistryPresence.declareDevice` re-writes with `.keep` when it refuses the claim); the phone keeps only its log line.
- **The store's arm is Core's `PersonKeyStoreChoice`**: injected wins; an XCTest host with nothing injected gets an in-memory store that refuses to create (the simulator may not enforce access groups); production is `KeychainPersonKeyStore` in the team's group.
- **The device's name**: the system name stands unless it is exactly the model (`"iPhone"`, what iOS hands an app), and then, with a person name on the key, it is *"<first name>'s <model>"* (`PhoneDeviceRecord.deviceName`).
- **The claim round trip is pinned twice**: in-process (`PhonePersonClaimTests.test_thePhonesClaimIsRecognisedByTheRootsMac`) and from phone-written bytes checked into Core's `PhoneClaimRoundTripTests`, regenerated by the opt-in `PhoneClaimFixtureDump`, a **standing skip** in every phone gate unless `MAUGHAM_PHONE_CLAIM_FIXTURE_DIR` is set (it writes outside `TestTemp`).
- **Only the Release build can reach the person key.** The entitlement is wired under Release only and granted by the *Maugham Phone App Store* profile (`docs/release-notes/phone/SETUP.md` §1). A Debug device build, the simulator and the gate read the keychain as unavailable and make no claim; the gate cannot tell (`CODE_SIGNING_ALLOWED=NO`), so the TestFlight dry run proves the entitlement.
- **The phone never writes a root**: a root record is the Mac's.
- **The per-write memo**: `PhoneDeviceRecord` remembers the FACTS it declared per project (this phone's key, its actors via `existingActors`, which never mints, its name), so a second write into the same book reads nothing. In-process and per-project; a declaration that THREW is not remembered, or a transient iCloud fault would leave the phone undeclared (`PhoneDeviceRecordTests`, through the `declare` closure).
- **Settings shows facts and offers no control**: the four-character code (`DeviceCode.short`) on its own line, to compare with the Mac's admission sheet; then one line per book. Pull-to-refresh re-reads, because the state changes on the other machine.
- **The person-key line is `MaughamPhone/Settings/PersonKeyLine.swift`, read through the SAME `findPersonKey` the claim takes** (every sentence in `PersonKeyLineTests`), inside the standings' detached task. Because the phone never mints, *no key* is told apart from *keychain unreachable*: found → *Recognised as <name> on your other devices.*; absent → *Not recognised yet. Your Mac makes the key…*; unavailable, an item that is not a key, and a phone that cannot sign each say so.
- **The standing sentence is Core's `DeviceStanding`**, so the Mac's People & Devices says the same fact in the same words. A registry record that is present and unreadable answers with the read's own sentence, never *not yet admitted*.
- **A retired phone is told so**: `DeviceStanding.retiredAt` is read from this device's own record BEFORE the chain guard, because a retirement is the device's own signed word. `retirementNotice(device: "iPhone")` draws under the standing: the phone keeps applying what it writes locally while every peer quarantines it, a divergence visible from nowhere else; the noun is an argument because the Mac draws the same function with `"Mac"`. **There is no un-retire**; a retired device returns only as a new key.
- **Each row carries a role line**: `DeviceStanding.permit` (`table.myTimeline.current`; nil with no register, not yet admitted, or revoked) said through `DeviceStanding.permitSentence` → Core's `PermitWords`, the Mac's words, pieces named by this book's titles. A book with no register draws none; an admitted phone in a rooted book that narrows nobody reads *Author of the whole book*. `BookStandingRow.swift` resolves through `TrustResolution.resolveVerified`, so a deleted register is read from this phone's memory.
- **Settings re-reads on `scenePhase == .active` and on pull-to-refresh**: the phone has no file presenter.
- **Whether the phone is in the book asks `TrustTable.myChain`** (my root's chain plus every adopted root's).
- **The rows are per project**: the ones `RecentsTracker` calls recent, intersected with what `ProjectsBrowser` has manifests for, so the list is not a wall of *not yet admitted*.

### Releasing
- **The bundle id is `com.Maugham.MaughamPhone`, capital M**: the App ID was registered so, Apple namespaces ids case-insensitively, and codesign is case-sensitive. `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` and `provisioningProfiles` in the `ExportOptions.plist` that `.github/workflows/phone-release.yml` writes MUST stay capital-M and in sync.
- **The dry run is the integration test**: device-only bugs are invisible to `xcodebuild test`; cut throwaway `phone-v0.0.x` tags to prove a fix on a device.

## Recipes

### Add a phone store
1. A new file under the folder it serves (e.g. `Storage/`): a plain `@Observable` class, never `@AppStorage`.
2. Inject its `UserDefaults`, a `now: () -> Date` clock if time matters, and a protocol seam for any OS primitive (the `BookmarkResolving`/`BiometricEvaluating` shape in `ProjectsRoot.swift`/`MaughamPhone/Auth/LaunchAuthGate.swift`).
3. Own the one instance in `MaughamPhoneApp.swift` and hand the same one to every tab.
4. Test it in `MaughamPhoneTests` against a private `UserDefaults` suite; run `./gen.sh` after adding the files.

### Read a new kind of file from the projects folder
1. Ask MaughamCore for its path or lookup (tripwire 19); if the Mac has its own spelling, move it to Core first.
2. Read through `DownloadCoordinator.ensureDownloaded` then `CoordinatedFileIO.coordinatedRead`; tolerate eviction with a placeholder (the `MaughamPhone/Read/PhoneImageLoader.swift` shape).
3. If it is derived from an op log, derive it; never read the `.md` as truth (`TripwirePhoneGrepTest.test_noManuscriptFileReadsOutsideReconciler`).
4. Pin the bytes against the Mac's reader in a round-trip test.

### Add a disposition verb
1. The verb's `Posture.Verb` comes from Core (`Packages/MaughamCore/Sources/MaughamCore/Posture.swift`); the phone builds no posture.
2. In `MaughamPhone/Annotations/AnnotationDetailView.swift`, show the button only where the `PhonePosture` answer allows it (hidden, never disabled).
3. Perform through `PhonePosture.perform(…onAnswer:write:)`, writing through `MaughamPhone/Annotations/AnnotationWriter.swift` with a judged read.
4. Add the decision to `PhonePostureTests` and a Mac↔phone case to `PhonePostureRoundTripTests`.

### Cut a phone release
1. `scripts/cut-phone-release.sh` (mirrors the Mac's; `phone-v*` tags), following `docs/RELEASING.md` → "Phone releases".
2. Push the tag by name, never `--tags`.

## Pointers

- Gate: `./scripts/test.sh phone` (run `./gen.sh` after `project.yml` or asset-catalog changes). `docs/RELEASING.md` ("Phone releases"); `docs/release-notes/phone/SETUP.md`; TestFlight forensics in `docs/superpowers/notes/2026-05-31-phone-testflight-status.md`.
- App icon sources: `scripts/phone-icon/` (`render.sh`).
- Cross-surface contracts registry: `docs/superpowers/notes/cross-surface-contracts.md`. ADRs 0008 (id prefixes), 0012 (per-device op logs), 0018/0019 (op log as truth, clean `.md`), 0023 (undo conventions), 0032 (the signed op log).
- Palette spec: `docs/superpowers/specs/2026-07-10-palette-phone-and-role-identity-design.md`.
- `docs/tripwires.md` rows 4, 13, 15, 17, 18, 19, 20, 24, 35, 37, 38, 39, 40, 41, 46, 51, 53, 54, 55.
- Tests: `TripwirePhoneGrepTest` (every phone census), `PhoneDeviceIdentityTests`, `PhonePostureTests`, `PhonePostureRoundTripTests`, `PhoneDeviceRecordTests`, `PhonePersonClaimTests`, `PersonKeyLineTests`, `PhoneChainPolicyTests`, `ResolvedEntryDecisionTests`, `ColdLaunchDownloaderTests`, `PhoneStatementReadTests`.
- Neighbouring guides: `Packages/MaughamCore/Sources/MaughamCore/AREA.md` (the shared implementations), `Maugham/Stores/AREA.md` (the Mac's inbox).
- History: `docs/history/phone.md`.
