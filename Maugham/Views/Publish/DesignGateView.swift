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
/// **No verbs.** Approve / Request Changes / Revert / Finalize are Task 6's. The
/// one control here is the way back to the book, which is navigation rather than
/// a verdict.
struct DesignGateView: View {
    let proposal: DesignProposalStore.Proposal
    let projectURL: URL
    var onClose: () -> Void = { }

    /// Whether the recorded pages are still on disk. Starts `true` so the first
    /// frame draws them — see `DesignGate.panel`'s doc for why that direction.
    @State private var pagesExist = true

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        // Asked here, never on a body path, and re-asked when the path moves —
        // which it does when the writer Shows a different round.
        .task(id: recordedPagesPath) { await checkPages() }
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
