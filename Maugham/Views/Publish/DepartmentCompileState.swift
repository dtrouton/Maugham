import Foundation

/// **What the desk's Compile button has to say for itself**, as decisions
/// rather than as a view (imprints P3 Task 4).
///
/// `DepartmentRunState`'s shape, one verb over: everything the surface draws
/// about a compile — whether one is in flight, what it is compiling, what the
/// last one produced and why a press was refused — is a value here, so
/// `DeskCompileRunner` holds one field and the pane goes on taking values.
///
/// **Every phase carries its own words.** A compile that refuses in silence is
/// the dead control RULING-35 is about, and this surface has three ways to
/// produce nothing: a second press while one is running, an imprint name the
/// config does not define, and a cancel. None of them is a failure and none of
/// them may be drawn as one.
struct DepartmentCompileState: Equatable {

    /// **What the last press did.**
    ///
    /// `.refused` is a separate arm from `.failed` on purpose. The orchestrator
    /// answers an unknown imprint through the ordinary `.failed` shape — it is
    /// the same channel a broken template comes back on — but nothing went
    /// wrong with the book: a name was typed that this project does not define,
    /// nothing compiled, and the writer's next move is to fix the name rather
    /// than to read a log. A red line over the desk would send them looking for
    /// a fault that is not there.
    enum Phase: Equatable {
        case idle
        /// What is being compiled, known before the compile ends — so the desk
        /// says which book, which format and which editions rather than
        /// spinning.
        case running(format: PublishConfig.Format, languages: [String], imprint: String?)
        case completed(Publication)
        /// The failure's first diagnostic message, carried whole.
        case failed(String)
        /// The refusal's own sentence.
        case refused(String)
    }

    var phase: Phase = .idle

    /// **Whether a compile is in flight — STORED, not read off `phase`.**
    ///
    /// A refusal replaces the phase while the run it refused is still going, so
    /// a computed `isRunning` would read `false` in exactly the moment a second
    /// press has just been turned away: the desk would re-enable its own button
    /// mid-compile and the third press would find nothing to refuse it. The one
    /// question a surface asks about availability has one answer, and this is
    /// it.
    var isRunning: Bool = false

    /// What the last finished compile said, when the phase itself has nothing
    /// to say. `nil` before any. `DepartmentRunState.report`'s job: a cancel
    /// and a dry run both settle the desk back to `.idle`, and an idle desk
    /// that just swallowed a press without a word is indistinguishable from a
    /// button that did nothing.
    var report: String? = nil

    /// **The desk's one line**, in `DepartmentRunState`'s order: what is
    /// happening now outranks what happened last.
    var statusLine: String? {
        switch phase {
        case .running(let format, let languages, let imprint):
            return Self.compiling(format: format, languages: languages, imprint: imprint)
        case .completed(let publication):
            return Self.completedLine(publication)
        case .failed(let message):
            return message
        case .refused(let sentence):
            // **A refusal while the refused run carries on says both things.**
            // The phase is replaced by the refusal, so the running sentence is
            // gone by the time this is read — and a desk that answered the
            // bare refusal would be a desk with a Cancel button on it and not
            // one word about what there is to cancel. One channel, both facts.
            return isRunning ? Self.refusedWhileRunning(sentence) : sentence
        case .idle:
            return report
        }
    }

    /// **Whether the last press ended badly** — `.failed` and nothing else.
    ///
    /// `DepartmentRunState.isFailure`'s rule, in this surface's currency: a
    /// refusal is not a failure (nothing broke, a press arrived at the wrong
    /// moment or a name was mistyped) and a cancel is the writer's own act. A
    /// red line over either sends them looking for a fault that is not there.
    var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - Settling

