import SwiftUI
import AppKit
import MaughamCore
import os

private let _departmentLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "Department")

/// **Where the desk's values come from, and where its one door leads**
/// (publish-department P4 Task 2).
///
/// `DepartmentPane` takes values and holds no store (its own census says so),
/// and the values it takes are expensive: the language union walks every
/// manuscript document's translation store, reads each one's open annotations,
/// and derives coverage against the current paragraph state. None of that may
/// happen on a `body` path (tripwire 4), so it happens here in a `.task` and
/// arrives as a plain array — `ReferencesPaneHost`'s shape, for
/// `ReferencesPaneHost`'s reason.
///
/// **It is also where the brief's door goes**, because the door writes: it
/// creates the statement the writer is about to type in and then presents an
/// editor over the desk. A pane that could do either would be a pane holding a
/// store.
struct DepartmentPaneHost: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let projectURL: URL
    /// **What the window's tree is naming** — the input Global Constraint 1 turns
    /// into a run target (Task 3). The desk sums the whole book, but a round is
    /// one chapter's, and this is the only thing on the pane that says which.
    var subject: BinderSubject? = nil
    /// The window's translator (P2), owned by `ProjectWindow` beside the compiler
    /// and reached here the way `DiagnosticsPane` reaches the compiler: passed as
    /// a value, never constructed. Optional so a caller that surfaces no run — the
    /// probe mounts — offers a desk that reads and does not act.
    var translator: TranslatorOrchestrator? = nil
    /// The window's record of finished rounds. Window-scoped rather than held here
    /// because `onRunEnded` is wired when the stores are configured, long before
    /// anybody opens this pane — see `TranslationRunLog`.
    var runLog: TranslationRunLog? = nil

    @State private var languages: [EditionStatus.LanguageRow] = []
    /// The edition whose brief is on screen, or nil for the desk itself.
    @State private var openBrief: OpenedBrief?
    /// A door that would not open. Cleared on the next attempt.
    @State private var notice: String?
    /// This pane's hosting window, for the ADR 0021 receive helpers' liveness
    /// guard — resolved through `WindowAccessor` because a cached `nil` is not
    /// a close check (`MaughamEvent.isLive`).
    @State private var window: NSWindow?
    /// Bumped by the events below so the derivation re-runs. A counter rather
    /// than a direct `await`: `.task(id:)` owns cancellation, and a re-derive
    /// kicked off from a notification closure would not be cancelled when the
    /// writer leaves the pane mid-walk.
    @State private var refreshes = 0

    /// What `openBrief(language:in:)` answered: the edition, and the statement
    /// the door found or made for it.
    struct OpenedBrief: Equatable, Identifiable {
        let language: String
        let statementID: String

        var id: String { statementID }
    }

    /// **Three signals, and the `.task`'s own mount is a fourth.** The desk's
    /// figures move when a translation is written (a run, or `write_translation`
    /// from outside), when a query is opened or disposed of, and when the
    /// manifest changes (a translator renamed, a chapter added or removed).
    /// Read as an `Equatable` value so `.task(id:)` re-runs on a change and on
    /// nothing else.
    private struct ReloadKey: Equatable {
        let manifestModified: Date
        let refreshes: Int
    }

    private var reloadKey: ReloadKey {
        ReloadKey(manifestModified: store.manifest.modified, refreshes: refreshes)
    }

    var body: some View {
        Group {
            if let openBrief {
                brief(openBrief)
            } else {
                desk
            }
        }
        .background(WindowAccessor(window: $window))
        // `.project`-scoped, both of them: a window on another book must not
        // re-walk its own manuscripts because this one gained a translation,
        // and a closed window must walk nothing at all (tripwire 21).
        .onProjectEvent(.maughamTranslationDidUpdate, url: projectURL, window: window) { _ in
            refreshes += 1
        }
        .onProjectEvent(.maughamAnnotationsChanged, url: projectURL, window: window) { _ in
            refreshes += 1
        }
    }

    private var desk: some View {
        DepartmentPane(
            title: store.manifest.title,
            languages: languages,
            // Task 4's: the staged proposals are the other half of the desk.
            designProposalCount: 0,
            openEditionBrief: { language in
                Task { await present(language: language) }
            },
            notice: notice,
            runTarget: runTarget,
            runs: runStates,
            runTranslation: { run(language: $0) },
            // One session per window, so the row that is running is the only row
            // that offers this and there is never a question of whose round it
            // ends.
            cancelRun: { translator?.cancel() })
        .task(id: reloadKey) { await derive() }
    }

    // MARK: - The run (Task 3)

    /// **Which chapter a Run would translate**, from the window's own subject.
    ///
    /// Read on the body path on purpose and cheaply: a `TreeWalk.find` over the
    /// manifest and one dictionary lookup in the open-document registry. Both are
    /// observed (`ProjectStore` and `DocumentStore` are `@Observable`), which is
    /// what makes the button follow the tree — the writer clicks a chapter in the
    /// left column and the desk's Run becomes pressable with no event and no poll.
    private var runTarget: DepartmentRunTarget {
        DepartmentRunTarget.resolve(
            subject: subject,
            structure: store.manifest.structure,
            isOpen: { documentStore.document(for: $0) != nil })
    }

    /// One resolved run state per row. A pure fold over values the window already
    /// holds — no I/O, so a book with twenty editions costs twenty comparisons.
    private var runStates: [String: DepartmentRunState] {
        let target = runTarget
        let runState = translator?.runState ?? .idle
        let session = DepartmentRunSession.read(
            runState: runState, isRunning: translator?.isRunning ?? false)
        var states: [String: DepartmentRunState] = [:]
        for row in languages {
            states[row.language] = DepartmentRunState.resolve(
                language: row.language, target: target, session: session,
                runState: runState,
                lastRun: target.docId.flatMap {
                    runLog?.run(docId: $0, language: row.language)
                })
        }
        return states
    }

    /// **The click, and everything that can refuse it in words** (Global
    /// Constraint 2).
    ///
    /// The pre-flight is `DepartmentRunState.preflight`'s, so what the disabled
    /// button says and what a click that beat the disable is told are the same
    /// sentence resolved once. Past it the orchestrator's own `!isRunning` guard
    /// and its briefing gather are the only refusals left, and neither can be
    /// reached from here without one of the answers above having been given first.
    private func run(language: String) {
        notice = nil
        guard let translator else {
            notice = Self.noTranslatorWired
            return
        }
        let session = DepartmentRunSession.read(
            runState: translator.runState, isRunning: translator.isRunning)
        if let refusal = DepartmentRunState.preflight(
            language: language, target: runTarget, session: session) {
            notice = refusal
            return
        }
        guard let docId = runTarget.docId else { return }
        translator.runTranslation(docId: docId, language: language)
    }

    /// A desk mounted with no orchestrator behind it — the probe mounts, and a
    /// window whose stores never finished loading. Saying so is better than a
    /// button that silently does nothing, which is the whole of Constraint 2.
    static let noTranslatorWired =
        "This window isn\u{2019}t ready to run a translation yet. Try again in a "
        + "moment, or reopen the project."

    /// The brief itself, over the desk rather than beside it.
    ///
    /// **`StatementPane`, exactly as `⌘⌥N` and `⌘⌥V` present a statement** — the
    /// same editor host, the same op-logged `Document`, and the same rulings
    /// stratum beneath it, which is where a translator's answered query hardens
    /// into a dated ruling (spec §4). A second editor of this pane's own would
    /// be a second answer to how a statement is edited.
    ///
    /// `subject: .project` is stated rather than left nil: an edition brief is
    /// project-scope by construction (`StatementConvention.newPath` has no row
    /// for `(.editionBrief, .document)`), and saying so here means the pane is
    /// not relying on `effectiveScope`'s coercion to reach the right file.
    private func brief(_ open: OpenedBrief) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    openBrief = nil
                } label: {
                    Label("Department", systemImage: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .help("Back to the department desk")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            StatementPane(
                store: store, documentStore: documentStore,
                kind: .editionBrief(open.language),
                subject: .project)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func derive() async {
        do {
            languages = try await EditionStatus.languageRows(
                in: store, projectURL: projectURL)
        } catch {
            // The walk reads; it cannot damage anything by failing. The desk
            // keeps whatever it last derived rather than blanking the rows the
            // writer is reading, and says nothing — the notice line is for a
            // refusal the writer ASKED for.
            _departmentLog.error(
                "could not derive the department's language rows: \(error, privacy: .public)")
        }
    }

    private func present(language: String) async {
        notice = nil
        guard let opened = await Self.openBrief(language: language, in: store) else {
            notice = Self.briefRefusal(language: language)
            return
        }
        openBrief = opened
    }

    /// **The door.** Find-or-create, then present.
    ///
    /// Creating on the click is the right moment: the writer clicked because
    /// they are about to write register and idiom policy into it, and a brief
    /// that mints on the first keystroke instead (`StatementEditorHost`'s own
    /// route for a statement that does not exist) is the same file one moment
    /// later — but the desk would have nothing to name in the meantime.
    ///
    /// **Once, ever.** `createStatement` is find-or-create and idempotent, so
    /// the second click finds what the first made; a door that minted per click
    /// would leave a second empty `edition-brief-es-2.md` beside the writer's
    /// own, because `vacantStatementPath` steers a new mint around an occupied
    /// path — and the next visit would open the empty one.
    ///
    /// Static and free of view state so the rule is drivable without mounting
    /// anything (`DepartmentPaneTests`).
    @MainActor
    static func openBrief(language: String, in store: ProjectStore) async -> OpenedBrief? {
        do {
            let statement = try await store.createStatement(
                kind: .editionBrief(language), scope: .project)
            return OpenedBrief(language: language, statementID: statement.id)
        } catch {
            _departmentLog.error(
                "could not open the \(language, privacy: .public) edition brief: \(error, privacy: .public)")
            return nil
        }
    }

    /// What the desk says when the door would not open. It names the edition,
    /// because a writer with three of them needs to know which one refused.
    static func briefRefusal(language: String) -> String {
        "Couldn’t open the "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + " edition brief. Check that the project folder is still where it was."
    }
}
