import SwiftUI
import AppKit

/// **What the writer looks at before they say yes** (publish-department P4 Task
/// 5, spec §5's centre) — as decisions and copy, so the gate's truth table is
/// assertable with nothing mounted.
///
/// `DepartmentDesignRow`'s discipline one column over: the view below draws, and
/// everything it could get wrong lives here as a pure function.
enum DesignGate {

    /// **What stands where the sample pages go.** Four arms because there are
    /// four different things that can be true, and three of them are not
    /// "nothing" — RULING-7's shape, which is the whole reason a `SampleResult`
    /// carries its cause instead of being an optional path.
    enum SamplePanel: Equatable {
        /// The pages, at a resolved URL.
        case pages(URL)
        /// The compile ran and produced no pages. `cause` is never empty.
        case failed(cause: String)
        /// The round staged a proposal and no sample was recorded against it —
        /// `DesignerEnvironment.sample`'s `nil`, which is a proposal with no
        /// pages beside it rather than a design that failed.
        case notSampled
        /// The proposal names pages that are no longer on disk. Everything under
        /// `.maugham/design/` is derived and the store's own doc says deleting it
        /// is safe, so this is a state a writer can reach on purpose.
        case missing(path: String)
    }

    /// **Which panel a recorded sample result earns.**
    ///
    /// `pagesExist` is asked of the disk by the view, off its body path, and is
    /// `true` while the answer is still being fetched — so the first frame draws
    /// the pages and a vanished file corrects itself a turn later, rather than
    /// the reverse (a "these are gone" flash over pages that are fine).
    static func panel(for result: DesignProposalStore.SampleResult?,
                      projectURL: URL,
                      pagesExist: Bool) -> SamplePanel {
        switch result {
        case .none:
            return .notSampled
        case .failed(let error):
            let cause = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(cause: cause.isEmpty ? noCauseGiven : error)
        case .pages(let path, _):
            guard pagesExist else { return .missing(path: path) }
            return .pages(pagesURL(path, in: projectURL))
        }
    }

    /// Absolute as itself, relative against the project —
    /// `PublishPreviewResolver.fileURL(of:in:)`'s rule, spelled the same way so
    /// the gate and the book's preview cannot come to disagree about where a PDF
    /// is. (Not that function: it takes a `Publication`, and a sample is not
    /// one — it is never in the catalog and never has a version.)
    static func pagesURL(_ path: String, in projectURL: URL) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : projectURL.appendingPathComponent(path)
    }

    /// **The base-templates caveat** (P4 Global Constraint 3), or `nil` for a
    /// round about the book itself.
    ///
    /// Maugham keeps ONE template set per book. A design round briefed on a
    /// language sets that edition's TEXT — `ProjectStoreASTSource(language:)` —
    /// but its sample compiles against the same publish tree every other round
    /// does, so what the writer is judging is the base design doing the
    /// edition's work. Approving it approves the book's templates, and a gate
    /// that did not say so would be collecting a verdict about something else.
    static func caveat(language: String?) -> String? {
        guard let language else { return nil }
        let name = TranslationReviewIndicator.displayLabel(forLanguageTag: language)
        return "These sample pages set the \(name) edition\u{2019}s text in the "
            + "book\u{2019}s base templates. Maugham keeps one template set per "
            + "book, so an edition round revises that set rather than adding a "
            + "second one \u{2014} approving this changes how every edition is "
            + "typeset."
    }

    // MARK: - Copy

    static let templatesHeading = "Templates in this proposal"

    /// A proposal that staged no files at all. `DesignerReport` accepts an empty
    /// `files` array on purpose — a words-only round is a legitimate answer — and
    /// a heading over nothing is how a writer decides a surface failed to load.
    static let noTemplatesStaged =
        "This round proposes no template files \u{2014} it is a written answer "
        + "only."

    static let demonstratesHeading = "These pages show"

    static let specHeading = "The design"

    static let failedHeadline = "The sample pages didn\u{2019}t compile"

    /// Said under the headline, because the writer's next question is whether
    /// the round is a write-off. It is not: the spec is above, the files are
    /// listed, and every verdict is still available.
    static let failedDetail =
        "The proposal is still here to read, to send back for changes, or to "
        + "turn down. What follows is what the typesetter reported."

    /// The standing sentence for a failure that arrived with nothing to say.
    /// `SampleCompiler.failureSentence` never produces one — it has an arm for
    /// exactly this — but a `proposal.json` is a file on disk, and this is the
    /// one place a writer would otherwise be shown an empty box where a reason
    /// goes.
    static let noCauseGiven =
        "The sample compile failed and recorded no reason. Run another round to "
        + "see what the typesetter says."

    static let notSampledHeadline = "No sample pages for this round"

    static let notSampledDetail =
        "The round staged its templates and no pages were recorded beside them. "
        + "Run another round to see the design set."

    static let missingHeadline = "The sample pages are no longer on disk"

    /// Names the path, RULING-7's shape: the writer can go and look, and if they
    /// cleared `.maugham/design/` they will recognise what they did.
    static func missingDetail(path: String) -> String {
        "This round recorded its pages at \(path), and there is nothing there "
            + "now. Sample pages are derived \u{2014} run another round to "
            + "compile them again."
    }

    static let closeTitle = "Back to the book"

    /// Distinct from the visible title for the reason every control on this
    /// department's surfaces carries one: the visible words are told apart by
    /// where they sit, which a linear accessibility tree does not carry.
    static let closeAccessibilityLabel = "Back to the book"
}

