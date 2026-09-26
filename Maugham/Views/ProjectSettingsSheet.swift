import SwiftUI
import MaughamCore

struct ProjectSettingsSheet: View {
    @Bindable var store: ProjectStore
    @Environment(UserPreferences.self) private var userPreferences
    @Environment(\.dismiss) private var dismiss

    /// **Where a Describe… press hands the writer on** (two loops P2 Task 6).
    ///
    /// The sheet cannot post the `.firstReader` segment event itself: that
    /// post is scoped `.keyWindow`, and while a sheet is up the
    /// KEY window is the sheet's own — the project window behind it would
    /// filter the command out (`MaughamEvent.shouldDeliver`'s `isWindowKey`),
    /// so the act of closing this sheet is what would swallow it. The
    /// presenter records the request and posts it from the `.sheet`'s
    /// `onDismiss`, which is the framework's own "the sheet is gone" hook.
    var onDescribeFirstReader: () -> Void = {}

    @State private var useDefaults: Bool = true
    @State private var draft: TypographySettings = .defaults
    @State private var reviewPasses: [ReviewPass] = []
    /// The first reader's name as the writer is typing it. A draft rather
    /// than a direct binding because `ProjectStore.setFirstReaderName` writes
    /// `project.json` — a manifest write per keystroke is a file write per
    /// keystroke.
    @State private var firstReaderDraft: String = ""
    @FocusState private var firstReaderNameFocused: Bool

    /// Who may write in this book, as of the last read (spec §6). Nil until the
    /// first resolve lands: a registry read is a directory walk plus a P256
    /// verification per record, so it happens in a `.task` off the main actor
    /// and the section simply is not there until it answers.
    @State private var peopleAndDevices: PeopleAndDevicesModel?
    /// What the last People & Devices verb said when it refused. Cleared on the
    /// next press, so it describes the act the writer just performed and never
    /// an older one.
    @State private var peopleNotice: String?
    /// The act the writer has asked for and not yet confirmed (fix round 1,
    /// Important 3a). Revoke and Retire are irreversible enough to be worth a
    /// sentence first; the alert is presented here because a section is not the
    /// presenter of its own dialogs.
    @State private var confirming: PeopleAndDevicesConfirmation?
    /// **The claim this pane can offer**, from the same read as the model
    /// (`ClaimDecision.offer`), or nil where it may not be offered. Since P3b
    /// smoke find F3 this control is the ONLY way to the claim: no Mac is asked
    /// at open, so a collaborator is never put the question.
    @State private var claimOffer: ClaimOffer?
    /// The claim the writer has pressed *This Book Is Mine…* for and not yet
    /// confirmed — the sheet's item — with the refusal of the last attempt
    /// and whether one is being written.
    @State private var claiming: ClaimOffer?
    @State private var claimRefusal: String?
    @State private var isClaiming: Bool = false
    /// **The one act that asks for a word** (P2 smoke find 3), and the word.
    ///
    /// Its own state rather than a fourth case inside `confirming`, because
    /// SwiftUI's `Alert` value — what `.alert(item:)` builds — cannot hold a
    /// `TextField`, and the modern `actions:` form can. The VALUE is the same
    /// `PeopleAndDevicesConfirmation` the other three go through, and `perform`
    /// is still the one switch, so a fifth act is a compile error there.
    @State private var renaming: PeopleAndDevicesConfirmation?
    @State private var renameDraft: String = ""
    /// **The one act that asks for a rung and a list of pieces** (P3b Task 5).
    ///
    /// Its own `@State` and its own sheet for `renaming`'s reason one step
    /// further on: an `Alert` takes buttons and a text field, and this question
    /// needs a picker over three choices and a list of the book's pieces. The
    /// decisions are still a value — `PermitChangeSheet` draws
    /// `PeopleAndDevicesConfirmation.changePermit`/`.readmit` and holds the
    /// writer's two choices and nothing else.
    @State private var changingPermit: PermitChangeAsk?
    /// What a narrowing would cost this book, as of the last read, so the sheet
    /// can carry the first-narrowing sentence. Nil until it lands and after a
    /// read that refused: the act itself runs the same sweep and refuses in the
    /// error's own words, so a guess here would be a second, quieter account.
    @State private var bookNarrowing: PermitControl.BookNarrowing?
    /// **How many pieces of this book's history the writer has said are gone**
    /// (P3b Task 6). A marking verb no longer waits for one of those, so every
    /// confirmation in this pane says what deciding without it costs. Read
    /// beside the rest of the pane, off the main actor.
    ///
    /// **Per person as well as per book** (fix round 1, Minor 1): a revocation
    /// and a permit change that narrows nobody sweep one person's streams, so
    /// a loss under somebody else's machine is nothing to do with them and
    /// saying otherwise is an over-statement on the screen that can least
    /// afford one.
    @State private var acknowledgedLostHistory = DocumentStore.AcknowledgedLosses()

