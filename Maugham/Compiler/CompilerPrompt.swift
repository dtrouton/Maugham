import CryptoKit
import Foundation
import MaughamCore

/// Assembles what a compiler run sends to the spawned Claude: the session's
/// one-time system preamble, and each run's message (delta + diffed-in
/// context + what the previous round raised + the output-shape instruction).
///
/// A pure function of its inputs — no I/O, no clock — so the prompt itself is
/// testable without a subprocess.
enum CompilerPrompt {

    /// The output contract: six line-delimited JSON objects, one per
    /// section, in fixed order (conformance, continuity, reader, facts,
    /// intent_drift, letter). `DiagnosticIngestTests` reference this SAME
    /// constant, so prompt and parser cannot drift apart in a rewording.
    ///
    /// **`letter` (editorial letter P1 Task 2) is last, and that is a
    /// streaming decision.** The first five are what a check found in the
    /// prose, entry by entry; the sixth is an editorial letter about the
    /// reading as a whole (spec §3.1). Asking for it last means the writer is
    /// reading line-level results while the letter is still being written —
    /// the tempo the guide already promises — and it is the one section whose
    /// parts are prose rather than findings, so it mints at most three
    /// `letterQuestion` notes and otherwise lands on `CompilerRun.letter`.
    ///
    /// **`intent_drift` (M3-P3 Task 4) is the odd one and deliberately so.**
    /// The first four are things found IN the prose and each entry carries a
    /// `refs` array; the fifth is a verdict on the reading as a whole and
    /// carries none, because a judgement about the draft anchored to one
    /// paragraph is a judgement about that paragraph. Its `note` is asked for
    /// and thrown away at ingest — see `DiagnosticIngest.parseIntentDrift`.
    /// It shares nothing with M2's `DriftDetector`, which is a clause-strain
    /// PATTERN across run records and keeps its own meaning.
    ///
    /// No severity field, no suggestion field anywhere in this string —
    /// the register is enforced structurally, not by asking nicely
    /// (`test_theSchemaHasNowhereForYouShould`). References travel ONLY in
    /// each entry's `refs` array; prose never carries a bare paragraph id
    /// (`test_theSchemaForbidsIdsInProse`) — the enforcement with teeth is
    /// Task 2's ingest-side scrub, this is the instruction half.
    static let sectionSchemaDescription: String = """
        Respond with six lines, each one JSON object, in this exact order \
        — conformance, then continuity, then reader, then facts, then \
        intent_drift, then letter. Nothing else: no prose before, between, \
        or after them, and no line skipped — a section with nothing to \
        report still gets its line, with an empty array, and intent_drift \
        always carries a verdict:
        {"section":"conformance","checks":[{"clause_quote":<string>,"status":\
        "holds"|"strains"|"silent","refs":[<paragraph id>...],"what_pulls":\
        <string or null>}]}
        {"section":"continuity","questions":[{"cites":<string>,"refs":\
        [<paragraph id>...],"question":<string>}]}
        {"section":"reader","reports":[{"kind":"dream_break"|"belief","refs":\
        [<paragraph id>...],"report":<string>}]}
        {"section":"facts","candidates":[{"subject":<string>,"fact":<string>,\
        "refs":[<paragraph id>...]}]}
        {"section":"intent_drift","verdict":"holds"|"drifted","note":<one \
        sentence, only when drifted>}
        {"section":"letter","answer":<string or null>,"about":<string>,\
        "one_thing":<string or null>,\
        "working":[{"refs":[<paragraph id>...],"what":<string>,"why":\
        <string>}],"habits":[{"name":<string>,"refs":[<paragraph id>...],\
        "cost":<string>,"lesson":<string or null>,"exercise":<string or \
        null>}],"questions":[{"refs":[<paragraph id>...],"habit":\
        <habit name or null>,"question":<string>}],"scenes":[{"refs":\
        [<paragraph id>...],"wants":<string>,"changes":<string>,"turn":\
        <string>,"charge":"+"|"-"|null}] or null,"retired":[<lesson \
        heading>...],"process":<string or null>}
        The fifth line answers one question about this reading as a whole: \
        has the draft drifted from the declared intent? Weigh the prose in \
        this run's delta against the intent declared above — holds when \
        the writing is still going where the writer said it was going, \
        drifted when it has moved away from what they declared. Judge the \
        draft, never the writer's decision to change their mind; if there \
        is no declared intent to measure against, the answer is holds. \
        Every reference to a paragraph travels in that entry's refs array, \
        copied exactly as the paragraph id appears above. Prose — \
        what_pulls, question, report, cites, fact, and every prose field of \
        the letter — never contains a paragraph id: refer to the prose \
        itself by a short quotation, the way an editor would. clause_quote and cites are the writer's own \
        words, quoted, not summarized. what_pulls names what pulls \
        against the clause and stops there — never a fix. Every \
        continuity entry ends as a question, never a verdict. The reader \
        section holds at most 3 entries — the sharpest three, not every \
        dream-break you noticed.
        \(formOnItsOwnTermsInstruction)
        \(readerBarInstruction)
        \(crossSectionDedupInstruction)
        \(driftStabilizerInstruction)
        \(letterInstruction)
        """

    /// **A form is judged by its own rules** (spec §5.2's second half).
    ///
    /// It shipped inside `readerBarInstruction` and did not belong there: a
    /// reader's report is only one of the four ways an unconventional form is
    /// mistaken for a mistake. The copyedit register is where it bites hardest
    /// — Gould's own brief carries the diegetic-error rule — and a continuity
    /// question about a machine's clipped tense is the same error one section
    /// over. Scoped to the reader section it read as a licence the other three
    /// did not have.
    ///
    /// First, and deliberately: it governs how everything below it is read.
    static let formOnItsOwnTermsInstruction = """
        Judge an unconventional form by the rules it sets for itself, not by \
        the ones it has chosen not to follow. This governs every section: an \
        apparent error may be the piece's own — a character's typo, a \
        machine's clipped register, a narrator who cannot spell — and where \
        it might be, ask rather than assert.
        """

    /// **The bar for a reader entry** (spec §5.2, spike-validated).
    ///
    /// The reader's report is the section most easily filled with something
    /// rather than nothing: every paragraph can be said to have cost a reader
    /// some belief. Left unstated, the model reads "at most 3" as a quota and
    /// finds three. What the writer wants is the report of a real break, and
    /// most checks have none — so the empty array has to be named as the
    /// ordinary answer rather than merely permitted by the schema.
    static let readerBarInstruction = """
        Most checks report nothing in the reader section, and an empty \
        reports array is the ordinary answer rather than a failure to \
        notice anything: raise an entry only where you can quote the words \
        that did it and the effect survives a second reading.
        """

    /// **One issue gets one entry** (spec §5.3) — the spike's single largest
    /// quality lever, because the same trouble is genuinely visible from all
    /// four sections and a model asked four questions answers all four. It
    /// collapsed a five-entry fan-out there, and the attention that freed
    /// found new questions that were really new.
    static let crossSectionDedupInstruction = """
        One issue gets one entry, in the section where it cuts sharpest. \
        Where the same trouble could be filed as a strain, a continuity \
        question and a reader's report, choose the one place it lands \
        hardest and say nothing about it in the other two — three views of \
        one problem read to the writer as three problems, and cost them the \
        attention a fourth, real finding needed.
        """

    /// **Drift judges direction, not success** (spec §5.4). Observed in the
    /// spike: the structural framing alone flipped the verdict, because a
    /// draft with a straining clause reads as a draft that has gone wrong —
    /// and going wrong is not the same as going somewhere else. The strain is
    /// conformance's finding and already has a section to live in; letting it
    /// move the verdict reports one thing twice and marks the writer's intent
    /// for a reason that has nothing to do with intent.
    static let driftStabilizerInstruction = """
        The drift verdict judges direction, not success. A clause that \
        strains is the conformance section's finding and must not move this \
        verdict: prose that is still going where the writer said it was \
        going holds, however imperfectly it gets there, and only a draft \
        that has moved away from what was declared has drifted.
        """