    /// **Every `Outcome` the orchestrator can answer, as one state.**
    ///
    /// Pure, so the whole of what the desk draws when a compile ends is
    /// assertable from literals — and so the runner's `Task` has one line of
    /// judgment in it rather than a switch nobody can reach without compiling a
    /// book.
    static func settled(after outcome: CompileOrchestrator.Outcome) -> DepartmentCompileState {
        switch outcome {
        case .completed(let publication, _):
            return DepartmentCompileState(phase: .completed(publication), isRunning: false)

        case .failed(let errors, let logExcerpt):
            let message = errors.first?.message ?? Self.failedWithoutADiagnostic
            // The orchestrator's own marker, read rather than re-typed: an
            // unknown imprint refuses before a job registers and is a typo, not
            // a fault (`CompileOrchestrator.unknownImprintLogExcerpt`).
            if logExcerpt.hasPrefix(CompileOrchestrator.unknownImprintLogExcerpt) {
                return DepartmentCompileState(phase: .refused(message), isRunning: false)
            }
            return DepartmentCompileState(phase: .failed(message), isRunning: false)

        case .cancelled:
            return DepartmentCompileState(phase: .idle, isRunning: false,
                                          report: Self.cancelledLine)

        case .dryRunPassed:
            // The desk never asks for one — `DeskCompileRunner` passes
            // `dryRun: false` and has no control that could change it. The arm
            // exists because the switch is exhaustive, and it says the true
            // thing rather than pretending a book was made.
            return DepartmentCompileState(phase: .idle, isRunning: false,
                                          report: Self.dryRunLine)
        }
    }

    // MARK: - Copy

    static let compileTitle = "Compile"
    static let cancelTitle = "Cancel"

    /// **What a press while one is running is told.** Named for the desk's own
    /// currency — the writer is not waiting on a session here, they are waiting
    /// on a book.
    static let alreadyRunning =
        "A compile is already running. There is one press at a time \u{2014} this "
        + "one lands, then the next."

    /// A cancel is the writer's own act and is never drawn as a failure
    /// (`DepartmentRunState.cancelledLine`'s rule, in this surface's currency).
    /// It names what did NOT happen, because a cancelled compile can leave an
    /// artifact half-written and the writer needs to know it did not.
    static let cancelledLine = "Compile cancelled. Nothing was published."

    static let dryRunLine = "Dry run passed. Nothing was compiled."

    /// A refusal drawn while the run it was refused for is still going. The
    /// suffix is a constant rather than a rebuild of `compiling(...)` because
    /// the phase no longer carries what that run was for — saying THAT
    /// something is compiling is true; naming it from a phase that no longer
    /// holds it would not be.
    static func refusedWhileRunning(_ sentence: String) -> String {
        sentence + " \u{2014} still compiling."
    }

    /// A failure that arrived with no diagnostics at all. Rare — the
    /// orchestrator's own refusals all carry one — but a red desk with an empty
    /// line would be worse than a vague sentence.
    static let failedWithoutADiagnostic =
        "The compile failed and said nothing about why. Check Exports and the "
        + "publish config."

    /// **What is being compiled**, while it is.
    ///
    /// The imprint is spelled when there is one, because "the book" and an
    /// imprint of it are different objects with different version counters and
    /// a writer who compiled the wrong one wants to see it here rather than in
    /// the filename afterwards.
    ///
    /// The parenthetical lists what the caller named. A source-only compile
    /// says the book's own language because the desk passes that tag; an empty
    /// list draws no parenthetical at all, since a compile whose editions
    /// nobody named has nothing honest to put in one.
    static func compiling(format: PublishConfig.Format,
                          languages: [String],
                          imprint: String?) -> String {
        let subject = imprint.map { "the \($0) imprint" } ?? "the book"
        let editions = languages.isEmpty
            ? ""
            : " (" + languages.joined(separator: " + ") + ")"
        return "Compiling \(subject) as \(format.rawValue.uppercased())"
            + editions + "\u{2026}"
    }

    /// **What landed**, and where to find it.
    ///
    /// Version, imprint, edition and when it was compiled — read off
    /// `PublishPreviewCentre.parts(for:)`, the one composition every surface
    /// that names a book draws from (Task 6), so this line can never disagree
    /// with the picker or the single-book header about the same publication.
    /// Absent parts are dropped rather than drawn empty: the plain book has no
    /// imprint and no language tag, and "Compiled v0.2 ·  ·  — in Exports" is
    /// how a value type leaks into copy.
    static func completedLine(_ publication: Publication) -> String {
        "Compiled " + PublishPreviewCentre.parts(for: publication).joined(separator: " \u{00B7} ")
            + " \u{2014} in Exports"
    }
}
