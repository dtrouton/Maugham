import SwiftUI
import MaughamCore

/// What Claude has read off the manuscript — the third stratum of the Intent
/// pane, and the only one that is not the writer's (spec §3.3).
///
/// **Provisional in three channels, because two of them are unavailable to
/// somebody.** The paper is the canvas's Claude tint
/// (`CanvasRenderer.claudeCardPaper`, from `CanvasMaterial.lightClaudeCardPaper`
/// / `darkClaudeCardPaper` — cooler and slightly darker than the writer's), the
/// ink is `.secondary` rather than the writer-ink the rulings above are set in,
/// and `accessibilityLabel` speaks `CanvasAccessibility.claudeTerm` because a
/// colour is inaudible. Those are the canvas's values and its reasoning, cited
/// rather than re-derived: a second answer to "what does Claude's work look
/// like" is two surfaces that can drift about the one signal the writer is meant
/// to be able to trust at a glance.
///
/// **Nothing here writes into the writer's layer.** The three actions are
/// `bless`, `correct` and `dismiss`; the first two graduate an entry by calling
/// `RulingPerformer.rule` with a **`String`** — the sentence the writer has just
/// approved or amended — and never with the `BibleFact` itself. That is the
/// membrane (§3.4) and it is why `RulingPerformer` has no `bless(fact:)`: the
/// writer's press is the thing in between, and it has to be expressible on the
/// wire as their words.
///
/// **No empty state.** A piece with no facts shows no stratum, no header and no
/// "nothing yet" — the same rule the whole pane is built on (M1A: absence is
/// valid and is never a nag).
@MainActor
enum BibleStratum {

    // MARK: - Reading

    /// Which statements have a bible under them at all.
    ///
    /// **The craft intent, and nothing else** (publish department, Task 7). A
    /// bible entry is a reading of what the MANUSCRIPT establishes, offered
    /// against the intent the writer declared for it; no other statement is
    /// about the manuscript's facts. Visual language is about how the book
    /// looks, an edition brief about how it reads in another language, and an
    /// `.unknown` kind is a newer build's — retained and ignored everywhere else
    /// (`Statement.Kind`), so ignored here too.
    ///
    /// **This is the bible's own question, and that is the whole point of it.**
    /// `StatementPane.bibleFacts` used to gate on `StatementEssay.carriesRulings`
    /// — a question about the FILE (does a `## Rulings` section live in it) read
    /// as a question about the SUBJECT (is this the craft intent). The two agree
    /// for exactly as long as intent is the only kind with strata, which is why
    /// the proxy survived a milestone and why `carriesRulings`' own doc comment
    /// records it as a trap rather than a defect. The edition brief is the case
    /// where they part: it carries rulings by construction and establishes
    /// nothing about Kelly, so the proxy would have put the project's whole
    /// bible under a brief about Spanish register.
    /// (`StatementPaneStrataTests.test_aBriefRefusesTheBibleEvenWithAStore
    /// ThreadedThroughIt` pins the predicate rather than the fact that Task 2's
    /// door happens to pass no bible.)
    static func belongsTo(_ kind: Statement.Kind) -> Bool {
        switch kind {
        case .intent: return true
        // The lessons ledger is about the WRITER, not about the book's world —
        // the bible establishes what is true of Kelly, and nothing in a lesson
        // about the writer's own habits belongs under it.
        case .visualLanguage, .editionBrief, .lessons, .unknown: return false
        }
    }

    /// The facts this scope's pane shows.
    ///
    /// A document scope shows that document's; the project row shows the book's
    /// whole ledger. `BibleStore.allFacts`' own doc draws that line ("the Bible
    /// pane shows one piece's facts; a project-wide view shows all of them") and
    /// the store deliberately does not pre-filter, so the slice is decided here,
    /// once, as a pure function over the product of its inputs.
    ///
    /// An `.unknown` scope — a newer build's — shows nothing rather than
    /// everything: it names something this build cannot resolve, and answering
    /// with the project's ledger would be a guess.
    static func facts(for scope: Statement.Scope, in all: [BibleFact]) -> [BibleFact] {
        switch scope {
        case .project:
            return all.sorted { $0.recordedAt < $1.recordedAt }
        case .document(let docId):
            return all.filter { $0.docId == docId }
                .sorted { $0.recordedAt < $1.recordedAt }
        case .unknown:
            return []
        }
    }