    /// **What a letter is for** (spec §3.1/§3.3, and §4.4's "writer's own
    /// bar") — the general instruction, which rides every run whatever voice
    /// is reading.
    ///
    /// It is general on purpose. A pass brief says which PARTS its voice
    /// writes (Perkins takes the structural habits and the scenes, Gould
    /// leaves the letter empty); what a part MEANS is the same for all of
    /// them, and stating it once is what keeps a custom pass with no brief
    /// from getting a letter that means whatever the model guessed.
    ///
    /// Its cost is measured, not assumed:
    /// `CompilerPromptTests.test_theStandingPerRunInstructionAdditionsStayUnderAWordBudget`
    /// counts it into the standing per-run overhead every call pays.
    static let letterInstruction = """
        The letter is about the manuscript as a whole: it says what no \
        anchored finding can. about is one sentence: what this piece seems \
        to be about as read, not what it set out to be. one_thing is the one \
        thing to fix if the writer fixes only one, and null when there is \
        nothing. Name what works before what does not, each with the \
        principle behind it, so the writer can repeat it on purpose. A habit \
        is a pattern across everything you read, not one instance — at most \
        2 habits, 4 refs each — and one worth testing by name is voice \
        distinctness: could each character be identified by their lines \
        alone? An exercise is a thing to go and do, never a rewrite of their \
        words. You ask and nothing else: at most 3 questions, never a \
        suggested change. Where the pinned references hold the writer's own \
        pieces, measure this one against them by name before any rule. One \
        issue gets one entry: what is already filed as a strain, a \
        continuity question or a reader's report does not return here. Write \
        only the parts your pass brief allows; with no brief, write all of \
        them. About the prose you were given; on a cold reading, about the \
        whole piece. Where the writer has asked something, answer it in \
        answer first, directly and in your own register — an opinion where \
        they asked for one, never a rewrite; answer is null when they asked \
        nothing. A habit the ledger above already names is reported under \
        that heading, verbatim, with lesson null: the writer already has it. \
        A question raised under one of those habits names it in habit, \
        spelled as briefed. retired lists every briefed lesson you looked \
        for and did not find, verbatim, and is empty when there are none. \
        process is one sentence in your own words from the numbers under \
        \(processHeading), and null when none were given.
        """

    /// Sent once, when the warm session is spawned — never repeated per run.
    static func sessionSystemPreamble(projectId: String) -> String {
        """
        You are reading a manuscript-in-progress as a close, tasteful \
        reader giving the writer near-live feedback while they are still \
        writing — two jobs in one pass, and neither of them is a critic's. \
        As continuity editor you check the wet ink against what the \
        writer has declared: their intent, their rules, and the facts \
        already established. As first reader you report what happens in \
        the reading itself: where the dream broke, what a reader believes \
        and when. Note the problem, never the solution; ask a question \
        rather than hand down a verdict. You are not a linter and you do \
        not rank your opinions — there are no severity levels. Give notes \
        worth reading: specific, concise, and grounded in what the prose \
        is actually doing against what the writer says they're going for. \
        Silence on a clause or a paragraph is a valid response; do not \
        manufacture a note to fill space.

        This session is long-lived: later messages will build on what \
        you've already read here. Each run gives you the wet ink since \
        the last run, the writer's declared world when they have one, and \
        the facts you've already read off the manuscript.

        Project: \(projectId)
        """
    }

    // MARK: - The two builders (two loops P1 Task 3, spec §4.9)

    /// **Author's ⌘R.** The delta since the marker, dosed by the draft stage,
    /// filed in no lane — so this door has no `previousRound` to pass.
    ///
    /// Thin on purpose: one message builder, two named doors. The alternative
    /// — two builders assembling their own sections — is two spellings of the
    /// briefing, and the sections they share are all of them but one.
    ///
    /// The value of the door is what it CANNOT say: a caller holding a prior
    /// round has nowhere to put it here, so a check briefed on another loop's
    /// conversation is a compile error rather than a silent section. The gates
    /// inside `runMessageV2` say the same thing a second time, for the callers
    /// that pass a kind directly — its tests, and `beginRun` until Task 4
    /// splits its one send into these two doors.
    static func checkMessage(
        delta: CompilerDelta, world: DerivedWorld?, essay: String?,
        bibleFacts: [BibleFact], paletteListing: [String], pinnedListing: [String],
        pass: CompilerOrchestrator.ActivePass? = nil,
        scenePosition: ScenePosition = .none,
        dispositions: [CompilerAnnotationDisposition] = [],
        ask: String? = nil,
        lessons: String? = nil,
        stage: DraftStage? = nil,
        freshEyes: Bool = false,
        signals: ProcessSignals? = nil,
        previousBriefingHash: String?
    ) -> (message: String, briefingHash: String?) {
        runMessageV2(
            delta: delta, kind: .check, world: world, essay: essay,
            bibleFacts: bibleFacts, paletteListing: paletteListing,
            pinnedListing: pinnedListing, pass: pass, scenePosition: scenePosition,
            dispositions: dispositions, ask: ask, lessons: lessons,
            stage: stage, freshEyes: freshEyes, signals: signals,
            previousBriefingHash: previousBriefingHash)
    }

    /// **Review's Run round.** The piece whole, read by the pass's editor,
    /// with the prior round in this lane above it — so this door has no
    /// `stage`, no `freshEyes` and no `signals` to pass.
    ///
    /// `freshEyes` is absent rather than defaulted because the flag's ONLY
    /// reader in this file is `stageSection`, which a round never gets: a cold
    /// round differs from a warm one in the session it is sent to and the
    /// sections it is not given (no prior round, no dispositions), and both of
    /// those are the orchestrator's decision, not this function's. If a second
    /// reader of the flag ever appears on the round side, it arrives with a
    /// parameter and a reason, not by inheriting one nothing here would read.
    ///
    /// `signals` is absent on that same rule (Task 4): its only reader here is
    /// `processSection`, which spec §4.9's round list omits — the writer's own
    /// drafting process is what a CHECK is read against, and an editor is
    /// handed the manuscript rather than the month that produced it.
    static func roundMessage(
        delta: CompilerDelta, world: DerivedWorld?, essay: String?,
        bibleFacts: [BibleFact], paletteListing: [String], pinnedListing: [String],
        pass: CompilerOrchestrator.ActivePass? = nil,
        scenePosition: ScenePosition = .none,
        previousRound: PriorRound? = nil,
        dispositions: [CompilerAnnotationDisposition] = [],
        ask: String? = nil,
        lessons: String? = nil,
        previousBriefingHash: String?
    ) -> (message: String, briefingHash: String?) {
        runMessageV2(
            delta: delta, kind: .round, world: world, essay: essay,
            bibleFacts: bibleFacts, paletteListing: paletteListing,
            pinnedListing: pinnedListing, pass: pass, scenePosition: scenePosition,
            previousRound: previousRound, dispositions: dispositions, ask: ask,
            lessons: lessons,
            previousBriefingHash: previousBriefingHash)
    }