/// **The gate: a design proposal, facing the writer, in Publish's centre
/// column** (publish-department P4 Task 5).
///
/// Two columns, because the decision has two halves that are read together: what
/// the designer *said* on the left (the spec, the caveat when there is one, the
/// files this would stage, and what the sample was chosen to demonstrate), and
/// what it *looks like* on the right. A stacked layout would make the writer
/// scroll between the argument and the evidence.
///
/// **It takes a value, never a store** (tripwire 4, the desk's rule for the
/// desk's reason). The proposal arrives whole from the desk's Show; the one
/// thing this view asks the disk is whether the recorded pages are still there,
/// and that is a `.task` keyed on the path rather than anything on a body path.
///
/// **Opaque and full-frame on purpose**, `PublishPreviewCentre`'s rule: this is
/// a layer of `ProjectWindow.manuscriptEditor`'s `ZStack` with `EditorHost` and
/// the altitude view still mounted underneath it, and anything translucent would
/// read the corkboard through the page.
///
/// **And the verdict, along the bottom** (Task 6). Approve / Request Changes /
/// Revert / Finalize sit in a footer under both columns rather than in the
/// header, because they are what the writer does *after* reading the two halves
/// above — and because the header's other control is the way OUT, which must not
/// end up adjacent to the way the templates ship.
///
/// **Which verbs are drawn is a pure function of the proposal's status**
/// (`DesignGate.verbs`), and the proposal is a value owned by the window. That
/// is the whole of "transitions reflect immediately": a verb hands its result to
/// `onProposalChanged`, the window rewrites the value, and the footer that drew
/// Approve draws Revert and Finalize on the next body pass. A gate that kept a
/// `@State` copy of the proposal would be the second source of truth this shape
/// exists to avoid.
///
/// **Nothing here registers with `NSUndoManager`.** `ProposalPromotion`'s type
/// doc settles it: the reversal is `revert`, a verb asked for by name, and a ⌘Z
/// in a text pane must never un-ship a book's templates.
struct DesignGateView: View {
    let proposal: DesignProposalStore.Proposal
    let projectURL: URL
    var actions: DesignGateActions = DesignGateActions()
    var hasOpenProposalRound: Bool = false
    var onClose: () -> Void = { }
    var onProposalChanged: (DesignProposalStore.Proposal) -> Void = { _ in }

    /// **The verb standing at its confirmation, published as it comes and
    /// goes** — `nil` when nothing is waiting on the writer.
    ///
    /// Production passes nothing: the dialog below is drawn from the same state
    /// and needs no witness. It exists because a `.confirmationDialog` belongs
    /// to the window server and a headless mount can neither read its words nor
    /// press its buttons — so without this, the one irreversible verb on this
    /// surface would be the one verb no test could drive past its own press.
    var onConfirmationChanged: (DesignGateConfirmation?) -> Void = { _ in }

