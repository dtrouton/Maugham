import SwiftUI
import MaughamCore

/// **Keep this letter** (editorial letter P1 Task 10, spec §3.6).
///
/// A letter is derived. It rides its `CompilerRun`, and a run ages out of the
/// document's rounds ring behind five later checks; nothing else in the app
/// makes one durable. Keep is the writer's own hand on that — the same shape
/// as *Add to intent* beside it and *Answer as ruling* one pane over: Maugham
/// notices, offers, and writes only when asked.
///
/// **A copy, not a move.** The run's own letter is untouched, so the section
/// stays on screen and a second Keep is a second note. There is deliberately
/// no dedupe: a writer who kept a letter, edited the note into something else
/// and wants the original back is entitled to it, and the store's own
/// sibling-title dedupe is what keeps the two apart on disk.
///
/// **Where it lands is the router's decision, never this file's**
/// (`ResearchScope.route`, spec §6.2). Keep names the scope — the piece the
/// letter is about — and the project type decides containment (a loose
/// collection piece's own folder), shared plus a link (a novel chapter) or
/// shared alone (a short story or screenplay). A `switch manifest.type` here
/// would be a second copy of that table, and a copy is how the two drift.
///
/// **The body is written before anything reports success** (RULING-7, and the
/// two-step every caller of `createResearchNote` keeps —
/// `InboxStore.promote`'s own note names the defect it was fixed from). A
/// failed write throws, the host shows its refusal, and no confirmation is
/// drawn over a note that has no letter in it.
@MainActor
enum LetterKeep {

    /// What a host remembers about a keep: which run's letter went, and what
    /// the store finally called it. Keyed by run id rather than a bare `Bool`
    /// because the next round replaces the letter on screen, and a line still
    /// naming the previous round's note would point at a note about different
    /// prose.
    struct Kept: Equatable {
        let runId: String
        let title: String
    }

    /// The sentence under the button, in the writer's register.
    static func confirmation(_ title: String) -> String {
        "Kept as \u{201C}\(title)\u{201D}"
    }

    /// The confirmation for THIS run, or `nil` — the shape both hosts pass
    /// straight into `LetterSection.keepConfirmation`, so neither has to spell
    /// the run comparison itself.
    static func confirmation(for kept: Kept?, run: CompilerRun?) -> String? {
        guard let kept, let run, kept.runId == run.id else { return nil }
        return confirmation(kept.title)
    }

    /// **The lane, in the words the cockpit already uses.** A stage answers
    /// `laneLine`; the coach answers `coachLine`, because her pass name
    /// ("Workshop") names no column, no ladder row and nothing in the guide —
    /// the same split `ReviewRoundCockpit.laneLabel` makes on screen.
    ///
    /// A passless run has no lane at all, and the empty string is what stops
    /// the rendered heading inventing one.
    static func laneLine(for run: CompilerRun, store: ProjectStore) -> String {
        guard let passId = run.passId,
              let pass = ReviewPass.pass(
                id: passId, in: store.manifest.effectiveReviewPasses)
        else { return "" }
        return pass.id == ReviewPass.coachPreset.id
            ? ReviewRoundCockpit.coachLine(coach: pass, round: run.round)
            : ReviewRoundCockpit.laneLine(pass: pass, round: run.round)
    }

    /// File the letter as a research note. Returns the item the store made, so
    /// the caller can name it in its confirmation — the store resolves the
    /// title against its siblings, and a caller echoing back the title it
    /// ASKED for would name a note that is not there.
    /// **`write` is a seam, and it exists because the ordering could not
    /// otherwise be tested** (fix round 1, Important 1). Both writes land in
    /// the same folder, so an unwritable destination refuses at the STORE's
    /// empty-file write and this function's own `try` is never reached — which
    /// is exactly how a `try` quietly turning into a `try?` passed a full gate.
    /// Production passes nothing; the test injects a thrower.
    @discardableResult
    static func keep(
        _ letter: Letter, run: CompilerRun, docId: String,
        editorName: String, store: ProjectStore,
        write: (String, URL) throws -> Void = LetterKeep.atomicWrite
    ) async throws -> ResearchItem {
        let rendered = LetterMarkdown.render(
            letter, editorName: editorName,
            laneLine: laneLine(for: run, store: store), at: run.at)
        let created = try await store.createResearchNote(
            scope: .document(docId), title: rendered.title)
        guard let path = created.path else {
            throw ProjectStoreError.fileSystemError(
                "The kept letter's note has no file to write to: \(created.id)")
        }
        // `try`, not `try?`: a failed body write used to leave an EMPTY note
        // reported as a successful promotion on this store's other callers
        // (`InboxStore.promote`, M8-IN-001/002). Falsified by
        // `LetterKeepTests.test_aRefusedBodyWriteRefusesTheWholeKeep`.
        try write(rendered.body, store.url.appendingPathComponent(path))
        return created
    }

    /// The real write. Atomic, so a crash mid-write cannot leave a half-letter
    /// where a whole one is claimed.
    /// `nonisolated` because it touches nothing actor-bound and because the
    /// isolation would otherwise ride into the parameter's function type,
    /// which Swift 6 rejects at every call site that passes it as a value.
    nonisolated static func atomicWrite(_ text: String, _ url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The whole verb, as the closure `LetterSection.onKeep` takes —
    /// `TurnClauseOffer.handler`'s twin, and for the same reason: two hosts
    /// draw the letter and a second spelling is two answers waiting to
    /// disagree.
    ///
    /// `onFailure(nil)` is sent first, so a second attempt does not read under
    /// the first one's refusal. A host with no project has nowhere to file,
    /// and says so rather than pressing into nowhere — `LetterSection` draws
    /// the button unconditionally, so silence here would be a control that
    /// looks pressed and a note that never happened.
    static func handler(
        letter: Letter, run: CompilerRun?, docId: String,
        store: ProjectStore?, editorName: String,
        write: @escaping (String, URL) throws -> Void = LetterKeep.atomicWrite,
        onKept: @escaping (Kept) -> Void,
        onFailure: @escaping (String?) -> Void
    ) -> () -> Void {
        return {
            onFailure(nil)
            guard let run, let store else {
                onFailure(noProjectRefusal)
                return
            }
            Task {
                do {
                    let item = try await keep(
                        letter, run: run, docId: docId,
                        editorName: editorName, store: store, write: write)
                    onKept(Kept(runId: run.id, title: item.title))
                } catch {
                    documentLog.error("\u{201C}Keep this letter\u{201D} refused for \(docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    onFailure(error.localizedDescription)
                }
            }
        }
    }

    /// What a keep with no project to file into says. Named rather than
    /// inlined so the test asserts the words the writer reads.
    static let noProjectRefusal = "There is no project open to keep this letter in."
}