    /// The run message: the declared world (essay + derived clauses/rules),
    /// the bible slice, the listings, the delta, and the section schema.
    ///
    /// The bible slice is rendered exactly as given — `bibleFacts` is the
    /// caller's job to compute (Task 3 slices by subjects the delta text
    /// mentions); this function only renders `subject: fact`, never a
    /// paragraph id, because a fact's `establishedAt` is an anchor for the
    /// pane's excerpt chip, not quotable prose this function has in hand.
    ///
    /// `briefingHash` covers essay + world + facts + the lessons ledger as ONE
    /// unit (the diff-in rule widened from v1's intent-only hash, and again at
    /// P2 Task 4): unchanged since the last run's hash → a single marker line
    /// replaces all four; changed → all four re-embed together, never
    /// partially. `nil` when there is nothing declared at all — no essay, an
    /// empty or absent world, no facts, and a ledger with nothing live in it —
    /// an empty declared world is a valid, un-hashed state (spec §7: the
    /// conformance section is simply absent). A writer with a ledger and no
    /// intent statement HAS declared something, so that alone is a hash.
    ///
    /// **The ledger's member is the rendered section, not its markdown** —
    /// see `briefingHashInput`, where the reason lives.
    ///
    /// `freshEyes` reaches the prompt for one thing only: `stageSection` has
    /// to state the dose that `DiagnosticIngest` will actually enforce, and a
    /// cold read is always the full letter whatever the stage. **This is the
    /// first time the flag crosses into `CompilerPrompt`** — everything else a
    /// fresh-eyes run does differently, it does by omission (no round section,
    /// no dispositions), which is why the parameter did not exist until P3.
    /// Do not grow a second use of it here without saying why: "cold read" is
    /// a fact about the RUN, and the sections are about the piece.
    ///
    /// `previousRound` is per-run state and is **never** part of that hash —
    /// see `roundSection`. Defaulted because "there is no previous round" is
    /// the ordinary answer (round 1 of a lane, a passless ⌘R, a fresh-eyes
    /// read) and because this function has exactly one production caller,
    /// `CompilerOrchestrator.beginRun`, which is where the lane rule is
    /// decided — and which will reach it through `checkMessage`/`roundMessage`
    /// above once Task 4 splits its send.
    ///
    /// **`kind` changes what is briefed and never the hashed unit** (two loops
    /// P1 Tasks 3 and 4). Four sections are scoped by it: the prose is the
    /// delta for a check and the piece whole for a round, the draft stage and
    /// the process numbers behind it reach a check alone, and the prior round
    /// in this lane briefs a round alone. The
    /// essay, the world, the bible slice and the ledger are what the writer
    /// DECLARED — which loop asked for this run is not one of those — so a
    /// check and a round over an unchanged intent hash identically and the
    /// second of them gets the marker line, not the briefing again.
    ///
    /// Defaulted to `.check` because the check is the verb that predates the
    /// split: every call site written before `RunKind` existed was one, and a
    /// default that silently briefed a round as a check would be the wrong way
    /// round.
    static func runMessageV2(
        delta: CompilerDelta,
        kind: RunKind = .check,
        world: DerivedWorld?, essay: String?,
        bibleFacts: [BibleFact], paletteListing: [String], pinnedListing: [String],
        pass: CompilerOrchestrator.ActivePass? = nil,
        scenePosition: ScenePosition = .none,
        previousRound: PriorRound? = nil,
        dispositions: [CompilerAnnotationDisposition] = [],
        ask: String? = nil,
        lessons: String? = nil,
        stage: DraftStage? = nil,
        freshEyes: Bool = false,
        signals: ProcessSignals? = nil,
        previousBriefingHash: String?
    ) -> (message: String, briefingHash: String?) {
        var sections: [String] = []

        // Assembled once and used twice — the hash is over the ledger AS
        // BRIEFED rather than over the writer's file, so retiring a lesson
        // (which changes the file and nothing the model is told) leaves the
        // hash where it was. See `briefingHashInput`.
        let lessonsSection = lessonsSection(lessons)
        let hash = briefingHashInput(
            essay: essay, world: world, bibleFacts: bibleFacts, lessons: lessonsSection)
            .map(sha256Hex)
        if let hash, hash == previousBriefingHash {
            sections.append("Declared world and bible: unchanged since last run.")
        } else if hash != nil {
            if let essay, !essay.isEmpty {
                sections.append("Declared intent (essay):\n\(cleaned(essay))")
            }
            if let world, !(world.clauses.isEmpty && world.rules.isEmpty) {
                sections.append(worldSection(world))
            }
            if !bibleFacts.isEmpty {
                sections.append(bibleSection(bibleFacts))
            }
            // Last of the four, and inside the gate with them: the ledger is
            // something the writer has DECLARED — like the essay, the world
            // and the facts above it — rather than context that moves with the
            // run, so all four diff in as one unit and a round that changed
            // none of them is told so in one line.
            if let lessonsSection {
                sections.append(lessonsSection)
            }
        }

        sections.append(
            contentsOf: listingSections(pinnedListing: pinnedListing, paletteListing: paletteListing))

        // Between the listings and the delta: context about the prose the
        // delta is about to show, rather than part of the standing briefing
        // above it or of the thing being checked below it. **None of these
        // three is ever folded into `briefingHashInput`** — each changes with
        // the writer rather than with what they declared, and a hash covering
        // any of them would never match its predecessor, so the essay, the
        // declared world and the bible slice would re-embed in full on every
        // ⌘R. Who is reading, what they said last time, and what the writer
        // has done about it — in that order, because the frame is what the
        // rest is read through.
        if let passSection = passSection(pass) {
            sections.append(passSection)
        }
        // Beside the role frame and above the rest of it: what form this piece
        // takes is read the same way as who is reading it — a frame for the
        // delta rather than a fact about the delta. Per-run like its three
        // neighbours, and out of the hash for the same reason (constraint 5):
        // it moves when the writer changes their intent or switches lanes.
        if let scenes = scenePositionSection(scenePosition) {
            sections.append(scenes)
        }
        // The stage, then the numbers behind it, in that order: what this run
        // is being asked to write, and then the observation the letter's own
        // process line may be built from. Per-run frame like the three above
        // them, and out of the hash for the same reason (constraint 25) with
        // one sharper of its own — the stage flips the first round the
        // writer stops adding and starts rewriting, and the numbers move with
        // their week, so a hash covering either would never match its
        // predecessor.
        //
        // The stage is written on every production check; the numbers only
        // when a plain threshold was crossed. A quiet session says nothing at
        // all rather than saying there is nothing to say.
        //
        // **The stage doses a CHECK and never a round** (spec §4.8, two loops
        // P1): a round is always the full letter — its pass brief decides
        // which parts — so a stage reaching one would ask for the short letter
        // over a piece the editor was told to read whole. Switched rather than
        // `if kind == .check`, on `RunKind.of(persona:)`'s rule: a third loop
        // is then a compile error at every fork that decides on the kind,
        // instead of silently taking the arm nobody wrote for it.
        //
        // **And the numbers go with it** (two loops P1 Task 4, spec §4.9's
        // round list, which omits them). `ProcessSignals` is Maugham's own
        // observation of the WRITER's process — sessions since the frontier
        // moved, a paragraph rewritten seven times, three weeks away — and it
        // is the check's context because a check is the writer's own read of
        // what they have just been doing. An editor reads the manuscript, not
        // the working month that produced it. Inside the `.check` arm rather
        // than beside it, so the two halves of that one answer cannot part
        // company.
        switch kind {
        case .check:
            if let stageSection = stageSection(stage, freshEyes: freshEyes) {
                sections.append(stageSection)
            }
            if let processSection = processSection(signals) {
                sections.append(processSection)
            }
        case .round:
            break
        }
        // And its mirror: the prior round in this lane reaches the ROUND loop
        // alone. A check is filed in no lane (Task 1), so "last round you
        // raised these notes" over one would ask this run to confirm findings
        // from a conversation it is not part of.
        switch kind {
        case .round:
            if let previousRound,
               let round = roundSection(
                previousRound: previousRound.record, notes: previousRound.notes) {
                sections.append(round)
            }
        case .check:
            break
        }
        if let dispositions = dispositionsSection(dispositions) {
            sections.append(dispositions)
        }
        // Last of the per-run frame, and closest to the delta on purpose: the
        // ask is the writer's own words about the prose immediately below it,
        // so it is the final thing said before the prose itself. **Out of
        // `briefingHashInput` for its four neighbours' reason** (global
        // constraint 5) and one of its own: an ask is expected to change every
        // round — that is what it is for — and a hash covering it would never
        // match its predecessor, so the essay, the declared world and the
        // bible slice would re-embed in full on every ⌘R a writer asked
        // anything on.
        if let ask = askSection(ask) {
            sections.append(ask)
        }

        // The prose itself, and the one thing the two verbs actually read
        // differently (spec §4.5). What changed since the last round reaches a
        // round through the two sections above rather than through a diff.
        switch kind {
        case .check: sections.append(deltaSection(delta))
        case .round: sections.append(wholePieceSection(delta))
        }

        sections.append(sectionSchemaDescription)

        return (sections.joined(separator: "\n\n"), hash)
    }