    /// Whether the recorded pages are still on disk. Starts `true` so the first
    /// frame draws them — see `DesignGate.panel`'s doc for why that direction.
    @State private var pagesExist = true

    /// **What the last verb said** — a refusal in its own words, or the
    /// confirmation that it worked. The gate's one transient-message channel,
    /// `DepartmentPane.notice`'s shape and for its reason: a click that produces
    /// nothing visible is the silent no-op Global Constraint 2 exists against.
    @State private var notice: String?

    /// The writer's words for the next round. Local to this surface for the
    /// reason `DepartmentPane.direction` is local to the desk: it is the field's
    /// own text, and a `Binding` up to the window would put a keystroke-rate
    /// write on `ProjectWindow`'s state (tripwire 3's shape).
    @State private var words = ""

    /// True between a verb's press and its answer. The verbs are file I/O over
    /// the writer's whole template set, so a second press mid-promotion is a
    /// second backup attempt — refused by `ProposalPromotion` with a sentence,
    /// but a disabled control is the cheaper answer.
    @State private var working = false

    /// The verb that has been pressed and is waiting for the writer to say yes
    /// — `DesignGate.confirmation`'s answer, held until one of its two ways out
    /// is taken. `nil` the rest of the time, which is most of the time.
    @State private var pendingConfirmation: DesignGateConfirmation?

    private var verbs: [DesignGate.Verb] {
        DesignGate.verbs(status: proposal.status,
                         hasOpenProposalRound: hasOpenProposalRound)
    }

    private var panel: DesignGate.SamplePanel {
        DesignGate.panel(for: proposal.sampleResult, projectURL: projectURL,
                         pagesExist: pagesExist)
    }