    /// Who the permit sheet is about, and which of its two questions it is
    /// asking. `Identifiable` so `.sheet(item:)` can key on it, and keyed on
    /// both, because Change… and Re-admit over one person are two questions.
    struct PermitChangeAsk: Identifiable, Equatable {
        let person: PeopleAndDevicesModel.Person
        let isReadmission: Bool
        var id: String {
            "\(isReadmission ? "readmit" : "change")-\(person.fingerprint)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Project Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text(store.manifest.title)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Form {
                Section("Typography") {
                    Picker("Source", selection: $useDefaults) {
                        Text("Use my defaults").tag(true)
                        Text("Customize for this project").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: useDefaults) { _, newValue in
                        Task { await applyDefaultsToggle(newValue) }
                    }

                    if !useDefaults {
                        Picker("Font", selection: Binding(
                            get: { draft.fontFamily },
                            set: { draft.fontFamily = $0; saveDraft() })) {
                            ForEach(curatedFonts(), id: \.fontName) { font in
                                Text(font.displayName).tag(font.fontName)
                            }
                        }
                        .pickerStyle(.menu)

                        Stepper("Size: \(draft.fontSize) pt",
                                value: Binding(get: { draft.fontSize },
                                               set: { draft.fontSize = $0; saveDraft() }),
                                in: 12...24)

                        VStack(alignment: .leading) {
                            Text("Line height: \(String(format: "%.2f", draft.lineHeightMultiplier))")
                            Slider(value: Binding(get: { draft.lineHeightMultiplier },
                                                  set: { draft.lineHeightMultiplier = $0; saveDraft() }),
                                   in: 1.4...2.0, step: 0.05)
                        }

                        Stepper("Page width: \(draft.pageWidthCharacters) chars",
                                value: Binding(get: { draft.pageWidthCharacters },
                                               set: { draft.pageWidthCharacters = $0; saveDraft() }),
                                in: 60...90)
                    }
                }

                screenplaySection()
                coachSection()
                firstReaderSection()
                if let peopleAndDevices {
                    peopleSection(peopleAndDevices)
                }
                reviewPassesSection()
            }
            .formStyle(.grouped)
            // **The consequence, before the act** (fix round 1, Important 3a).
            // `item:` rather than a bool, so the alert cannot be up about a
            // device the writer has since scrolled past: the value IS the
            // question, and dismissing it drops the question.
            // **Two ways to revoke, and the writer picks one** (find 5, ruled
            // 2026-09-18). The `actions:` form rather than `Alert(primary:
            // secondary:)`, which takes exactly two buttons — one destructive
            // act plus Cancel — and a revocation now has two honest shapes.
            // Not a checkbox on one button: a writer who mis-set a toggle would
            // find out by reading their chapters.
            .alert(
                confirming?.title ?? "",
                isPresented: Binding(
                    get: { confirming != nil },
                    set: { if !$0 { confirming = nil } }),
                presenting: confirming
            ) { confirmation in
                Button(confirmation.confirmTitle, role: .destructive) {
                    perform(confirmation)
                }
                if let alternate = confirmation.alternate {
                    Button(alternate.title, role: .destructive) {
                        perform(confirmation, keeping: alternate.scope)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                // One message, both costs. An alert has a single message and
                // the choice is between two consequences, so a writer shown
                // only the default's would be choosing in the dark.
                Text(PeopleAndDevicesConfirmation.alertMessage(for: confirmation))
            }
            // **The word, before the act** (smoke find 3). A separate modifier
            // because only the `actions:` form takes a `TextField`; Rename is
            // refused on an empty field the way the admission sheet refuses one
            // — an empty label is a cleared field, not a name.
            .alert(
                renaming?.title ?? "",
                isPresented: Binding(
                    get: { renaming != nil },
                    set: { if !$0 { renaming = nil } }),
                presenting: renaming
            ) { confirmation in
                TextField(confirmation.field?.prompt ?? "", text: $renameDraft)
                Button(confirmation.confirmTitle) { perform(confirmation) }
                    .disabled(renameDraft.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
            // **The claim, confirmed** (spec §5, made a verb by F3). The same
            // sheet the open used to put up unasked; now only a press reaches
            // it, and Cancel closes it having written nothing.
            .sheet(item: $claiming) { offer in
                ClaimSheet(
                    offer: offer,
                    projectTitle: store.manifest.title,
                    refusal: claimRefusal,
                    isClaiming: isClaiming,
                    onClaim: { claimBook(offer) },
                    onCancel: { claiming = nil })
            }
            // **The rung, and the pieces, before the act** (P3b Task 5). A
            // sheet rather than a third alert: an `Alert` takes buttons and a
            // text field, and this question needs a picker and a list.
            .sheet(item: $changingPermit) { ask in
                PermitChangeSheet(
                    person: ask.person,
                    pieces: PermitControl.pieces(in: store.manifest.structure),
                    book: bookNarrowing,
                    lostHistory: acknowledgedLostHistory.count(
                        ofPerson: ask.person.fingerprint),
                    lostHistoryInTheBook: acknowledgedLostHistory.book,
                    isReadmission: ask.isReadmission,
                    commit: { permit in
                        changingPermit = nil
                        if ask.isReadmission {
                            readmitDevice(ask.person, as: permit)
                        } else {
                            changePersonPermit(ask.person.fingerprint, to: permit)
                        }
                    },
                    cancel: { changingPermit = nil })
            }

            HStack {
                Spacer()
                // **Done commits the name first** (fix round 1). A SwiftUI
                // Button click does not resign an `NSTextField`, so the field
                // never loses focus before teardown and the draft would go
                // with the sheet — the one control here that can discard the
                // writer's words (constitution must #1). `.onDisappear` on the
                // section catches Escape and every other teardown.
                //
                // **On Done both run, and both write** (whole-branch review of
                // two loops P2, finding M3). The guard they share reads
                // `store.manifest.firstReaderName`, and the first commit's
                // write is a detached `Task` that has not landed by the time
                // `dismiss()` tears the sheet down — so the second sees the
                // same stale value and saves the same string again. It is
                // idempotent and nothing is lost; it costs one extra manifest
                // save on a control the writer presses once. Not fixed by
                // mirroring the committed name in `@State`, which would be a
                // second source of truth for a value the manifest already
                // holds, for a duplicate write of an identical string.
                Button("Done") {
                    commitFirstReaderName()
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 540, minHeight: 360)
        .task { initializeDraft() }
        .task { await loadPeopleAndDevices() }
    }

    private func curatedFonts() -> [TypographySettings.CuratedFont] {
        store.manifest.type == .screenplay
            ? TypographySettings.curatedScreenplayFonts
            : TypographySettings.curatedFonts
    }

    private func initializeDraft() {
        if let override = store.manifest.typography {
            useDefaults = false
            draft = override
        } else {
            useDefaults = true
            draft = userPreferences.typography
        }
        reviewPasses = store.manifest.effectiveReviewPasses
        firstReaderDraft = store.manifest.firstReaderName ?? ""
    }

    private func applyDefaultsToggle(_ usingDefaults: Bool) async {
        if usingDefaults {
            try? await store.setProjectTypography(nil)
        } else {
            // Seed the override with the user-default snapshot
            draft = userPreferences.typography
            try? await store.setProjectTypography(draft)
        }
    }

    private func saveDraft() {
        guard !useDefaults else { return }
        let d = draft
        Task { try? await store.setProjectTypography(d) }
    }

    @ViewBuilder
    private func screenplaySection() -> some View {
        if store.manifest.type == .screenplay {
            Section("Screenplay") {
                Toggle("Show element gutter", isOn: Binding(
                    get: { store.manifest.showElementGutter ?? true },
                    set: { newValue in
                        Task { await applyGutterToggle(newValue) }
                    }))
            }
        }
    }

    private func applyGutterToggle(_ newValue: Bool) async {
        // Persist as nil when value matches default (show), else explicit.
        try? await store.setShowElementGutter(newValue ? nil : false)
    }

    // MARK: - The coach's seat (editorial letter P1, Task 6)

    /// **One row, above the ladder, and the one off switch for the seat**
    /// (spec §4.1).
    ///
    /// It sits BEFORE the pass list because the coach is not a pass: she is
    /// read by every piece the ladder has nothing to say about, and a row
    /// underneath the list would read as a fifth stage.
    ///
    /// **No draft buffer.** The Review Passes section below batches its edits
    /// behind an explicit Save because it is an array of names a writer types;
    /// this is one Bool, and a Save button over a single switch is a control
    /// whose state the writer has to remember. It writes straight through
    /// `ProjectStore.setCoachVacated` — the one verb, deliberately not
    /// `setReviewPasses`, since the coach is never in that array.
    ///
    /// Nothing is confirmed and nothing is destroyed: her past rounds stay in
    /// the diagnostics sidecar as history, and Restore brings her back where
    /// she left off, which is what the footer says.
    @ViewBuilder
    private func coachSection() -> some View {
        let coach = store.manifest.effectiveCoach
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(coach?.effectiveEditorName
                         ?? ReviewPass.coachPreset.effectiveEditorName)
                        .foregroundStyle(coach == nil ? .secondary : .primary)
                    Text(coach == nil
                         ? "The seat is vacant. An unassigned piece is read by "
                           + "the plain all-altitudes reader, signed \u{201C}Claude\u{201D}."
                         : "Reads any piece you haven\u{2019}t assigned a pass to, "
                           + "and signs what she writes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(coach == nil ? "Restore" : "Vacate") {
                    let vacated = (coach != nil)
                    Task { try? await store.setCoachVacated(vacated) }
                }
                .help(coach == nil
                      ? "Put the coach back in the seat"
                      : "Hand unassigned pieces back to the plain reader. Her "
                        + "past rounds stay in the piece\u{2019}s history.")
            }
        } header: {
            Text("Coach")
        } footer: {
            Text("The coach is not a pass \u{2014} she is never a column on the board and never something a piece is done with. Vacating loses nothing: her rounds stay in each piece\u{2019}s history, and restoring the seat brings her back where she left off.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The first reader (two loops P2, spec §4)

    /// **One specific person the writer writes toward, named here and
    /// described in her own statement** — directly beneath the coach's seat,
    /// because she is the other answer to the same question and neither of
    /// them is a pass.
    ///
    /// **The name is metadata; the description is prose.** The two are
    /// deliberately different kinds of thing and live in different places:
    /// `ProjectManifest.firstReaderName` travels with the book and is what
    /// every surface renders, while what she knows is markdown the writer
    /// edits in a pane (`Statement.Kind.firstReader`). Clearing the name here
    /// takes nothing away from that file.
    ///
    /// **A draft buffer, unlike the coach's row above.** The seat is one Bool
    /// and writes straight through; this is a name being typed, and
    /// `setFirstReaderName` saves the manifest — so it is committed on submit
    /// and on focus loss, never per keystroke. There is no Save button, for
    /// the coach row's own reason: a control whose state the writer has to
    /// remember, over a single field, is worse than a field that keeps itself.
    @ViewBuilder
    private func firstReaderSection() -> some View {
        let describe = Self.describeButton(
            name: firstReaderDraft,
            statementExists: store.statement(kind: .firstReader, scope: .project) != nil)
        Section {
            TextField("Name", text: $firstReaderDraft)
                .focused($firstReaderNameFocused)
                .onSubmit { commitFirstReaderName() }
                .onChange(of: firstReaderNameFocused) { _, focused in
                    if !focused { commitFirstReaderName() }
                }

            HStack {
                Spacer()
                Button(describe.title) { describeFirstReader() }
                    .disabled(!describe.enabled)
                    .help(describe.enabled
                          ? "Open her statement and write down who she is"
                          : "Name her first \u{2014} her statement is about a person")
            }
        } header: {
            Text("First reader")
        } footer: {
            Text("One specific person you write toward, by name. Describe her: what she reads, what she loves, what she will not sit through.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        // Escape, ⌘W, and any other teardown Done does not run through.
        .onDisappear { commitFirstReaderName() }
    }

    /// **What the Describe button says and whether it can be pressed** — pure,
    /// so the rule is assertable with nothing mounted (tripwire 33).
    ///
    /// **`statementExists` is asked of the MANIFEST, not of `FirstReader`.**
    /// `FirstReader.statement` is nil for a statement whose prose is blank,
    /// which is the state a writer is in the moment after they press this
    /// button — reading it here would offer them "Describe…" again over a file
    /// they have already opened, and a second press would be a second look for
    /// a statement that is already there.
    ///
    /// Disabled while the name is empty because the statement is about a
    /// person: there is nobody to describe until she has been named, and a
    /// live button here would mint `first-reader.md` for a reader who does not
    /// exist.
    static func describeButton(
        name: String, statementExists: Bool
    ) -> (title: String, enabled: Bool) {
        let named = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (statementExists ? "Edit description\u{2026}" : "Describe\u{2026}", named)
    }

    /// **Whether the typed name differs from what the manifest holds** — pure,
    /// so the guard every commit path shares is assertable with no window.
    ///
    /// **Compared TRIMMED, on both sides.** `setFirstReaderName` trims what it
    /// stores, so a draft of `" Ursula "` never equals the stored `"Ursula"`
    /// and a raw comparison re-saves `project.json` on every focus loss over a
    /// field the writer has not touched. Nil and blank are the same state for
    /// the same reason: `setFirstReaderName` maps a blank to nil, so an
    /// emptied field is "no first reader" rather than a reader named "".
    static func nameNeedsCommitting(draft: String, stored: String?) -> Bool {
        func normalized(_ value: String?) -> String {
            (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized(draft) != normalized(stored)
    }

    /// Commit the typed name, or clear it. Called from submit, focus loss,
    /// Done and teardown — all four guarded alike.
    ///
    /// **The guard is against the MANIFEST, so it is not synchronous** (M3).
    /// The write below is a detached `Task`; two calls in one turn — Done, then
    /// `.onDisappear` — both read the pre-write value and both save. The same
    /// string either way, so this is a redundant file write rather than a lost
    /// or reordered one, and it is why the four callers are safe to have.
    // MARK: - People & Devices

    /// Resolve who may write in this book, off the main actor.
    ///
    /// **The registry read and the trust table are one act**
    /// (`TrustResolution.resolveVerified`), for its own stated reason: a
    /// surface that read the folder a second time would describe a device off a
    /// registry the verdicts were not taken from.
    ///
    /// **It refuses out loud** (RULING-54). A record present and unreadable
    /// answers `DeviceStanding.refused`, whose sentence names the file and says
    /// what Maugham will not do over it — never an empty list of people, which
    /// would read as *nobody may write in this book*.
    ///
    /// **What is waiting is everything this window is holding** — the open
    /// documents' own loads, the closed documents' last sweep (carry C4) and
    /// the project's capture stream, unioned by
    /// `DocumentStore.heldLinesByDevice` and turned into requests by
    /// `AdmissionDecision.requests`, which is the list the admission sheet
    /// queues. One derivation, because a pane counting only captures would say
    /// nobody is waiting while a chapter holds forty lines (Task 6's review).
    /// The inbox is refreshed first: its count is whatever its last read held.
    private func loadPeopleAndDevices() async {
        await store.documentStore?.inboxStore.refresh()
        // **One walk, both halves** (P3b Task 4/5). The counts are what
        // `requests` is built from, and the same map is what the rows Task 5
        // owes are built from — the holders `requests` DECLINED. A second walk
        // to find them would be a second opinion about who is waiting.
        let union = store.documentStore?.heldLines() ?? HeldLineUnion()
        let pending = union.counts
        let heldStreams = union.streams
        // §7.2's questions (fix round 1, I3) — the SAME union the sheet reads,
        // and this Mac's own memory of the ones already put off, which this
        // pane lists and the sheet does not.
        let heldPieceStarts = union.startedAPiece
        // What those lines ARE, per piece, and the captures (P3b smoke F2):
        // the pending rows say what the admission sheet says.
        let heldWaiting = union.waiting
        let heldCaptures = union.captures
        let declinedPieces = store.documentStore?.declinedPieceQuestions() ?? []
        let settledPieces = store.documentStore?.settledPieceQuestions() ?? []
        // What a narrowing would cost this book: the unsigned rows' subject,
        // and the sheet's first-narrowing sentence. It is the same read the
        // admission sheet makes, through the same store verb, so the two
        // surfaces cannot say different things about one folder.
        let reading = await store.documentStore?.unsignedReading()
            ?? DocumentStore.UnsignedReading()
        bookNarrowing = reading.refusal == nil
            ? PermitControl.BookNarrowing(
                alreadyNarrowed: reading.alreadyNarrowed,
                holdsAnUnsignedStream: reading.holdsAnUnsignedStream)
            : nil
        let unsignedStreams = reading.streams
        // What the writer has already said is gone: every confirmation below
        // states what deciding without it costs (P3b Task 6), counted by the
        // streams the act it precedes actually sweeps (fix round 1).
        acknowledgedLostHistory = await store.documentStore?
            .acknowledgedLostHistory() ?? DocumentStore.AcknowledgedLosses()
        let pieces = PermitControl.pieces(in: store.manifest.structure)
        let url = store.url
        let loaded = await Task.detached(priority: .userInitiated) {
            () -> (PeopleAndDevicesModel, ClaimOffer?) in
            let mine = LocalIdentities.current
            let remembered = AdmissionMemory.shared.remembered
            let claimants = RegistryCache.shared.claimants(for: url)
            // **Which pieces no opening has reached** (Task 8): op-log file
            // PRESENCE, the load's own `needsBootstrap` test — a piece with no
            // file is exactly one this Mac's load would refuse as waiting. One
            // listing of the ops folder, off the main actor, and only for the
            // pieces that record a starter. A folder that will not list says
            // nothing is waiting rather than that everything is.
            let unopened = StrandedPieces.unopened(pieces, in: url)
            do {
                let resolved = try TrustResolution.resolveVerified(
                    projectURL: url, identities: mine)
                // Read AFTER the resolve, because the resolve is what restores:
                // a record this open put back must be marked on the row this
                // open draws, not on the next one.
                let restores = RegistryCache.shared.restores(for: url)
                // Which unverifiable records this Mac could put back, asked of
                // the memory here rather than inside the model — the model
                // reads no shared cache, which is what lets every rule in it be
                // pinned as a value (smoke find 1).
                let restorable = Set(resolved.registry.malformed
                    .compactMap(\.ref)
                    .filter { RegistryCache.shared.rawBytes(of: $0, for: url) != nil })
                let claim = ClaimDecision.offer(
                    registry: resolved.registry, table: resolved.table,
                    canWriteRegistry: ClaimDecision.canWriteRegistry(in: url),
                    canSign: mine.author.canSign)
                let model = PeopleAndDevicesModel.make(
                    registry: resolved.registry, table: resolved.table,
                    remembered: remembered,
                    requests: AdmissionDecision.requests(
                        pending: pending, streams: heldStreams,
                        registry: resolved.registry,
                        memory: remembered,
                        // A root's question (Ruling AA): an admitted Mac lists
                        // nobody as waiting on it, as its sheet asks nobody.
                        myRoot: AdmissionDecision.askingRoot(
                            in: resolved.registry, thisDevice: mine.author.fingerprint),
                        thisDevice: mine.author.fingerprint),
                    claimants: claimants,
                    restores: restores,
                    restorable: restorable,
                    standing: DeviceStanding.resolve(
                        registry: resolved.registry, cache: .shared,
                        mine: mine, for: url),
                    me: mine.author.fingerprint,
                    held: pending,
                    heldStreams: heldStreams,
                    unsignedStreams: unsignedStreams,
                    pieces: pieces,
                    unopenedPieces: unopened,
                    heldPieceStarts: heldPieceStarts,
                    heldWaiting: heldWaiting,
                    heldCaptures: heldCaptures,
                    declinedPieces: declinedPieces,
                    settledPieces: settledPieces)
                return (model, claim)
            } catch {
                // A registry this Mac could not read judges nobody, so there is
                // no chain to be a stranger to and no request to make of the
                // writer — the refusal below is the whole of what this section
                // says (RULING-54).
                // Nor a claim: a book whose register will not read is not one
                // this Mac can know it has no key in.
                return (PeopleAndDevicesModel.make(
                    registry: Registry(), table: TrustResolution.keyless(mine: mine),
                    remembered: remembered, requests: [], claimants: claimants,
                    standing: DeviceStanding.refused(mine: mine, error: error),
                    me: mine.author.fingerprint), nil)
            }
        }.value
        peopleAndDevices = loaded.0
        claimOffer = loaded.1
    }

    /// People & Devices, extracted from `body` for `ProjectWindow.body`'s
    /// established reason — the type-check ceiling, which this section reached
    /// the moment §7.2's two verbs joined its eleven others (fix round 1, I3).
    private func peopleSection(
        _ model: PeopleAndDevicesModel
    ) -> some View {
        PeopleAndDevicesSection(
            model: model,
            admit: {
                // The window opens the sheet; a settings sheet is not a
                // presenter of another sheet, and only the window knows which
                // device is waiting on it now.
                MaughamEvent.postAdmissionRequested(
                    projectURL: store.url, forced: true)
                dismiss()
            },
            forget: forgetDevice,
            revoke: confirmRevoke,
            retire: confirmRetire,
            readmit: askReadmission,
            rename: confirmRename,
            restore: confirmRestore,
            merge: confirmMerge,
            changePermit: askPermitChange,
            resign: confirmResign,
            onPieceIsTheirs: answerPieceQuestion,
            onPieceNotNow: putPieceQuestionOff,
            writeAgain: confirmWriteAgain,
            claim: claimOffer,
            claimBook: askToClaim,
            notice: peopleNotice)
    }

    // MARK: - §7.2's piece questions (fix round 1, I3)

    /// **Yes, that piece is theirs.** The store verb decides everything about
    /// the permit — what is in force now, whether this Mac may change it,
    /// every record of theirs, the cut that brings her held lines in — and a
    /// refusal is reported in the pane's own notice rather than swallowed
    /// (RULING-7).
    private func answerPieceQuestion(_ question: LoadQuestions.NewPiece) {
        peopleNotice = nil
        guard let documentStore = store.documentStore else { return }
        Task { @MainActor in
            do {
                _ = try await documentStore.pieceIsTheirs(
                    person: question.person, docId: question.docId)
            } catch {
                peopleNotice = AdmissionDecision.refusal(error)
            }
            await loadPeopleAndDevices()
        }
    }

    /// **Not now**, from the pane. It writes nothing to the book; the row
    /// stays, saying it was put off.
    private func putPieceQuestionOff(_ question: LoadQuestions.NewPiece) {
        peopleNotice = nil
        store.documentStore?.notNowAboutPiece(
            person: question.person, docId: question.docId)
        Task { await loadPeopleAndDevices() }
    }

    /// Ask first. The row hands back the fingerprint; the name comes from the
    /// model the row was drawn from, so the alert says who it is about in the
    /// words the writer gave them.
    private func confirmRevoke(_ fingerprint: String) {
        peopleNotice = nil
        let name = peopleAndDevices?.people
            .first { $0.fingerprint == fingerprint }?.title
            ?? DeviceCode.short(fingerprint)
        confirming = .revoke(
            person: fingerprint, named: name,
            // A revocation marks THIS person's streams
            // (`expectedStreams(ofDeviceIds:)`), so it is decided without what
            // was put down about them and about nobody else (fix round 1).
            lostHistory: acknowledgedLostHistory.count(ofPerson: fingerprint))
    }

    private func confirmRetire(_ fingerprint: String) {
        peopleNotice = nil
        let device = peopleAndDevices?.people
            .flatMap(\.devices)
            .first { $0.fingerprint == fingerprint }
        confirming = .retire(
            device: fingerprint,
            named: device?.name ?? DeviceCode.short(fingerprint),
            kind: device?.kind ?? "Mac")
    }

    /// **This book is mine** — open the confirmation (F3). The offer is the
    /// one this pane's read decided, so the sheet names the roots the control
    /// was drawn for.
    private func askToClaim() {
        peopleNotice = nil
        claimRefusal = nil
        claiming = claimOffer
    }

    /// Write this Mac's own root record and the claim adopting what it found.
    /// A refusal keeps the sheet up carrying its own sentence — a dialog must
    /// never close on a write that did not happen — in `AdmissionDecision`'s
    /// words, the one vocabulary a `RegistryAdmissionError` becomes.
    private func claimBook(_ offer: ClaimOffer) {
        guard !isClaiming else { return }
        // The window's store is what performs a claim; a settings sheet up
        // before it exists (a project still opening) says so on the sheet
        // rather than closing on a write that never happened (RULING-7).
        guard let documentStore = store.documentStore else {
            claimRefusal = Self.claimNotReady
            return
        }
        isClaiming = true
        claimRefusal = nil
        Task { @MainActor in
            defer { isClaiming = false }
            do {
                _ = try await documentStore.claim(adopting: offer.roots)
                claiming = nil
            } catch {
                claimRefusal = AdmissionDecision.refusal(error)
            }
            await loadPeopleAndDevices()
        }
    }

    /// What the claim's sheet says when the project has no store to perform
    /// it yet.
    static let claimNotReady =
        "This book is still opening, so nothing was claimed. Try again in a moment."

    /// **Is that root also you?** The claimant row's own question, asked before
    /// a chain of somebody's devices starts applying here (Task 8).
    private func confirmMerge(_ fingerprint: String) {
        peopleNotice = nil
        let name = peopleAndDevices?.claimants
            .first { $0.fingerprint == fingerprint }?.name
            ?? DeviceCode.short(fingerprint)
        confirming = .merge(root: fingerprint, named: name)
    }

    /// **Rename somebody** (smoke find 3). The field starts at the name that
    /// stands, so an untouched field and Cancel come to the same thing.
    private func confirmRename(_ person: PeopleAndDevicesModel.Person) {
        peopleNotice = nil
        let confirmation = PeopleAndDevicesConfirmation.rename(
            person: person.fingerprint, named: person.title, currently: person.label)
        renameDraft = confirmation.field?.initialValue ?? person.label
        renaming = confirmation
    }

    /// **Put a record back** (smoke find 1) — the deliberate press, over a file
    /// this device has just told the writer does not verify.
    private func confirmRestore(_ record: PeopleAndDevicesModel.Unverifiable) {
        peopleNotice = nil
        confirming = .restore(
            record: record.ref, named: record.name, kind: record.kind)
    }

    /// The writer confirmed. One switch, so a further act cannot be added to
    /// the value without being given a verb here.
    private func perform(
        _ confirmation: PeopleAndDevicesConfirmation,
        keeping scope: RevocationScope = .whatWasApplied
    ) {
        switch confirmation.verb {
        case .revoke: revokeDevice(confirmation.fingerprint, keeping: scope)
        case .retire: retireThisMac(confirmation.fingerprint)
        case .merge: mergeRoot(confirmation.fingerprint)
        case .rename: renamePerson(confirmation.fingerprint, to: renameDraft)
        case .restore:
            // The ref is the act. A confirmation that reached here without one
            // would be a Restore about half a record, so it does nothing rather
            // than guessing a directory.
            if let record = confirmation.record { restoreRecord(record) }
        case .changePermit:
            // The permit is the act, and it is asked for in a sheet of its own
            // (`changingPermit`) rather than in an alert, so nothing reaches
            // this arm from the alert path. A value that did would be a permit
            // change with no permit, which does nothing rather than guessing a
            // rung.
            if let permit = confirmation.permit {
                changePersonPermit(confirmation.fingerprint, to: permit)
            }
        case .resign: resignRecord(confirmation.fingerprint)
        case .writeOwnRecord:
            if let record = confirmation.record { writeOwnRecordAgain(record) }
        }
    }

    // MARK: - What somebody may write (P3b Task 5)

    /// **Ask the rung, starting where they already are.** The sheet is opened
    /// rather than the act performed: widening what somebody may write is the
    /// direction a writer must never be moved in silently, and that holds for
    /// Re-admit as much as for Change… (Task 4's review, the Critical).
    private func askPermitChange(_ person: PeopleAndDevicesModel.Person) {
        peopleNotice = nil
        changingPermit = PermitChangeAsk(person: person, isReadmission: false)
    }

    /// **Let them back in, and say what that installs.** Before this, Re-admit
    /// called `admit` with no permit at all — whose default is the whole book,
    /// and which a REVOKED record takes from the caller — so an author of two
    /// chapters came back an author of the novel with nothing on screen.
    ///
    /// **And it refuses over a permit this build cannot draw** (Task 5's
    /// ruling, built in Task 6). The row's button is disabled for that case,
    /// so this is the second door on the same stop: the sheet's control has no
    /// rung to start at, and starting it at the whole book would be exactly
    /// the silent widening above, chosen by the build that understands least.
    private func askReadmission(_ person: PeopleAndDevicesModel.Person) {
        peopleNotice = nil
        if let why = person.whyNotReadmittable {
            peopleNotice = why
            return
        }
        changingPermit = PermitChangeAsk(person: person, isReadmission: true)
    }

    /// **Bring a record up to this book's history** (spec §3.2's crash window).
    private func confirmResign(_ person: PeopleAndDevicesModel.Person) {
        peopleNotice = nil
        guard let history = person.historySays else { return }
        confirming = .resign(
            person: person.fingerprint, named: person.title,
            history: PermitControl.choice(displaying: history)?.title
                ?? "something this version of Maugham doesn\u{2019}t recognise",
            record: person.rung?.title ?? "something else")
    }

    /// **Write this Mac's own record again** (audit F4) — the last resort, over
    /// a record this device cannot Restore because it never read one.
    private func confirmWriteAgain(_ record: PeopleAndDevicesModel.Unverifiable) {
        peopleNotice = nil
        confirming = .writeOwnRecord(record: record.ref, kind: record.kind)
    }

    /// **Every machine of one writer at once** (fix round 1, I3): the pane
    /// calls `changePermit(everyRecordOf:to:)` and never the single-record
    /// primitive, because a permit lives on a record and P2b's admission merges
    /// a writer's Mac and phone under one label. Demote the Mac alone and she
    /// goes on writing manuscript text from the phone, applied by every reader.
    private func changePersonPermit(_ fingerprint: String, to permit: Permit) {
        Task { @MainActor in
            guard let store = store.documentStore else { return }
            do { try await store.changePermit(everyRecordOf: fingerprint, to: permit) }
            catch { peopleNotice = AdmissionDecision.refusal(error) }
            await loadPeopleAndDevices()
        }
    }

    private func resignRecord(_ fingerprint: String) {
        Task { @MainActor in
            guard let store = store.documentStore else { return }
            do { try await store.resignRecord(person: fingerprint) }
            catch { peopleNotice = AdmissionDecision.refusal(error) }
            await loadPeopleAndDevices()
        }
    }

    private func writeOwnRecordAgain(_ ref: RecordRef) {
        Task { @MainActor in
            guard let store = store.documentStore else { return }
            do { try await store.writeOwnRecordAgain(ref) }
            catch { peopleNotice = AdmissionDecision.refusal(error) }
            await loadPeopleAndDevices()
        }
    }

    /// **The version this Mac last saw verify, put back.** The store writes it
    /// through the cache's own restore door, forgets every resolved table and
    /// re-reads what is open; this reloads the rows, so the record that was
    /// listed as unverifiable is either gone from that list or still in it with
    /// the reader's reason.
    private func restoreRecord(_ ref: RecordRef) {
        Task { @MainActor in
            guard let store = store.documentStore else { return }
            do { try await store.restore(record: ref) }
            catch { peopleNotice = AdmissionDecision.refusal(error) }
            await loadPeopleAndDevices()
        }
    }

    /// **A word about somebody, not authority over them.** The store writes the
    /// record, forgets every resolved table and re-reads what is open; this
    /// reloads the rows and says so when it refuses, in the one vocabulary
    /// every refusal here speaks.
    private func renamePerson(_ fingerprint: String, to label: String) {
        Task { @MainActor in
            guard let store = store.documentStore else { return }
            do { try await store.rename(person: fingerprint, to: label) }
            catch { peopleNotice = AdmissionDecision.refusal(error) }
            await loadPeopleAndDevices()
        }
    }

    /// **This is also me** (spec §5, plan decision P2) — a claim record
    /// adopting that root's chain, written by this Mac's own root. It is the
    /// same verb the claim sheet performs on a book this Mac has no key in, and
    /// the other Mac presses it too: adoption is symmetric, and until it does
    /// this device is still a claimant over there.
    private func mergeRoot(_ fingerprint: String) {
        Task { @MainActor in
            guard let store = store.documentStore else { return }
            do { try await store.claim(adopting: [fingerprint]) }
            catch { peopleNotice = AdmissionDecision.refusal(error) }
            await loadPeopleAndDevices()
        }
    }

    /// **Let a device back in** (fix round 1, Important 3b) — the same
    /// admission door, under the label and the name the record already holds,
    /// so re-admitting is not also a rename.
    ///
    /// **The permit is the writer's, and it is never defaulted here** (Task 4's
    /// review, the Critical). `RegistryAdmission.admit` over a REVOKED record
    /// installs the role, scope and pieces it is given, and this call used to
    /// give none — so `DocumentStore.admit`'s own default, author of the whole
    /// book, was silently installed over an author of two chapters. The sheet
    /// starts at the permit they held when they were shut out and shows it in
    /// its own sentence; what arrives here is what the writer confirmed.
    private func readmitDevice(
        _ person: PeopleAndDevicesModel.Person, as permit: Permit
    ) {
        peopleNotice = nil
        Task { @MainActor in
            guard let store = store.documentStore else { return }
            do {
                try await store.admit(
                    device: person.fingerprint, label: person.label,
                    ownName: person.recordedOwnName, permit: permit)
            } catch {
                peopleNotice = AdmissionDecision.refusal(error)
            }
            await loadPeopleAndDevices()
        }
    }

    /// **Stop applying what a device writes** (spec §5). The store writes the
    /// record, forgets every resolved table and re-reads what is open; this
    /// only reloads the rows and says so when it refuses.
    private func revokeDevice(_ fingerprint: String, keeping scope: RevocationScope) {
        Task { @MainActor in
            guard let store = store.documentStore else { return }
            do { try await store.revoke(person: fingerprint, keeping: scope) }
            catch { peopleNotice = AdmissionDecision.refusal(error) }
            await loadPeopleAndDevices()
        }
    }

    /// **Say this Mac has stopped writing in this book.** Offered on this Mac's
    /// own row alone — a device signs its own retirement — and refused by
    /// `RegistryAdmission` for anything else, which is where the rule lives.
    private func retireThisMac(_ fingerprint: String) {
        Task { @MainActor in
            guard let store = store.documentStore else { return }
            do { try await store.retire(device: fingerprint) }
            catch { peopleNotice = AdmissionDecision.refusal(error) }
            await loadPeopleAndDevices()
        }
    }

    /// Clear this Mac's memory of the name it gave a device the folder no
    /// longer describes. It touches no registry record — there is none left to
    /// touch, which is the whole reason the row is offered.
    private func forgetDevice(_ fingerprint: String) {
        AdmissionMemory.shared.forget(fingerprint)
        Task { await loadPeopleAndDevices() }
    }

    private func commitFirstReaderName() {
        guard Self.nameNeedsCommitting(
            draft: firstReaderDraft, stored: store.manifest.firstReaderName) else { return }
        let name = firstReaderDraft
        Task { try? await store.setFirstReaderName(name) }
    }

    /// Save the name, make sure she HAS a statement, then hand the writer to
    /// it. The name is committed first because the button is pressable
    /// straight after typing one, with no submit and no focus change in
    /// between — a Describe over an uncommitted name would open a statement
    /// for a reader the manifest has never heard of.
    private func describeFirstReader() {
        let name = firstReaderDraft
        Task { @MainActor in
            // The same guard every other commit path uses — one Task rather
            // than two, so the name is stored before the statement is minted
            // and neither write can land in the other's order.
            if Self.nameNeedsCommitting(
                draft: name, stored: store.manifest.firstReaderName) {
                try? await store.setFirstReaderName(name)
            }
            if store.statement(kind: .firstReader, scope: .project) == nil {
                _ = try? await store.createStatement(kind: .firstReader, scope: .project)
            }
            onDescribeFirstReader()
            dismiss()
        }
    }

    // MARK: - Review Passes (M3 P1 Task 9)

    /// A list editor over `effectiveReviewPasses` — rename in place, add,
    /// delete, drag-reorder. Nothing here writes to the store per keystroke;
    /// Save writes the whole array at once. Rows use a plain always-editable
    /// `TextField`, matching this sheet's existing style for every other
    /// control — there's no `List(selection:)` here and so no rename-mode
    /// focus race to guard against (tripwire 16 doesn't apply: nothing ever
    /// transitions a row INTO rename mode: it's always in it).
    @ViewBuilder
    private func reviewPassesSection() -> some View {
        Section {
            ForEach(reviewPasses) { pass in
                reviewPassRow(pass)
            }

            HStack {
                Button {
                    addReviewPass()
                } label: {
                    Label("Add Pass", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Save") {
                    saveReviewPasses()
                }
                // A blank-named pass must not persist as a blank column
                // header / ladder row — see `ReviewPassEditorLogic.isSavable`
                // for why the guard is here and not in `renamed`.
                .disabled(!ReviewPassEditorLogic.isSavable(reviewPasses))
                .help(ReviewPassEditorLogic.isSavable(reviewPasses)
                      ? "Save the pass list"
                      : "Every pass needs a name before saving")
            }
        } header: {
            Text("Review Passes")
        } footer: {
            Text("These are the columns on Review's board and the rows on each piece's pass ladder. Removing every pass restores the four defaults — Structural, Line, Copyedit, Proof — rather than leaving the project with none.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func reviewPassRow(_ pass: ReviewPass) -> some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Pass name", text: Binding(
                get: { reviewPasses.first { $0.id == pass.id }?.name ?? pass.name },
                set: { reviewPasses = ReviewPassEditorLogic.renamed(reviewPasses, id: pass.id, to: $0) }))

            Spacer()

            Button {
                reviewPasses = ReviewPassEditorLogic.deleted(reviewPasses, id: pass.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Delete \(pass.name)")
        }
        .draggable(pass.id) {
            Text(pass.name)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        }
        .dropDestination(for: String.self) { draggedIds, _ in
            guard let draggedId = draggedIds.first else { return false }
            reviewPasses = ReviewPassEditorLogic.reordered(
                reviewPasses, draggedId: draggedId, droppedOnId: pass.id)
            return true
        }
    }

    private func addReviewPass() {
        reviewPasses = ReviewPassEditorLogic.added(to: reviewPasses, name: "New Pass")
    }

    private func saveReviewPasses() {
        let passes = reviewPasses
        Task { try? await store.setReviewPasses(passes) }
    }
}

/// **Which of a book's pieces no opening has reached** (P3 plan 3 Task 8) —
/// the one folder read behind People & Devices' waiting line, kept out of
/// `PeopleAndDevicesModel`, which reads no folder.
///
/// **Op-log file presence, not `OpLogStore.unownedPiece`.** The question is
/// whether ANY opening is on disk, and presence is exactly the test the load
/// asks before it refuses (`Document.load`'s `needsBootstrap`: no file for the
/// doc id). `unownedPiece` answers a different question — *has a book author
/// written this piece's text* — which is `.nobodyHasWrittenItsText` for a
/// piece whose starter's opening HAS arrived as well as for one with no file
/// at all, and it classifies every file it finds to say so.
enum StrandedPieces {
    /// The ids, among the pieces that record a starter, with no op-log file
    /// in `.maugham/ops/`. One listing, matched through
    /// `OpLogStore.docIds(inOpsDirectoryFilenames:)` (the single source of
    /// truth for filename → doc id). A folder that will not list answers
    /// EMPTY — nothing waiting — because telling the writer to revoke a Mac
    /// over a read that failed would be a trust suggestion nobody earned.
    nonisolated static func unopened(
        _ pieces: [PermitControl.Piece], in projectURL: URL
    ) -> Set<String> {
        let started = pieces.filter { $0.startedBy != nil }
        guard !started.isEmpty else { return [] }
        let ops = projectURL.appendingPathComponent(".maugham/ops", isDirectory: true)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: ops.path)
        } catch {
            // No ops folder at all is a book nothing has been written in:
            // every started piece is unopened. Any other failure says nothing.
            guard !FileManager.default.fileExists(atPath: ops.path) else { return [] }
            names = []
        }
        let opened = OpLogStore.docIds(inOpsDirectoryFilenames: names)
        return Set(started.map(\.id).filter { !opened.contains($0) })
    }
}