    // MARK: - v2 declared-world / bible sections

    private static func worldSection(_ world: DerivedWorld) -> String {
        var lines: [String] = ["Declared world — the writer's own sentences, and what checking each one means:"]
        for clause in world.clauses {
            lines.append("- \"\(cleaned(clause.quote))\" — \(clause.check)")
        }
        for rule in world.rules {
            lines.append("- \(rule.subject): \"\(cleaned(rule.quote))\" — \(rule.constraint)")
        }
        return lines.joined(separator: "\n")
    }

    private static func bibleSection(_ facts: [BibleFact]) -> String {
        var lines: [String] = ["Established so far:"]
        for fact in facts {
            lines.append("- \(fact.subject): \(cleaned(fact.fact))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - The lessons ledger (editorial letter P2 §3.8)

    /// **What the writer has learned, as this run is told it** — their own
    /// preamble, the lessons they are still working on, and the choices they
    /// have settled.
    ///
    /// **A retired entry is briefed to nobody.** Retiring is how a writer says
    /// they are done with a lesson, and putting it back in front of the model
    /// is the one thing retiring it was for. The two live kinds are stated
    /// separately because they ask for opposite behaviour: an open lesson is
    /// something to look for and report under its own heading, a settled
    /// choice is something never to raise at all.
    ///
    /// `nil` when there is nothing live to say — no preamble, no open lesson,
    /// no choice — on `askSection`/`passSection`/`scenePositionSection`'s
    /// rule: the call site composes optional sections in one spelling, and a
    /// section saying the writer has learned nothing would spend words telling
    /// the model to do nothing. **That `nil` is also what keeps a retirement
    /// out of the briefing hash** — see `briefingHashInput`.
    static func lessonsSection(_ markdown: String?) -> String? {
        guard let markdown else { return nil }
        // Asked of `LessonsLedger` three times rather than filtered here off
        // one parse: which rows are open and which are settled is that type's
        // grammar, and a filter spelled here would be a second owner of it.
        // The cost is three parses of one small file, once per keystroke.
        let essay = cleaned(LessonsLedger.parse(markdown).essay)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let open = LessonsLedger.open(in: markdown)
        let choices = LessonsLedger.choices(in: markdown)
        guard !essay.isEmpty || !open.isEmpty || !choices.isEmpty else { return nil }

        var lines: [String] = []
        // **Labelled like every sibling section** ("Declared intent (essay):",
        // "Established so far:"). Without it a ledger that is only a preamble
        // arrives as an unattributed paragraph directly under the bible's
        // list, reading as one more thing established rather than as the
        // writer talking about their own work.
        if !essay.isEmpty {
            lines.append("What the writer has learned (their own words):")
            lines.append(essay)
        }
        if !open.isEmpty {
            lines.append(
                "Lessons the writer is working on — cite one by its heading, "
                    + "verbatim, with lesson null:")
            lines.append(contentsOf: open.map { "- \(cleaned($0))" })
        }
        if !choices.isEmpty {
            lines.append("Choices the writer has made — never raise these:")
            lines.append(contentsOf: choices.map { "- \(cleaned($0))" })
        }
        return lines.joined(separator: "\n")
    }

    /// The one place the v2 briefing hash's input is assembled, so the hash
    /// gate and the embed decision can never compute it two ways. `nil`
    /// when essay, world (empty counts as absent) and facts are ALL absent
    /// — nothing to diff in means no hash to track.
    ///
    /// **`lessons` is the rendered SECTION, not the ledger's markdown** (P2
    /// Task 4). The hash exists to answer "has what this run is told changed?",
    /// and a ledger's file moves for reasons the briefing never sees: retiring
    /// an entry rewrites the writer's line and removes it from the section, so
    /// hashing the file would re-embed the essay, the whole declared world and
    /// the bible slice to communicate a deletion. Hashing what is actually
    /// said keeps the marker line honest in both directions.
    private static func briefingHashInput(
        essay: String?, world: DerivedWorld?, bibleFacts: [BibleFact], lessons: String?
    ) -> String? {
        let essayEmpty = essay?.isEmpty ?? true
        let worldEmpty = world.map { $0.clauses.isEmpty && $0.rules.isEmpty } ?? true
        let lessonsEmpty = lessons?.isEmpty ?? true
        guard !essayEmpty || !worldEmpty || !bibleFacts.isEmpty || !lessonsEmpty
        else { return nil }

        var parts: [String] = ["essay:\(essay ?? "")"]
        if let world {
            parts.append(
                "clauses:" + world.clauses.map { "\($0.quote)|\($0.check)" }.joined(separator: ";"))
            parts.append(
                "rules:" + world.rules.map { "\($0.subject)|\($0.quote)|\($0.constraint)" }
                    .joined(separator: ";"))
        }
        parts.append("facts:" + bibleFacts.map { "\($0.subject)|\($0.fact)" }.joined(separator: ";"))
        parts.append("lessons:\(lessons ?? "")")
        return parts.joined(separator: "\n")
    }

    // MARK: - The pass's editor and brief (M4 P1 §4)

    /// What a pass with no brief of its own is told to read for — the honest
    /// fallback rather than silence. A custom pass the writer named and never
    /// wrote doctrine for still has a name, and the name is the only altitude
    /// anybody has declared.
    static let brieflessPassFallback =
        "No brief is recorded for this pass. Attend at the altitude its name "
        + "suggests, and leave the other altitudes to the passes that own them."

    /// **The role frame** (spec §4): who is reading, and what they read for.
    ///
    /// `nil` for a passless ⌘R, which is M2's all-altitudes check and has no
    /// editor to be — a frame invented for it would be a register the writer
    /// never chose.
    ///
    /// The editor's name and the brief are read off the `ActivePass` resolved
    /// once at the keystroke, never re-resolved here: the same value signs the
    /// notes this round mints, and a second resolution site is how the byline
    /// and the briefing come to describe different passes (`ActivePass`'s own
    /// doc).
    ///
    /// **Never folded into `briefingHashInput`.** It is per-run state for the
    /// round section's reason — the writer moves the piece from lane to lane,
    /// and a hash that moved with them would re-embed the whole declared world
    /// on the round after every switch.
    static func passSection(_ pass: CompilerOrchestrator.ActivePass?) -> String? {
        guard let pass else { return nil }
        // **A brief the writer emptied is a brief they do not have.**
        // `ReviewPass.effectiveBrief` lets a stored `""` win over the preset's
        // doctrine, which is right for resolution — the writer deleted it on
        // purpose — and would put a blank line under the role frame here. The
        // fallback is what "no doctrine" is supposed to read as.
        let brief = pass.brief
            .map(cleaned)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // **The coach is a teacher, not an editor** (spec §4.1, §4.4). She is
        // a pass in every respect this file cares about — a name, an editor,
        // a brief — and `isCoach` is the ONE thing that differs, resolved once
        // in `AuthorReader` — a CHECK's reader, and the only verb that can
        // carry the flag — and read only here. Her own name is the noun in the
        // frame (lowercased, because it is a common noun in this sentence
        // where a stage's is a proper one), so a writer who renames the seat
        // renames what she teaches rather than leaving a second spelling of
        // "workshop" in this file.
        let frame = pass.isCoach
            ? "You are \(pass.editorName), this writer's \(pass.name.lowercased()) teacher."
            : "You are \(pass.editorName), this manuscript's \(pass.name) editor."
        return """
            \(frame)
            \(brief ?? brieflessPassFallback)
            """
    }

    // MARK: - The scene position (editorial letter P1 §3.4)

    /// **What form this piece takes, stated rather than inferred** (spec
    /// §3.4). `ScenePosition` decides it app-side from the project's type, the
    /// writer's whole intent statement and the active pass's brief; this is
    /// the one sentence that tells the model which of the three positions it
    /// is in, and what that means for the letter's `scenes` array.
    ///
    /// **Every position gets a sentence, `.none` included.** Saying nothing
    /// would hand the model back the exact judgement the derivation exists to
    /// take off it — whether this book moves by scenes at all — and it would
    /// make that judgement from the delta's prose rather than from anything
    /// the writer declared.
    ///
    /// The `.strongDeclared` / `.strongDefault` split is the sharp edge, and
    /// it is the only place in the prompt where a section is told NOT to raise
    /// something: conformance is keyed on a `clause_quote` from the intent
    /// statement, so under `.strongDefault` — a screenplay whose intent is
    /// silent, a prose piece opted in by a pass brief — there is no clause of
    /// the writer's to strain against, and a strain raised anyway would be the
    /// app synthesizing the standard it then judges them by. The gap is the
    /// Add-to-intent offer's, and the offer is the writer's to accept
    /// (Task 9).
    ///
    /// **`String?` for its two siblings' reason** (`passSection`,
    /// `roundSection`): the call site composes optional sections in one
    /// spelling. No position is silent today, which
    /// `CompilerPromptTests.test_everyScenePositionGetsItsOwnSentence` pins.
    ///
    /// **Never folded into `briefingHashInput`** (global constraint 5). It
    /// moves with the writer — a pass switch changes it — and a hash covering
    /// it would re-embed the essay, the declared world and the bible slice on
    /// the round after every switch.
    static func scenePositionSection(_ position: ScenePosition) -> String? {
        let sentence: String
        switch position {
        case .none:
            sentence = """
                This piece does not move by scenes — the writer's own intent \
                says so. Answer the letter's scenes with null, and raise \
                nothing anywhere about a scene failing to turn.
                """
        case .weak:
            sentence = """
                This piece moves by scenes, but the writer has declared \
                nothing about how. Give a row per scene — what it wants, what \
                changes in it, its turn — with charge always null. A scene \
                where nothing seems to change is an observation worth making \
                plainly, never a fault: say what you see and ask whether it is \
                the point.
                """
        case .strongDeclared:
            sentence = """
                This piece moves by scenes in the strong sense, and the writer \
                declared it in their own intent. Give each row a charge of + \
                or -, and where a scene does not turn, ALSO raise it in the \
                conformance section as a strain against the writer's own \
                clause, quoted in clause_quote exactly as they wrote it.
                """
        case .strongDefault:
            sentence = """
                This piece moves by scenes in the strong sense by its form or \
                by the brief of the pass it is in — not by anything the writer \
                declared. Give each row a charge of + or -, and where a scene \
                does not turn, say so in the row as an observation. Do not \
                raise it as a conformance strain: the writer has not declared \
                that clause, and there is nothing of theirs to quote.
                """
        }
        return "Scenes in this piece: \(sentence)"
    }

    // MARK: - The draft stage and its dosage (P3 Task 4, spec §3.8)

    /// **How much letter this run's delta has earned** — the second half of
    /// global constraint 24, whose first half is `DiagnosticIngest.parseLetter`
    /// capping the answer at ingest. Both, never one: the briefing is how the
    /// model is asked for a short letter, and the cap is what makes it short
    /// whatever the model did.
    ///
    /// **The stage is the RUN's, not the model's.** It is derived at the
    /// keystroke from this run's own delta and the document's own signals
    /// (`DraftStage.derive`), so the section states a fact rather than asking a
    /// question, and nothing the answer says about it is read back.
    ///
    /// **Deliberately outside
    /// `CompilerPromptTests.test_theStandingPerRunInstructionAdditionsStayUnderAWordBudget`**
    /// (global constraint 26). That budget measures the text that rides EVERY
    /// run; this is per-run frame, on `scenePositionSection`'s footing —
    /// written only when there is a stage to name, and different words on a
    /// drafting round from a revising one. Folding it into a standing-overhead
    /// total would charge every run for words half of them never carry. It has
    /// a ceiling of its own instead:
    /// `CompilerPromptTests.test_theDraftingDosageStaysUnderItsOwnWordCeiling`.
    ///
    /// **`String?` on `passSection`/`roundSection`/`scenePositionSection`'s
    /// rule**: the call site composes optional sections in one spelling. Every
    /// production run carries a stage — `beginRun` derives one before it sends
    /// — so the `nil` arm is for this function's other callers and for a test
    /// that is not about the stage.
    ///
    /// **Never folded into `briefingHashInput`** (global constraint 25), and
    /// its reason is sharper than its neighbours': the stage is derived from
    /// the delta, so it flips the first round the writer stops adding and
    /// starts rewriting — a hash covering it would re-embed the essay, the
    /// declared world and the bible slice on exactly that round.
    /// **`freshEyes` is the second half of the answer, not a detail.** The dose
    /// is `stage.dosage(freshEyes:)`, and that function answers `.full` on a
    /// cold read whatever the stage — so a drafting piece read with ⌘⇧R is
    /// enforced full at ingest, and a section that told it to write the short
    /// letter would be asking for one thing while allowing another with nothing
    /// else in the message to say which wins. The two ends state the same dose
    /// or neither is trustworthy (global constraint 24).
    static func stageSection(_ stage: DraftStage?, freshEyes: Bool) -> String? {
        guard let stage else { return nil }
        switch stage {
        case .drafting where freshEyes:
            return """
                Draft stage: drafting, and this is a cold read. Most of what \
                changed is new prose and the frontier moved this session, but \
                Fresh Eyes rereads the whole piece from nothing, and a cold \
                read is always the FULL letter: about, working, habits with \
                their exercise, questions, and the scenes table your scene \
                position allows. The short letter belongs to the ordinary \
                round; this is not one.
                """
        case .drafting:
            return """
                Draft stage: drafting. The frontier moved this session and most \
                of what changed is new prose, so this is a first draft in \
                motion and must not be line-edited. Write the SHORT letter: \
                about, working, at most one question, and a habit only where \
                it runs through the whole delta. No exercise, and answer \
                scenes with null. Whatever the stage, a question the writer \
                asked is answered in full — the ask overrides the dose. The \
                full letter waits for Fresh Eyes, which always reads the piece \
                cold and always writes all of it.
                """
        case .revising:
            return """
                Draft stage: revising. What changed is mostly rework of prose \
                that already stood, so write the full letter — every part your \
                pass brief allows.
                """
        }
    }

    // MARK: - The process numbers (P3 Task 4, spec §5)

    /// What the section is called, and the one spelling of it on this side of
    /// the seam: `letterInstruction` interpolates it ("the numbers under
    /// \(processHeading)") rather than restating the word, so a rename cannot
    /// leave the schema pointing at a heading that no longer exists.
    ///
    /// The coach's brief names it too, and CANNOT interpolate — `ReviewPass`
    /// lives in MaughamCore, which does not see this type. That spelling is
    /// held by `CompilerPromptTests.test_theCoachsBriefNamesTheProcessNumbers\
    /// Declaratively`, which pins her sentence whole.
    static let processHeading = "Process"

    /// The section's own first line — the heading, plus what these numbers are
    /// and are not.
    ///
    /// A constant rather than an inline string because the heading ALONE is
    /// not a witness that the section was written: `letterInstruction` names
    /// `Process` in its own prose, so a test asking whether a quiet session
    /// wrote a section has to look for this line rather than for the word.
    static let processSectionOpening =
        "\(processHeading) — counted off this document's own op log, not read "
        + "out of the prose:"

    /// **The numbers behind the letter's one process sentence** — and only when
    /// a plain threshold says they are worth a line (spec §5).
    ///
    /// `nil` for a quiet session, which is most sessions, and that silence is
    /// the feature: a heading over "the frontier moved this session" would be
    /// the app narrating an ordinary working day back at the writer.
    /// `ProcessSignals.noteworthy` owns the whole of the judgement; this
    /// function only says what it found.
    ///
    /// **Never folded into `briefingHashInput`** (global constraint 25): the
    /// numbers move with the writer's own week, so a hash covering them would
    /// never match its predecessor.
    static func processSection(_ signals: ProcessSignals?) -> String? {
        guard let signals else { return nil }
        let noteworthy = signals.noteworthy
        guard !noteworthy.isEmpty else { return nil }
        return ([processSectionOpening] + noteworthy.map { "- " + processSentence($0) })
            .joined(separator: "\n")
    }

    /// One signal, as one sentence with its number in it.
    ///
    /// **Every sentence carries a count**, because a sentence without one is an
    /// opinion, and the refusal to have one is the whole of `ProcessSignals`.
    ///
    /// **A hotspot is named by its POSITION, not by its text.** The excerpt
    /// lives on the live paragraph and this function is pure — it is handed a
    /// value computed off the op log and nothing else — so "the 4th paragraph"
    /// is the honest address here. The Statistics window, which has the prose
    /// in hand, shows the excerpt instead (global constraint 31).
    static func processSentence(_ signal: ProcessSignals.Signal) -> String {
        switch signal {
        case .frontierUnmoved(let sessions):
            return """
                The frontier has not moved in \(sessions) sessions: nothing \
                new has been added past the end of this document in that time.
                """
        case .hotspot(let hotspot):
            return """
                The \(ordinal(hotspot.position + 1)) paragraph has been \
                rewritten \(hotspot.rewrites) times in the last \
                \(ProcessSignals.churnWindowSessions) sessions.
                """
        case .coldRead(let days):
            return """
                The writer had been away from this document for \(days) days \
                before this session.
                """
        }
    }

    /// "4th" for 4 — a paragraph's address reads as an ordinal, and this is the
    /// one place the prompt counts that way.
    private static func ordinal(_ value: Int) -> String {
        let suffix: String
        switch (value % 100, value % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(value)\(suffix)"
    }

    // MARK: - The writer's dispositions (M4 P1 §5.5)

    /// The heading over the notes that are still live.
    static let standingNotesHeading =
        "Standing \u{2014} the writer is holding these. Confirm one where the "
        + "prose still earns it, let it resolve where it does not, and never "
        + "raise it again as new:"

    /// Its complement: the notes the writer has answered.
    static let settledNotesHeading =
        "Settled \u{2014} the writer has answered these. Do not raise them again "
        + "in any section:"

    /// How many settled notes a briefing lists.
    ///
    /// **Capped where the standing list is not**, and the asymmetry is the
    /// whole point: settled notes accumulate for the life of the piece and
    /// would eventually be most of the prompt, while the standing ones are
    /// what the writer is holding right now and are this section's real job.
    /// Truncating the standing half would mint duplicates; truncating the
    /// settled half costs at worst a finding raised twice over a long history,
    /// and the count says how much was left out rather than pretending the
    /// history is shorter than it is.
    ///
    /// **Which twelve survive is the caller's order, not a sort here** — and
    /// the caller that decides it is `CompilerAnnotationDisposition.gather`,
    /// where the rationale lives. This function renders what it is handed.
    static let settledDispositionLimit = 12

    /// How much of a note's body a briefing line carries.
    ///
    /// A body is the model's own prose from an earlier round and can run to a
    /// paragraph; what this section needs is enough to recognise the finding,
    /// not enough to re-read it.
    static let dispositionExcerptLimit = 160

    /// **What the writer has already done about this piece's notes** (spec
    /// §5.5, spike-validated verbatim: a declined note with a reason was not
    /// re-raised in any section).
    ///
    /// Two partitions saying opposite things. A **standing** note is live — it
    /// is in the writer's queue as this round begins, so raising it again as
    /// news gives them two copies of one finding to dispose of. A **settled**
    /// one is their answer, and raising it at all asks them to answer twice.
    ///
    /// `nil` — no section — when the piece has no compiler-authored notes at
    /// all, which is every first round and every piece the writer has cleared.
    ///
    /// **A standing fingerprint silences its settled twin.** The mint's dedupe
    /// stops two OPEN notes sharing a fingerprint, but nothing stops an open
    /// note sharing one with a note settled earlier and re-raised since — and
    /// briefing both would tell the model to confirm and to forget the same
    /// finding. The live note wins: it is the one the writer is looking at.
    ///
    /// Notes with no fingerprint are the anchorless kind (a doc-scoped craft
    /// note, whose finding has no discriminator to make one from), and they
    /// are listed individually rather than collapsed — a nil fingerprint is
    /// the absence of identity, not an identity they share. This section is
    /// their ONLY duplicate guard on a warm round.
    static func dispositionsSection(
        _ dispositions: [CompilerAnnotationDisposition]
    ) -> String? {
        let standing = dispositions.filter { $0.state == .standing }
        let standingFingerprints = Set(standing.compactMap(\.fingerprint))
        let settled = dispositions.filter {
            guard $0.state != .standing else { return false }
            guard let fingerprint = $0.fingerprint else { return true }
            return !standingFingerprints.contains(fingerprint)
        }
        guard !standing.isEmpty || !settled.isEmpty else { return nil }

        var lines: [String] = [
            "Notes already on this piece from earlier rounds \u{2014} the writer "
            + "has them in front of them, so none of these is news."
        ]
        if !standing.isEmpty {
            lines.append("")
            lines.append(standingNotesHeading)
            lines.append(contentsOf: standing.map(line(of:)))
        }
        if !settled.isEmpty {
            lines.append("")
            lines.append(settledNotesHeading)
            lines.append(contentsOf: settled.prefix(settledDispositionLimit).map(line(of:)))
            let elided = settled.count - settledDispositionLimit
            if elided > 0 {
                lines.append(
                    "- \u{2026}and \(elided) more the writer has already settled.")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func line(of disposition: CompilerAnnotationDisposition) -> String {
        let excerpt = shortened(cleaned(disposition.excerpt))
        guard let verdict = disposition.state.verdictWord else { return "- \(excerpt)" }
        // **The same treatment as the excerpt, and for the same reason.** A
        // rejection reason is the writer's own prose in a free-text field —
        // it can run to a paragraph and it can carry newlines, either of
        // which breaks a bullet list into what reads as several notes.
        let reason = disposition.reason.map { ": \(shortened(cleaned($0)))" } ?? ""
        return "- \(excerpt) [\(verdict)\(reason)]"
    }

    /// Enough of a note to recognise it by, and a mark saying there was more.
    private static func shortened(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard collapsed.count > dispositionExcerptLimit else { return collapsed }
        return collapsed.prefix(dispositionExcerptLimit) + "\u{2026}"
    }

    // MARK: - The writer's ask (editorial letter P2 §3.7)

    /// What the writer asked of THIS run, in their own words — "I'm worried
    /// the middle sags" — and the instruction to answer it before anything
    /// else.
    ///
    /// **Their words are quoted, never paraphrased into an instruction.** An
    /// ask is the one part of a briefing the writer typed themselves, and the
    /// letter answers a person rather than a directive; the guillemets mark
    /// where their sentence starts and stops so a two-sentence ask cannot read
    /// as one sentence of theirs and one of ours.
    ///
    /// `nil` for a nil or blank ask, on `passSection`/`roundSection`/
    /// `scenePositionSection`'s rule: the call site composes optional sections
    /// in one spelling, and a section saying the writer asked nothing would
    /// spend words telling the model to do nothing. Blank is guarded here as
    /// well as in `DiagnosticsStore.setAsk` because this function is public
    /// and a second caller must not be able to brief an empty question.
    ///
    /// **Never folded into `briefingHashInput`** — see the append site.
    static func askSection(_ ask: String?) -> String? {
        guard let ask, !ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return """
            The writer asks, this round: \u{00ab}\(cleaned(ask))\u{00bb}
            Answer it in the letter's answer field before anything else you \
            have to say, and let the rest of the letter follow.
            """
    }

    // MARK: - The previous round (M3-P3 §6)

    /// One note the previous round raised, as the next round's briefing sees
    /// it: what it said, which section said it, and whether the writer has
    /// been working behind it since.
    ///
    /// `kind` is the enum rather than its string, on tripwire 12's reasoning —
    /// the section a note came from is its whole classification, and a
    /// stringly-typed one here would be a second vocabulary to keep in step
    /// with `DiagnosticIngest.SectionField`.
    struct PriorNote {
        let body: String
        let kind: DiagnosticKind
        /// The paragraph this note was anchored to no longer reads as it did
        /// — `DiagnosticsStore.live`'s own anchor-text equality, asked at the
        /// keystroke. An anchorless note is never "since edited": it has
        /// nothing to track, exactly as it has nothing to go stale against.
        let sinceEdited: Bool
    }

    /// The previous round in this run's lane, with what it found.
    ///
    /// The record and the notes travel together because the section needs
    /// both halves and neither is derivable from the other: the round's
    /// identity lives on the record, and its prose lives only in the standing
    /// sidecar (`DiagnosticsStore.standingRound`).
    struct PriorRound {
        let record: RoundRecord
        let notes: [PriorNote]
    }

    /// **The partition the app knows and the model cannot**: the writer has
    /// rewritten the prose one of these notes was measured against, so the
    /// note may already be answered by the draft itself.
    static let sinceEditedHeading = "The writer has since edited the prose behind these:"

    /// Its complement — the prose still reads exactly as it did when the note
    /// landed, so anything that has changed is the reading, not the draft.
    static let untouchedHeading = "Untouched since that round:"

    /// **What the last round in this lane raised, so this one confirms rather
    /// than reconstructs** (spec §6, M3-P3 §6).
    ///
    /// `nil` — no section at all — in two cases, neither of them a round the
    /// model should hear about:
    ///
    /// - the record carries no lane, or no round number. The comparison lane
    ///   is `(document, pass)` and a passless run is an ordinary M2 run; this
    ///   is the second door on the room `CompilerOrchestrator` guards first.
    /// - the round raised no notes. There is nothing to confirm, and a
    ///   sentence saying so is a paragraph of prompt telling the model
    ///   nothing it can act on. What that round DID is still counted — the
    ///   pane's line reads the ring, not this.
    ///
    /// **It is never folded into `briefingHashInput`, and that is the whole
    /// reason it is assembled here rather than up there.** This section
    /// changes every single round by construction, so a hash covering it would
    /// never match its predecessor and the essay, the declared world and the
    /// bible slice would re-embed in full on every ⌘R — the diff-in the hash
    /// exists to make possible, undone by the one thing that can never be
    /// diffed. `CompilerPromptTests.test_theRoundSectionNeverFoldsIntoTheBriefingHash`
    /// asserts the hash is byte-identical across two rounds with unchanged
    /// intent.
    ///
    /// **No new answer section comes with it.** The model's confirmation rides
    /// the note sections it already answers in; what resolved and what
    /// persists is computed app-side off the writer's queue (`SinceLastRound`),
    /// never parsed back out of prose the model wrote.
    static func roundSection(previousRound: RoundRecord, notes: [PriorNote]) -> String? {
        guard let passId = previousRound.passId, let round = previousRound.round else {
            return nil
        }
        guard !notes.isEmpty else { return nil }

        var lines: [String] = [
            "Round \(round) of the \u{201C}\(passId)\u{201D} pass raised these notes."
        ]
        // The edited-behind half first: it is the one the model would
        // otherwise re-raise against prose that has moved under it.
        for (heading, partition) in [
            (sinceEditedHeading, notes.filter(\.sinceEdited)),
            (untouchedHeading, notes.filter { !$0.sinceEdited }),
        ] where !partition.isEmpty {
            lines.append("")
            lines.append(heading)
            for note in partition {
                lines.append("- (\(sectionName(of: note.kind))) \(cleaned(note.body))")
            }
        }

        lines.append("")
        lines.append(
            "Confirm rather than reconstruct. Where one of these still stands "
            + "against the prose as it reads now, raise it again in its own "
            + "section, in your own words and from your own reading. Where it "
            + "no longer stands, let it go and say nothing about it. And raise "
            + "whatever this round shows you that the last one did not \u{2014} a "
            + "note is not worth less for being new, or more for having been "
            + "made before.")
        return lines.joined(separator: "\n")
    }

    /// The section a note came out of, in the schema's own vocabulary — read
    /// off `DiagnosticIngest.SectionField` rather than restated, so the words
    /// the model is reminded of are the words it was asked to answer in.
    private static func sectionName(of kind: DiagnosticKind) -> String {
        switch kind {
        case .conformanceStrain: return DiagnosticIngest.SectionField.conformance
        case .continuity: return DiagnosticIngest.SectionField.continuity
        case .readerReport: return DiagnosticIngest.SectionField.reader
        // **Unreachable today, and so are the two arms above it.** The
        // briefing's prior-round notes come from `DiagnosticsStore.
        // standingRound`, which hands back the SIDECAR's diagnostics — and
        // since M4 P1 those are conformance strains alone. A letter question
        // is a `Diagnostic` in `accepted` and in `mintable`, never in
        // `sidecarDiagnostics`, so it reaches the next round through the
        // dispositions section as an open annotation, not through here. The
        // arm exists because the switch is exhaustive and because a sidecar
        // record written before that split still names its section; the word
        // it answers with is the one the schema asks in, which is what this
        // function is for.
        case .letterQuestion: return DiagnosticIngest.SectionField.letter
        }
    }

    // MARK: - Listings (pinned / palette)

    private static func listingSections(pinnedListing: [String], paletteListing: [String]) -> [String] {
        var sections: [String] = []
        if !pinnedListing.isEmpty {
            sections.append(
                "Pinned references (id and title only — fetch full contents "
                    + "with read_document if a note needs them):\n"
                    + pinnedListing.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !paletteListing.isEmpty {
            sections.append(
                "Palette cards (id and title only — fetch full contents "
                    + "with read_palette_card if a note needs them):\n"
                    + paletteListing.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections
    }

    // MARK: - Delta section

    private static func deltaSection(_ delta: CompilerDelta) -> String {
        var lines: [String] = ["This run's delta:"]

        if delta.new.isEmpty && delta.revised.isEmpty {
            lines.append("Nothing new or revised since the last run.")
            return lines.joined(separator: "\n")
        }

        if !delta.new.isEmpty {
            lines.append("\nNew paragraphs — these answer only to intent, "
                + "there is no prior version to compare against:")
            for paragraph in delta.new {
                lines.append("[\(paragraph.paragraphId)] (new)")
                lines.append(cleaned(paragraph.text))
            }
        }

        if !delta.revised.isEmpty {
            lines.append("\nRevised paragraphs — each carries what it said "
                + "before and what it says now, because a revision implies "
                + "a goal the writer already had in mind:")
            for paragraph in delta.revised {
                lines.append("[\(paragraph.paragraphId)] (revised)")
                lines.append("Before: \(cleaned(paragraph.prior))")
                lines.append("After: \(cleaned(paragraph.text))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - The piece, whole (two loops P1 Task 3, spec §4.5)

    /// **What a round reads.** A round passes `since: nil` to `DeltaBuilder`
    /// (Task 4), so the delta it hands over is the whole standing manuscript
    /// in `sequence` order — every paragraph `new`, nothing `revised`. This
    /// renders it as what it is: the piece, with no labels on it.
    ///
    /// **The labels are dropped rather than kept for tidiness.** Over a whole
    /// read "(new)" is true of every paragraph and says nothing, and there is
    /// no prior version to put after "Before:" — a diff's vocabulary over a
    /// whole read tells the editor they are being shown a change when they are
    /// being shown a book. What DID change since the last round reaches the
    /// round through the prior-round and dispositions sections above, which is
    /// the spec's answer (§4.5) and the one M4 P1 already built.
    ///
    /// **The order is the manuscript's.** `DeltaBuilder` walks `sequence`, so
    /// the arrays arrive in the order the writer reads them in; this function
    /// keeps that order and never sorts. A sort of any kind here would hand
    /// the editor a piece whose scenes are out of order with nothing in the
    /// message to say so.
    ///
    /// `revised` is walked after `new` rather than dropped: production hands a
    /// round nothing there, but a delta this function cannot interleave (the
    /// two arrays are each in sequence order and their join is not recoverable
    /// from them) must still lose no prose — the words are safe is the first
    /// invariant, and a caller who builds a round's delta some other way gets
    /// every paragraph, out of order, rather than silence.
    private static func wholePieceSection(_ delta: CompilerDelta) -> String {
        var lines: [String] = ["The piece, whole:"]

        if delta.new.isEmpty && delta.revised.isEmpty {
            // Unreachable from `beginRun`, which refuses an empty delta before
            // a message is ever built — stated anyway, on `deltaSection`'s
            // rule: a function whose caller must reason before calling it is
            // one the next caller gets wrong.
            lines.append("This piece has no prose in it yet.")
            return lines.joined(separator: "\n")
        }

        for paragraph in delta.new {
            lines.append("[\(paragraph.paragraphId)]")
            lines.append(cleaned(paragraph.text))
        }
        for paragraph in delta.revised {
            lines.append("[\(paragraph.paragraphId)]")
            lines.append(cleaned(paragraph.text))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Anchor hygiene

    /// Defense in depth: the delta is expected to already carry clean text
    /// (anchors are a materialize-time artifact, never part of an in-memory
    /// paragraph's text), but nothing embedded in a prompt should ever leak
    /// one if it somehow did. Reuses the one shared anchor-stripping
    /// transform (CLAUDE.md: don't add a target-local copy).
    private static func cleaned(_ text: String) -> String {
        MarkdownDisplayFilter.stripAnchors(text)
    }

    // MARK: - Hashing

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// **One compiler-authored note as the next round's briefing sees it** (M4 P1
/// Task 4, spec §5.5).
///
/// The findings that leave the compiler are annotations now (`CompilerNote`),
/// which means the record of what the writer did about them lives in the
/// annotation layer and not in anything the compiler kept. This is that record
/// as a value: gathered at the keystroke from the open document, carried into
/// the message, and never held across the subprocess turn (tripwires 3, 6 —
/// the orchestrator holds no `Document`).
///
/// Small on purpose. The model needs to recognise the finding and know what
/// became of it; it does not need the note's id, its kind, its anchor or its
/// author, and every field here has a reader in `CompilerPrompt`.
struct CompilerAnnotationDisposition: Equatable, Sendable {

    /// What the writer has done about a note, in the four cases a briefing
    /// can act on.
    ///
    /// A typed enum rather than a string (tripwire 12): adding a fifth
    /// disposition is adding a case, and every place that renders one is then
    /// the compiler's problem rather than a reviewer's.
    ///
    /// **`.accepted` and `.archived` are deliberately absent** rather than
    /// forgotten. An accepted note is one the writer ACTED on, so the prose it
    /// named has moved — the finding either no longer holds (nothing to
    /// suppress) or holds against different words and is honestly news again.
    /// An archived note was set aside unread and carries no verdict at all;
    /// briefing it as settled would put words in the writer's mouth.
    enum State: Equatable, Sendable {
        /// Open, and the writer has not said no to it. Live, and in their
        /// queue as this round begins.
        case standing
        /// Open, and marked `decline` in triage: the writer has said what they
        /// intend to do about it, which is nothing.
        case declined
        /// Read, considered, and the words stand.
        case stetted
        /// Settled no.
        case rejected

        /// The word the briefing states the verdict in — `nil` for a standing
        /// note, which is not a verdict but the absence of one.
        var verdictWord: String? {
            switch self {
            case .standing: return nil
            case .declined: return "DECLINED"
            case .stetted: return "STETTED"
            case .rejected: return "REJECTED"
            }
        }
    }

    /// `Annotation.compilerFingerprint` — the one identity spelling
    /// (`RoundFingerprint.stringValue`), read back rather than re-derived.
    /// `nil` for an anchorless finding, which has no discriminator to make one
    /// from; such a note is briefed on its own rather than pooled with every
    /// other fingerprintless one.
    let fingerprint: String?
    /// The note's body. Shortened at render time rather than here, because how
    /// many words a briefing can afford is the message's decision and not the
    /// document's.
    let excerpt: String
    let state: State
    /// The writer's own words about this note, where they wrote any — the
    /// `userResponse` on the resolution, else the reason of a rejection they
    /// have since reopened (RULING-31 keeps it as part of the note's record).
    /// `nil` for a bare triage decline, which carries a mark and no prose.
    let reason: String?

    init(fingerprint: String?, excerpt: String, state: State, reason: String?) {
        self.fingerprint = fingerprint
        self.excerpt = excerpt
        self.state = state
        self.reason = reason
    }

    /// **The one projection** from the annotation layer into the briefing —
    /// `nil` for a note this section has nothing to say about.
    ///
    /// Two refusals, each for its own reason:
    ///
    /// - a note the compiler did not write. The writer's own notes, and
    ///   Claude Desktop's, are theirs; briefing the model on what it must not
    ///   re-raise only makes sense for findings it raised.
    /// - a note the writer ACCEPTED or ARCHIVED (`State`'s own doc). Neither
    ///   is a verdict this section can act on.
    init?(annotation: Annotation) {
        guard annotation.isCompilerAuthored else { return nil }
        let state: State
        switch annotation.status {
        // A triage decline is a mark on an OPEN note, not a resolution — the
        // note is still live and still in the queue. It is briefed as settled
        // all the same, because what the model must do about it is what it
        // must do about a rejection: leave it alone. The writer said no.
        case .open: state = annotation.triage == .decline ? .declined : .standing
        case .stetted: state = .stetted
        case .rejected: state = .rejected
        case .accepted, .archived: return nil
        }
        self.init(
            fingerprint: annotation.compilerFingerprint,
            excerpt: annotation.body,
            state: state,
            // The live resolution's own words first; failing that, the reason
            // of a rejection the writer has since reopened, which RULING-31
            // keeps precisely because it is still part of this note's record.
            // A bare triage decline has neither, and says DECLINED alone.
            reason: annotation.userResponse ?? annotation.previousRejectionReason)
    }

    /// **The gatherer**: a document's annotations as the briefing's
    /// dispositions, in the order the briefing should spend its budget in.
    ///
    /// Pure, and the one place the ORDER is decided — the production closure
    /// in `CompilerEnvironment+Project` calls this and does nothing else, so
    /// the rule is testable without a document on disk.
    ///
    /// **Settled notes are ordered by when they were SETTLED, newest first,
    /// and that is not the order they arrive in.** `Document.annotations` is
    /// sorted by `createdAt` descending — when the model RAISED each finding —
    /// and the two orders come apart the moment a writer works through a
    /// backlog: a question raised in round 1 and answered this morning is the
    /// one whose prose they are still near, and under the cap it is the one
    /// worth the words. Sorting on arrival order would brief the twelve most
    /// recently RAISED, which after a catch-up session is close to the twelve
    /// least recently thought about.
    ///
    /// A `.declined` note has no `resolvedAt` — a triage mark is not a
    /// resolution — so declines sort after every dated verdict, and ties (and
    /// the undated) fall back on arrival order rather than on nothing:
    /// `sorted(by:)` is not stable, and an unstable order here would reshuffle
    /// the briefing between two runs that had nothing change.
    ///
    /// **The standing half is not sorted and not capped.** It is what the
    /// writer is holding, and its order is the deriver's own.
    static func gather(from annotations: [Annotation]) -> [CompilerAnnotationDisposition] {
        let projected = annotations.enumerated().compactMap {
            index, annotation -> (arrival: Int, settledAt: Date?,
                                  disposition: CompilerAnnotationDisposition)? in
            Self(annotation: annotation).map { (index, annotation.resolvedAt, $0) }
        }
        let standing = projected.filter { $0.disposition.state == .standing }
        let settled = projected.filter { $0.disposition.state != .standing }
            .sorted { lhs, rhs in
                switch (lhs.settledAt, rhs.settledAt) {
                case let (left?, right?):
                    return left == right ? lhs.arrival < rhs.arrival : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.arrival < rhs.arrival
                }
            }
        return (standing + settled).map(\.disposition)
    }
}