    /// The lines the selection wrote for the writer — present only on a sample
    /// that produced pages, because they are an account OF those pages.
    private var demonstrates: [String] {
        guard case .pages(_, let lines) = proposal.sampleResult else { return [] }
        return lines
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                rail
                Divider()
                sample
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        // Asked here, never on a body path, and re-asked when the path moves —
        // which it does when the writer Shows a different round.
        .task(id: recordedPagesPath) { await checkPages() }
        // **A different round is a different decision.** Keyed on the id rather
        // than the whole proposal: a verb's own write-back changes the value and
        // must NOT clear the sentence it just produced, which is the one thing
        // telling the writer what happened.
        .onChange(of: proposal.id) { _, _ in
            notice = nil
            words = ""
        }
        // **The one verb that asks first** (`DesignGate.confirmation`). The
        // buttons run the value's own closures rather than deciding anything
        // here, so the button labelled Finalize is the one that finalizes and a
        // dismissal — Escape, or a click outside — takes the cancel path like
        // any other no.
        .confirmationDialog(
            pendingConfirmation?.title ?? DesignGate.finalizeConfirmTitle,
            isPresented: Binding(get: { pendingConfirmation != nil },
                                 set: { if !$0 { cancelConfirmation() } }),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { confirmation in
            Button(confirmation.confirmTitle, role: .destructive) {
                confirmation.perform()
            }
            Button(confirmation.cancelTitle, role: .cancel) {
                confirmation.cancel()
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    /// Who made this, where it stands, and the way out.
    ///
    /// The second line is `DepartmentDesignRow.latestLine` — the desk's own
    /// sentence about this proposal, not a second one written here. A writer who
    /// clicked "Round 2 · waiting for your review · 5 min ago" on the desk must
    /// arrive at a surface that agrees it is that.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(proposal.designerName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(DepartmentDesignRow.latestLine(proposal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(DesignGate.closeTitle) { onClose() }
                .controlSize(.small)
                .accessibilityLabel(DesignGate.closeAccessibilityLabel)
                .help("Stop looking at this proposal and show the compiled book "
                      + "again. Nothing about the proposal changes.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// **The left half: everything the writer reads**, in two scrollers rather
    /// than one.
    ///
    /// The argument is on top and takes the room; the facts about it sit in a
    /// bounded footer underneath. **Two, and never one containing the other**:
    /// `GuideMarkdownView` brings its own `ScrollView` — it is the Help window's
    /// renderer — and nesting it inside a rail-wide scroller gives the writer two
    /// vertical gestures over the same pixels, with the inner one silently eating
    /// the outer's. Splitting them is what lets the spec keep an unbounded height
    /// while the file list stays where the writer left it.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let caveat = DesignGate.caveat(language: proposal.language) {
                editionCaveat(caveat)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
            }
            // The app's ONE read-only markdown renderer, which the Help window
            // uses. A second one here would be a second answer to how a heading
            // looks.
            GuideMarkdownView(markdown: proposal.specMarkdown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            facts
        }
        .frame(width: 340)
    }

    /// The bounded footer: what this round would stage, and what its pages were
    /// chosen to prove. Short by nature and scrollable when it is not — a
    /// twenty-file template set must not push the spec off the column.
    private var facts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section(DesignGate.templatesHeading) {
                    if proposal.filePaths.isEmpty {
                        Text(DesignGate.noTemplatesStaged)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(proposal.filePaths, id: \.self) { path in
                                Text(path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                // Absent when there are none rather than drawn empty — the
                // desk's `queryLine` rule: a heading that says nothing every
                // time trains the writer to stop reading it.
                if !demonstrates.isEmpty {
                    section(DesignGate.demonstratesHeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(demonstrates, id: \.self) { line in
                                Text("\u{2022} \(line)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
    }

    /// The right half: the pages, or why there are none.
    @ViewBuilder
    private var sample: some View {
        switch panel {
        case .pages(let url):
            PDFPreview(fileURL: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let cause):
            // The cause is a tectonic diagnostic — monospaced, selectable, and
            // in a scroller of its own, because `SampleCompiler.failureSentence`
            // can carry a 1200-character log tail and this half of the column
            // must not be resized by it.
            notice(symbol: "exclamationmark.triangle.fill", tint: .orange,
                   headline: DesignGate.failedHeadline,
                   detail: DesignGate.failedDetail) {
                ScrollView {
                    Text(cause)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .notSampled:
            notice(symbol: "doc.questionmark", tint: .secondary,
                   headline: DesignGate.notSampledHeadline,
                   detail: DesignGate.notSampledDetail) { EmptyView() }
        case .missing(let path):
            notice(symbol: "questionmark.folder", tint: .secondary,
                   headline: DesignGate.missingHeadline,
                   detail: DesignGate.missingDetail(path: path)) { EmptyView() }
        }
    }

    // MARK: - The verdict (Task 6)

    /// **The footer: what the writer can do about this round, and what happened
    /// last time they did.**
    ///
    /// Always drawn, never conditionally: `DesignGate.verbs` is empty exactly
    /// when `settledNote` is not, so every status has something to say here.
    /// A footer that vanished over a superseded round would leave the writer
    /// looking for controls that were never coming.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(notice)
            }
            if let settled = DesignGate.settledNote(proposal) {
                Text(settled)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The words ride ABOVE the buttons rather than beside them: the field
            // grows to three lines, and a row that changed height as the writer
            // typed would move the verdict under their cursor.
            if verbs.contains(.requestChanges) {
                TextField(DesignGate.changeRequestPrompt, text: $words,
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .font(.callout)
            }
            if !verbs.isEmpty { controls }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **The verbs, trailing.** Approve leads visually because it is what a
    /// pending round is for; every one of them carries an accessibility label of
    /// its own, since the words "Revert" and "Approve" are told apart from the
    /// rest of the window only by the surface they sit on, which a linear tree
    /// does not carry.
    ///
    /// **No `keyboardShortcut`**, for the desk's reason: ⌘R and ⌘⇧R belong to the
    /// compiler in whichever window hosts this, and a return-key default over a
    /// control that ships a book's templates is a keystroke nobody meant.
    private var controls: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(verbs, id: \.self) { verb in
                Button(verb.title) { perform(verb) }
                    .controlSize(.small)
                    .disabled(working)
                    .accessibilityLabel(verb.accessibilityLabel)
                    .help(verb.help)
            }
        }
    }

    /// **One press, one sentence** — whichever way it goes (Global Constraint
    /// 2/4).
    ///
    /// Request Changes is handled apart from the other three because it is a
    /// different kind of act: it starts a round rather than moving a byte of the
    /// publish tree, it is synchronous, and it consumes the writer's words —
    /// which are cleared only when they were spent, `DepartmentPane`'s rule for
    /// the desk's own field.
    ///
    /// **And Finalize is handled apart from the other two**: it is the one act
    /// here with no way back, so the press mints a confirmation and stops. What
    /// actually runs a verb is `run`, reached either straight from here or from
    /// the writer's yes.
    private func perform(_ verb: DesignGate.Verb) {
        notice = nil
        guard verb != .requestChanges else {
            if let refusal = actions.requestChanges(words) {
                notice = refusal
            } else {
                words = ""
                notice = DesignGate.changesSentConfirmation
            }
            return
        }
        // **Finalize stops here until the writer says yes** — the press mints
        // the confirmation and reaches no action. Everything else acts on the
        // press; `DesignGate.confirmation` is the one place that is decided.
        if let confirmation = DesignGate.confirmation(
            for: verb,
            perform: { confirmed(verb) },
            cancel: { cancelConfirmation() }) {
            pendingConfirmation = confirmation
            onConfirmationChanged(confirmation)
            return
        }
        run(verb)
    }

    /// The writer said yes: the dialog goes, then the verb runs.
    private func confirmed(_ verb: DesignGate.Verb) {
        pendingConfirmation = nil
        onConfirmationChanged(nil)
        run(verb)
    }

    /// …and the two ways of saying no, which do the same thing: nothing.
    /// Idempotent, because the buttons' own actions and the dialog's dismissal
    /// both arrive.
    private func cancelConfirmation() {
        guard pendingConfirmation != nil else { return }
        pendingConfirmation = nil
        onConfirmationChanged(nil)
    }

    /// One of the three verbs that moves the publish tree, run for real.
    private func run(_ verb: DesignGate.Verb) {
        working = true
        Task { @MainActor in
            let outcome: DesignGateOutcome
            switch verb {
            case .approve: outcome = await actions.approve(proposal)
            case .revert: outcome = await actions.revert(proposal)
            case .finalize: outcome = await actions.finalize(proposal)
            case .requestChanges: return   // answered above
            }
            working = false
            switch outcome {
            case .done(let updated, let sentence):
                notice = sentence
                // **The write-back**, and the reason this view holds no copy of
                // the proposal: the status the verb produced lives on disk, and
                // the window's own value is what every surface here reads.
                onProposalChanged(updated)
            case .refused(let sentence):
                notice = sentence
            }
        }
    }

    /// **The edition caveat, above everything.** It changes what approving this
    /// proposal MEANS, so it is read before the spec rather than filed under the
    /// pages it is about.
    private func editionCaveat(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "character.book.closed")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    /// A banner rather than a `ContentUnavailableView`: two of the three arms
    /// carry a body (the diagnostics scroller), and all three want to sit at the
    /// TOP of the column beside the rail they explain rather than centred in it.
    private func notice<Body: View>(
        symbol: String, tint: Color, headline: String, detail: String,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.callout.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            body()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func section<Content: View>(
        _ heading: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The path the proposal RECORDED, which is the `.task`'s key: it moves when
    /// the writer Shows a different round, and it is `nil` for a proposal with no
    /// pages to look for.
    private var recordedPagesPath: String? {
        guard case .pages(let path, _) = proposal.sampleResult else { return nil }
        return path
    }

    private func checkPages() async {
        guard let path = recordedPagesPath else {
            pagesExist = true       // nothing to look for; the panel is `.notSampled`
            return
        }
        let url = DesignGate.pagesURL(path, in: projectURL)
        pagesExist = FileManager.default.fileExists(atPath: url.path)
    }
}