    /// The line under a fact: who it is about, and — in the paragraph's own
    /// words — where it was read.
    ///
    /// **Never a ¶id** (requirement 3: "no bare ¶ids anywhere the writer
    /// reads… paragraphs are referred to by short QUOTE, the way an editor
    /// would"). `BibleFact.establishedAt` is the payload a jump would need and
    /// `BibleFact.excerpt` is what a writer can actually recognise, so the
    /// caption reads the second and never the first. A fact with no excerpt —
    /// one the run could not anchor, or a row written by a build before the
    /// field existed — is captioned by its subject alone. Falling back to the
    /// id would put the token in front of the writer in exactly the case they
    /// have least context to decode it.
    static func caption(for fact: BibleFact) -> String {
        guard let excerpt = fact.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !excerpt.isEmpty
        else { return fact.subject }
        return "\(fact.subject) · \u{201C}\(excerpt)\u{201D}"
    }

    /// What VoiceOver says, and the one channel that carries the provenance for
    /// a listener. `CanvasAccessibility.claudeTerm` is the same phrase the
    /// canvas speaks on all three of its primitives — one term across the
    /// product, not a second wording a listener has to keep apart from it
    /// (Denver, 2026-07-30).
    static func accessibilityLabel(for fact: BibleFact) -> String {
        "\(fact.fact) — \(caption(for: fact)), \(CanvasAccessibility.claudeTerm)"
    }

    /// The provisional register's paper. **The canvas's value, not a copy of
    /// its numbers** — `CanvasRenderer.claudeCardPaper` resolves per appearance
    /// from `CanvasMaterial`'s light/dark pair, and asking for it here is what
    /// keeps the two surfaces saying the same thing in the same colour.
    static var paper: NSColor { CanvasRenderer.claudeCardPaper }

    /// What a blessed line says about where it came from. The DATE is not in
    /// this string and must not be: `RulingPerformer.rule` stamps the day it was
    /// made and `RulingsSection` renders it as `— ruled <d MMM yyyy>,
    /// <provenance>`, so the rendered line already reads *"— ruled 7 Aug 2026,
    /// blessed from the bible"*. Spelling a second date into the provenance
    /// would print it twice and give the record two answers that can disagree.
    static let blessedProvenance = "blessed from the bible"

    /// The same, for a fact the writer amended before accepting it. A separate
    /// sentence rather than a flag on the first, because the two are different
    /// claims about the record: one says Claude read it right, the other says
    /// the writer fixed it.
    static let correctedProvenance = "corrected from the bible"

    // MARK: - The three actions

    /// **Bless**: the fact graduates into the writer's layer as a ruling, and
    /// leaves the provisional register in the same act.
    ///
    /// **The order is the contract, and it is `DiagnosticsPane.answer`'s.**
    /// Dismissed first, a refusal would cost the writer both the ruling and the
    /// reading, with nothing left on screen to press again; dismissed after, the
    /// worst case is a fact they bless twice.
    /// (`test_aRefusedBlessLeavesTheFactInTheRegister`.)
    static func bless(_ fact: BibleFact, forScope scope: Statement.Scope,
                      store: ProjectStore, bible: BibleStore,
                      world: DeclaredWorldStore?) async {
        await graduate(fact.fact, provenance: blessedProvenance, fact: fact,
                       forScope: scope, store: store, bible: bible, world: world)
    }

    /// **Correct**: the same graduation, in the writer's own words. What crosses
    /// the membrane is `amended` — a `String` they typed — so this is the writer
    /// ruling, not Claude's reading promoting itself.
    static func correct(_ fact: BibleFact, to amended: String,
                        forScope scope: Statement.Scope, store: ProjectStore,
                        bible: BibleStore, world: DeclaredWorldStore?) async {
        await graduate(amended, provenance: correctedProvenance, fact: fact,
                       forScope: scope, store: store, bible: bible, world: world)
    }

    /// **Dismiss**: the writer says this is not so. Nothing enters their layer.
    ///
    /// **Not undoable, and that is intended rather than missing** — the
    /// reasoning is `DiagnosticsPane.promote`'s, verbatim in shape: the bible is
    /// per-device derived state with no undo of its own, and a fact the
    /// manuscript still establishes is recorded again by the next run
    /// (`BibleStore.record`'s doc says so). A ⌘Z that resurrected it would be
    /// claiming the compiler had re-read something it has not looked at since.
    static func dismiss(_ fact: BibleFact, bible: BibleStore) {
        bible.dismiss(fact.id)
    }

    /// The half `bless` and `correct` share: write the writer's sentence as a
    /// ruling, mark what has graduated, and only then take the reading off the
    /// pane.
    ///
    /// **The ruling comes first because a refusal must leave the writer
    /// something to press again** — `bless`'s own contract, one step earlier:
    /// nothing is marked and nothing is dismissed unless `rule` succeeded.
    /// After that there is no race to guard (both calls are synchronous on the
    /// main actor with nothing between them); marking before dismissing is
    /// coherence — the register is never briefly missing a fact whose
    /// graduation has not been recorded.
    ///
    /// **TWO keys, and a correction is why.** `fact.fact` is Claude's reading,
    /// which the next run re-emits from the same prose. `words` is what the
    /// writer ruled — identical to the reading for a bless, their own sentence
    /// for a correction — and the manuscript can establish that too, at which
    /// point a run would offer them back the decision they already made and a
    /// second press would mint a duplicate ruling row. Both are declared now;
    /// a candidate matching either is not news (`BibleStore.markGraduated`).
    /// For a bless the two calls are one key and the second is a no-op.
    ///
    /// A refusal is swallowed here rather than surfaced, on the pane's own
    /// terms: `RulingPerformer`'s refusals are all structural (a scope naming no
    /// document, a statement whose bytes will not decode) and the fact staying
    /// put IS the visible answer — the writer presses again, or opens the piece.
    /// A sentence would want a place to live, and the pane's own place for one
    /// is Stage 2's.
    private static func graduate(_ words: String, provenance: String, fact: BibleFact,
                                 forScope scope: Statement.Scope, store: ProjectStore,
                                 bible: BibleStore, world: DeclaredWorldStore?) async {
        do {
            try await RulingPerformer.rule(
                words, provenance: provenance, kind: .intent, forScope: scope,
                store: store, world: world)
        } catch {
            return
        }
        bible.markGraduated(subject: fact.subject, fact: fact.fact)
        bible.markGraduated(subject: fact.subject, fact: words)
        bible.dismiss(fact.id)
    }
}

/// The bible stratum as the writer meets it — Claude's readings, on Claude's
/// paper, under the writer's own two strata.
struct BibleStratumView: View {
    let facts: [BibleFact]
    let scope: Statement.Scope
    @Bindable var store: ProjectStore
    let bible: BibleStore
    let world: DeclaredWorldStore?

    /// Which row's correction field is open, by fact id. A `BibleFact.id` is a
    /// ULID the store minted and does not move with its text, so it is a stable
    /// handle here — unlike a `Ruling`'s, which is why the stratum above keys on
    /// position instead.
    @State private var correctingId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What Claude has read")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            ForEach(facts) { fact in
                row(fact)
                Divider()
            }
        }
        .background(Color(nsColor: BibleStratum.paper))
    }

    @ViewBuilder
    private func row(_ fact: BibleFact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if correctingId == fact.id {
                StratumEditField(
                    seed: fact.fact,
                    isOpen: Binding(get: { correctingId == fact.id },
                                    set: { if !$0 { correctingId = nil } }),
                    onCommit: { text in
                        correctingId = nil
                        commitCorrection(text, to: fact)
                    })
            } else {
                Text(fact.fact)
                    .font(.callout)
                    // Dimmer than the writer's own ink, deliberately: nothing
                    // here is theirs yet.
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(BibleStratum.caption(for: fact))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                Button("Bless") { bless(fact) }
                    .buttonStyle(.plain)
                Button("Correct") { correctingId = fact.id }
                    .buttonStyle(.plain)
                Button("Dismiss") { BibleStratum.dismiss(fact, bible: bible) }
                    .buttonStyle(.plain)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BibleStratum.accessibilityLabel(for: fact))
    }

    private func bless(_ fact: BibleFact) {
        Task { @MainActor in
            await BibleStratum.bless(fact, forScope: scope, store: store,
                                     bible: bible, world: world)
        }
    }

    private func commitCorrection(_ text: String, to fact: BibleFact) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
            await BibleStratum.correct(fact, to: trimmed, forScope: scope,
                                       store: store, bible: bible, world: world)
        }
    }
}
