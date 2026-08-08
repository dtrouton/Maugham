# Maugham — the ruling set

**GENERATED from `experiment/01-claims-ledger.json` (`_meta.rulings`). Do not hand-edit.**
Regenerate with `python3 experiment/scripts/23-generate-rulings.py` after any ruling change.

25 rulings, 4 principles.

Every ruling carries its **BASIS** — the reason it was made. The basis is load-bearing:
applying a ruling to a new case means re-checking the basis, not pattern-matching the
conclusion. Four rulings here were originally filed with a correct verdict and a wrong basis,
and two rested on a belief about the code that did not hold.

## Roots — general. A root cited beside a sub that already reaches the case is decoration.

### RULING-9 — filesystem responsibility  `RATIFIED`

> What a writer does to their project outside Maugham is their risk. What Maugham does on their behalf is Maugham's.

*applied:* Maugham never creates a symlink (verified: no createSymbolicLink anywhere) and importResearchFolder COPIES rather than links. So every symlink in a project is writer-planted, and deleting through one is the writer's risk. No defence needed; the surface is ratified, not closed.

### RULING-19 — L — layered duties: upper layers tell, lower layers protect  `RATIFIED`

> Guards at an ENTRY POINT must fail and TELL THE WRITER. Lower layers — storage, rendering, serialisation — are responsible for protecting the system and the data, and are not obliged to communicate. Redundancy between the two is correct, not duplication.

*shape:* LAYERED — the first ruling that assigns different duties to different layers rather than stating one flat rule

*basis:* Denver: 'the guards above should fail and tell the user. The responsibility at the lower level is to protect the system and data — I think this is actually a decent layered abstraction.'

*scopes RULING 7:* RULING-7 ('never misrepresent a failure') applies to WRITER-FACING surfaces. A lower layer has no surface on which to misrepresent anything. I had been applying R7 to any code path that swallowed something, which is why the renderer's skip looked like a violation.

*settles:*
  - **M1-T-041 / M1-T-042** — RATIFIED with a correct basis at last. The renderer skipping an untagged-empty note is a LOWER layer protecting the round-trip law. Previously ratified under RULING-1, whose scope is accepting at an entry point — wrong layer.
  - **extension TRAP 15** — Answered. The silent drop is correct AT THAT LAYER. The hazard it named — a future back door making the drop a live loss path — is an UPPER-layer failure and belongs there, not an argument against the lower layer's behaviour.

*corollary RULED:* A repair firing at a lower layer means a guard above did not fire — that is a BUG. Confirmed by Denver, promoted from inference to ruled. Lower layers protect silently from the WRITER, but must not be silent to the developer: a repair is a defect signal.

### RULING-20 — ROOT — honour the writer's intent; where intent is unclear, default safe  `RATIFIED`

> We trust the writer to know what they want, and we do our best to honour it. Where their intent is unclear, we default SAFE. Where their intent cannot be parsed at all, what we do must be NON-DESTRUCTIVE and easy for them to recover from and correct.

*basis:* Denver: 'A, B and C are all instances of us honouring the writer's intent — we trust them to know what they want, and we do our best to honour that. If we aren't sure about the intent we default safe. D is a case where we can't parse their intent. What we do though is crucially non-destructive — it's easy for the writer to recover from and do what they meant.'

*collapses my three candidates:*
  - **A same action, same result** — honouring intent — the writer's action means what they meant, wherever taken
  - **B container shape** — honouring intent — they chose that destination; it takes that shape
  - **C a guess never destroys** — the default-safe clause, applied where intent is uncertain

*resolves D:* M1-C-021 is NOT a defect. An empty `kind:` is intent Maugham cannot parse. Its consequence — a later `kind: location` appearing as body prose — is visible, non-destructive and trivially correctable by the writer. That is the safe default working, not a bug.

### RULING-24 — ROOT — protection is TIERED, and the boundary is economic  `RATIFIED`

> DELETING STATE IS NOT DELETING HISTORY. Protection is tiered:
  THE WORK — the prose, the screenplay, the thing being created — is protected AT ALL COSTS and is version-controlled: every change to it is retained.
  RESEARCH is recoverable but not versioned.
  INGESTED OR DERIVED material — a voice note already promoted as text, a cache, a render — is not protected; losing it costs nothing but annoyance.
The boundary is PRACTICAL ECONOMICS: images, voice notes and PDFs are large, and versioning everything would be expensive.

*shape:* TIERED — protection differs by asset class, not by layer or by surface

*basis:* Denver: 'there is a difference between deleting state and history… why not keep and version everything? It's just practical economics… so we have a boundary — the WORK, the prose, the screenplay, the thing that's being created must be protected at all costs. Research can be recovered, voice notes already promoted as text are losing nothing. But the work must always be protected, that's why we version control everything that happens to it.'

*basis correction:* Denver added 'for the time being we rely on the ⌘S [and] filesystem backups for [research]'. VERIFIED FALSE for the ⌘S half: allDocIds = documentIds(in: manifest.STRUCTURE) — the manuscript binder, not manifest.research — and a Checkpoint stores docPointers [docId: opId], pointers INTO op logs. Research notes have no op log, so a checkpoint could not cover them even if they were enumerated. Research's only safety net is FILESYSTEM BACKUPS, entirely outside Maugham.

*resolves GAP 2:* The op log surviving 'permanently delete' is not a contradiction of RULING-23. Trash deletes STATE; history retention is a separate contract governed by the tier. For a manuscript the history is retained BECAUSE the work is protected at all costs — consistent, not contradictory. RULING-23 stands; my reading of it was wrong.

*scopes RULING 4:* R4's 'authored words are always recoverable' now has a tier attached: absolutely for the work, best-effort for research, not at all for ingested material. Without this, R4 read as an absolute promise the architecture never made.

*explains:*
  - why manuscripts have op logs and research notes do not
  - why three implementers found hard-deleting an inbox asset acceptable
  - why CheckpointCapture walks structure and not research

*future:* Denver: 'in future we might version control parts of research too'

## Sub-rulings — prefer these. Name the MOST SPECIFIC that reaches a case.

### RULING-1 —   `—`

> Maugham MUST NOT accept, through any of its own entry points, content it cannot read back faithfully. The refusal must be visible at the point of entry rather than discovered later.

*scope:* every entry point Maugham itself offers — the editor, MCP writes, canvas promotion, inbox promote

*rationale:* Product-level, from the constitution's 'the words are safe'. The writer must never be able to create, from inside the app, content that will later be eaten. Stated by Denver as: 'this is what makes it important there isn't a foot gun and people can't enter things that will get eaten within Maugham'.

### RULING-2 —   `—`

> A file on disk MAY contain content Maugham drops when reading it. That is acceptable. The fidelity obligation is on the ENTRY POINTS, not on the file.

*scope:* the parse path, for files arriving from outside — hand-edits, imports, sync

*rationale:* Consistent with the existing hard invariant that external .md edits are not honored and the model owns the file. Deliberately NOT symmetric with RULING-1: strictness applies where a person can act, tolerance applies where a file arrives.

### RULING-3 — E — What is on disk stays legible to the writer  `DEFERRED`

> Filename legibility for non-Latin scripts is NOT YET DECIDED. Today a title producing no ASCII slug yields `NN-untitled.md`, and that is accepted as an interim state — not because it is right, but because multilingual first-language support has not been scoped across the app.

*consequence:* A writer working in Japanese, Russian, Greek or Hebrew has a project folder that is opaque outside the app. This is now a known and accepted limitation rather than an unexamined defect.

* superseded verdict:* DECLINED

*revisit when:* a full cross-app review of multilingual first-language support is undertaken

*correction note:* Originally recorded as DECLINED, which read as a permanent product position. Denver's actual basis is that the governing decision has not been made. A deferral and a decline look identical in the code and are entirely different in the register.

### RULING-4 — A — Nothing is lost without a trace, and loss is recoverable  `RATIFIED_NARROWED`

> Words the writer authored are ALWAYS recoverable. Derived or transient material — a failed transcription, a superseded render, a cache — may be dropped, but the drop must be reported. Recovery is guaranteed only where the writer would look for it.

*consequence:* Every case must be classified as authored or derived, and the line will be argued. A trash-restore that fails with the words intact on disk is a defect under this ruling; a discarded cache is not.

*scope clause added:* Recoverability is owed against ACCIDENTS and against MAUGHAM'S OWN ACTIONS. It is not owed against the writer's own deliberate deletion, which is intent to be honoured (RULING-23).

### RULING-5 — F — What Maugham does on the writer's behalf carries a higher duty  `RATIFIED_STRICT`

> A suggestion whose quoted phrase can no longer be found in the writer's paragraph MUST NOT be applied. It is refused, the writer is told why, and they may ask again. Maugham never guesses where an AI-authored change belongs.

*consequence:* A suggestion the writer still wants becomes unusable after any nearby edit — accepted deliberately as the price of never mis-placing AI text. Directly closes the verified mis-splice defect.

### RULING-6 — C — The writer's text is theirs; presentation is ours  `RATIFIED`

> Stored text is never changed by a formatting convention. An EDITING surface renders as-typed, because a caret indexes into the source and display substitution desyncs it. A READING surface may present the form's conventions. EXPORT is a reading surface that produces an artifact for someone else, so the convention is offered to the writer as an option at publish time rather than chosen for them.

*consequence:* The phone reader's uppercase is ratified, not accidental. The Mac editor's as-typed rendering has a stated reason (the caret). Export gains an option it does not have today.

*provenance:* Recovered from commit de1b69d7 + Maugham/Editor/AREA.md: display-time uppercase was BUILT and REJECTED for cursor-positioning reasons; a dead ScreenplayLayoutManager relic was deleted 2026-06-10. The split was considered, not cheap.

### RULING-7 — B — A failure must be reported as what it is  `RATIFIED_BY_DEFAULT`

> Maugham never misrepresents a failure. Unreadable is never presented as empty. A refusal names its real cause. An empty replacement reads as a deletion. A capture this build cannot handle says so rather than appearing broken.

*consequence:* No product trade-off; consistency work only.

*scope clause added:* A surface is WRITER-FACING if what it returns reaches the writer without an independent check — including anything served to Claude (RULING-21).

### RULING-8 — D — One question, one answer, on every surface and every path  `RATIFIED_BY_DEFAULT`

> Where the same product question is answered in more than one place, it has one answer. A second surface or a second code path may not answer it differently.

*consequence:* A meta-rule: cheap to state, expensive to enforce. It is what makes the 17 INCONSISTENT findings defects rather than observations.

*sameness clause RULED:* Two situations that merely look alike may legitimately differ. Sameness is judged from the WRITER'S question — whether the writer is asking the same thing — never from whether the code paths differ. (Recommended by the phase-22 audit and cited by RECONCILE.md discipline 5 before it was written; ruled by Denver 2026-08-08. R8 was unqualified until this date — filings made before it, including M4-RW-019's, weighed an escape clause that did not yet exist.)

### RULING-10 — C/E — a slug collision rewrites the writer's title  `CLOSE`

> When a Collection piece's slug collides, Maugham appends a number to the writer's TITLE (`第二章` -> `第二章 2`) in the binder and manifest. Accepted as an interim state.

*basis:* Multilingual first-language support is not a decided product scope. Some of it falls out and works; this does not. Explicitly accepted on that basis rather than defended.

*revisit when:* the same cross-app multilingual review as RULING-3

*tension noted:* Sits against RULING-6 (stored text is never changed by a formatting convention) — a title is stored text, a slug is a filename convention. The tension is accepted knowingly, scoped to the undecided area, not resolved.

*compounding:* RULING-3 + RULING-10 together mean a non-Latin-script writer can distinguish their chapters neither in the binder nor on disk. That is now a stated interim cost with a named trigger, rather than two unrelated accidents.

* superseded verdict:* DEFERRED

*reclassified by:* RULING-16

*reclassification note:* Closeable without the deferred multilingual decision: make addLoosePiece behave like addResearchTextNote — dedupe the FILENAME, never the writer's title. Fixes the Latin-script case (two same-titled pieces) and the Japanese case for free. RULING-3 remains genuinely deferred: filenames stay illegible for non-Latin scripts until multilingual is scoped.

### RULING-11 — G — Maugham's own bookkeeping must never alter the writer's intent  `RATIFIED`

> Maugham stores invisible metadata inside the writer's text — paragraph anchors, task anchors, structural framing. Adding, removing or interpreting that metadata MUST NOT change what the writer meant, in either direction: not what they see, not what is stored, not what Claude is shown.

*basis:* Denver: 'our implementation is impacting what the writer's intent was — and that's the thing we really want to honour when we're messing about with the metadata.'

*settles:*
  - **MarkdownDisplayFilter word fusion** — stripping a task anchor also eats the preceding character, so 'very <!--t-…-->angry' displays as 'veryangry'. Remove the marker; collapse a RESULTING double space; never fuse. Also fixes what Claude is served, which is the root of the mis-splice.
  - **M1-C-023** — a writer-typed blank line before `kind:` is eaten because it is indistinguishable from the renderer's own structural pad. Same shape: Maugham's bookkeeping destroying a deliberate mark. Now a DEFECT, not a quirk.

*relation to RULING 6:* RULING-6 governs formatting CONVENTIONS and stored text. RULING-11 governs Maugham's own INVISIBLE METADATA and writer intent. Strictly stronger: it covers what the writer sees and what Claude reads, not only what is saved.

### RULING-12 — platform scope  `BASIS_INVALIDATED`

> A CRLF-terminated card parsing as one line and losing every field is accepted as an interim state. The basis is PLATFORM SCOPE, not fidelity: there is no Windows Maugham client, so CRLF means the file was touched by something that is not Maugham (RULING-9 — outside the app is the writer's risk).

*revisit when:* Windows gains official app support, at which point CRLF becomes a first-class input and this becomes a defect

*corrects:* My earlier filing of M1-C-024 as ACCEPTED_LIMIT under RULING-2. The verdict was right and the REASONING was wrong: RULING-2 tolerates content Maugham cannot represent, and a line ending is not that — every field in a CRLF file is perfectly representable. Under my basis it stays accepted forever; under the real basis it expires with the platform decision.

* superseded verdict:* DEFERRED

*evidence:* ParagraphParser recognises \n, \r, \r\n, NEL, LS and PS as line terminators — deliberately, documented, and pinned by PerfFastPathDifferentialTests. Maugham has already decided CRLF should work, for manuscripts. 14 sites do not follow: PaletteCard, MarkdownBlockParser, TranslationDeriver, TaskDeriver, Document+Tasks (x2), ProjectSearchEngine, OpLogStore, BackupSignature, UpdateInstaller, Promotion, CanvasRenderer, ScrapText (x2).

*consequence:* Under RULING-8 this is one question with two answers in the codebase — a defect today, independent of any Windows client. Needs re-ruling on the corrected basis.

### RULING-13 — H — losing identity must not orphan what was attached to it  `RATIFIED`

> When a paragraph's identity is not recovered, its annotations MOVE WITH THE TEXT and are marked STALE. They are never silently detached or archived. Staleness is a signal to the author, who decides whether each one still applies.

*basis:* Denver: 'this is actually a decision we made a long time ago, when fewer things depended on it. Back then this was not a big deal, now I think it's a potential bug. What I'd expect is those annotations move to the new paragraph but get set as STALE as they may no longer be able to be applied, but the author should make that call.'

*reuses existing:* `isStale` already exists for a suggestion whose text changed under it. This extends the same concept to an annotation whose PARAGRAPH changed under it. No new vocabulary.

*consequence for the threshold:* The 0.6 shingle threshold stops being a CORRECTNESS boundary and becomes a heuristic. A wrong identity decision is now recoverable — the annotation is present and marked, not archived elsewhere. Several ShingleMatcher findings drop in severity.

*settles:*
  - ShingleMatcher: whose notes survive when two paragraphs are joined — all of them, marked stale
  - ShingleMatcher: a split is not a rename — annotations follow the text, marked stale
  - ShingleMatcher: 'the obligation to make a loss visible extends to notes' — satisfied by the mark
  - the archive-list discovery problem: there is nothing to discover late, the mark is in place

*open half:* Whether Maugham's OWN smart-typography substitution costing a short paragraph its identity is separately forbidden by RULING-11. Proposed, not asserted — smart typography is an opted-in feature, not metadata, so the R11 reading is a stretch.

### RULING-14 — I — promotion is an ingestion boundary  `RATIFIED`

> Promoting a capture is about getting data INTO Maugham. Once inside, the result is an ordinary project artifact — research item, palette note, canvas scrap — and is moved, renamed and deleted by the ordinary rules. There is no reverse-promote.

*basis:* Denver: 'this is fine because this is getting the data into Maugham — once in Maugham it's on us to have the ability to move that import around (and you can do that now, as I ran into this issue and decided that was the right fix). It becomes another piece of research or whatever and can be acted on in the same way.'

*collapses:* Replaces a special case (un-promote machinery, per-destination dedup policy) with a general one already built. Settles InboxEntry #9 and largely dissolves #5.

### RULING-15 — J — delete is normalised: nothing is unlinked  `RATIFIED`

> Maugham does not delete a file. It moves it to trash, from which the writer can restore it — and, for a capture, re-ingest it. This is the single meaning of delete across the app.

*basis:* Denver: 'we don't delete the file on disk, we move it to trash… that might be cleanest as we normalise how we think about delete.'

*immediate defects:*
  - InboxStore:250 promoteToResearch — FileManager.removeItem on the inbox asset (hard unlink)
  - InboxStore:315 palette promote — same
  - InboxStore:396 canvas promote — same

*recovery path:* restore from trash, then re-ingest — which RULING-14 makes sufficient

### RULING-16 — K — a deferral is a hold, not a licence  `RATIFIED`

> A deferral MUST NOT be used as the reason to leave an unrelated surface open. Anything closeable independently of the deferred decision is closed now. The deferred area is opened later intentionally and in scope — not found already occupied by things that drifted in while it was parked.

*basis:* Denver: 'if something is deferred we should try to avoid depending on it for closes — that's a surface area that should later be opened intentionally in a scoped way rather than left open for anything else to happen in between.'

*operational:* For every DEFERRED ruling, ask: what is currently justified by this deferral that does not actually depend on it? Close those.

*immediately found:*
  - RULING-10 (title mutation) was sheltering under RULING-3's multilingual deferral. The correct behaviour already exists one file over in addResearchTextNote; converging is not a multilingual feature. Reclassified DEFERRED -> CLOSE.
  - RULING-12 (CRLF) was deferred on platform scope — but ParagraphParser is ALREADY deliberately CRLF-safe (Character.isNewline's full set, pinned by PerfFastPathDifferentialTests). The decision was made long ago for manuscripts. 14 other sites split on a literal newline. The inconsistency is internal and closeable now; the Windows question is not what is holding it.

### RULING-17 — inbox transcription  `RATIFIED`

> A failed transcription is NOT retried automatically. `.failed` sits outside the worker's eligible set, deliberately, so a corrupt file is not hammered. The writer asks for a retry. This is correct behaviour now.

*basis:* Denver: 'this is something which I'd say is correct behaviour NOW — and the ruling confirms this. Could it be a better experience, yes — but that's enhancement not bug.'

*enhancement noted:* Distinguishing transient failures (model not downloaded, machine busy) from permanent ones (corrupt audio) and re-running the transient ones would be a better experience. Recorded as an ENHANCEMENT, not a defect.

### RULING-18 — (rejects a candidate family)  `RATIFIED`

> Paragraph identity is computed on the text as it is, whoever changed it. A transformation the writer OPTED INTO — smart quotes, em-dash and ellipsis replacement, any configured auto-format — is the WRITER'S edit, not Maugham's, and carries no special duty.

*basis:* Denver: 'I rule 2 as these are options the writer has asked for.'

*verified:* TypographySettings.smartQuotes / emDashAutoReplace / ellipsisAutoReplace are per-project settings with a Settings tab and a project sheet. The writer switched them on.

*rejects:* The candidate family 'an edit Maugham makes on the writer's behalf carries a higher duty'. It dissolves: the category is mostly empty once opted-in transformations are attributed to the writer.

*boundary it draws:* DID THE WRITER ASK FOR THIS TRANSFORMATION?
  yes -> it is the writer's edit. Ordinary rules. (smart typography, configured auto-format)
  no, and it is invisible bookkeeping -> RULING-11 (anchors, structural framing)
  no, and it is AI-authored text -> RULING-5 (a suggestion whose phrase is gone is refused)
This is the line between R11 and R18, which was previously undrawn — I had been treating every transformation Maugham performs as Maugham's.

*consequence:* The verified case stands and is accepted: '"Go."' -> '“Go.”' scores 0.500 bigram overlap, below the 0.6 reuse threshold, so a two-word line of dialogue gets a fresh id. Under RULING-13 its notes follow and are marked stale. The writer may re-adjudicate a note on a line they did not consciously change — accepted, because they asked for the transformation that changed it.

### RULING-21 — RULING-7 scope — Claude is part of the writer's surface  `RATIFIED`

> What Maugham serves to Claude IS a writer-facing surface for the purposes of RULING-7. A surface is writer-facing if what it returns reaches the writer without an independent check — including anything served to Claude. An ANSWER about the writer's content must be true; only a REPAIR may be silent.

*basis RULED:* Denver: 'there are probably bigger risks in Claude clobbering something not realising it's not appending — which is where this could bite… we have made Claude part of the writer's surface.' The operative harm is that Claude ACTS on what it is served, not that the writer forms a false belief.

*basis ARGUED and partly set aside:* The sweep agent argued from false belief — that interposing Claude launders the harm rather than diluting it. Denver's own reaction: 'if Claude told me a note was empty that I knew wasn't, I'd assume the MCP was broken and go check manually.' So the false-belief harm is WEAKER than argued; the acting-on-it harm is stronger. Same verdict, different and better basis.

*verified:* The named risk is LATENT, by construction. add_note CREATES a note (addResearchTextNote) and writes the body to the freshly-created file; it never writes to an existing one. Only two MCP tools write and both write into the planning plane — manuscript text is reachable from neither (CLAUDE.md hard invariant). RULING-21 is therefore PROSPECTIVE INSURANCE: it becomes load-bearing the day a write-to-existing-note tool is added.

*requires:* RULING-7 gains the scope clause explicitly. Its scope was previously settled by argument, which meant it would be re-argued in every sweep and different modules would land on different sides — the sweep agent's own recommendation, which held either way it was ruled.

### RULING-22 — M — never surprise the writer  `RATIFIED`

> Maugham should never surprise the writer. Controls are unambiguous and DO WHAT THEY SAY. Where an action is complex or its consequences are confusing, that warrants an additional confirmation prompt.

*basis:* Denver, verbatim.

*relation to RULING 7:* R7 governs FAILURES — never misrepresent one. R22 governs SUCCESSES — never let one differ from what the writer understood. Together: Maugham tells the truth whether or not something went wrong. R7's scope gap (it reaches only failures and refusals) is what left the six cases below settled by a root only.

*scope:* the writer forms an expectation from what Maugham showed, said or labelled, and the outcome differs from it

*settles IN SCOPE:*
  - **rewind label — FIXED 2026-08-08 (8fb77a81), historical evidence only**: 'Rewind to before this…' did ops.prefix(THROUGH: idx) — inclusive — landing AFTER the op; the deep-link now posts the PREDECESSOR op (HistoryPane.predecessorIndex) and the old line numbers no longer hold. The disposition below records the ruling; do not file from this bullet
  - snapshot impact count
  - stale cursor silent no-op
  - unmentioned auto-archive
  - promotion duplicate

*OUT OF SCOPE on the scope test:*
  - **annotations-pane provenance** — the pane does not distinguish Maugham's auto-archiving from the writer's own. Nothing the writer expected failed to happen — this is an ABSENCE OF INFORMATION, not a mismatch between expectation and outcome. R22's scope does not reach it. It wants a separate clause: 'where Maugham resolves something on the writer's behalf, the resolution is labelled as Maugham's wherever it appears.' Left UNRULED rather than swept in.

*escalation clause:* 'complex or confusing warrants an additional confirmation' bears directly on rewind, which is the most complex action in the app and the source of four of these six.

*disposition M4 RW 002 RULED:* Denver, 2026-08-08: fix the BEHAVIOUR, not the label. 'Rewind to before this…' must land BEFORE the selected op (exclusive) — the label already says what a writer wants: pick the change you regret and land before it. First defect taken through the claim→fix→re-verify loop.

### RULING-23 — trash retention  `RATIFIED`

> Trash destroying its contents is Maugham HONOURING the writer's intent — they chose to delete. The retention window is leeway to change their mind, not a promise of permanence. Losing trash is not a defect.

*basis:* Denver: 'clearly the trash should destroy — this was the writer's intent on delete. We pause the actual deletion to give them some leeway to change their mind. But the writer losing trash is not a defect, it's us honouring their intent… having hit delete and having it turn up in something called trash I'm somewhat expecting it to do [that] at some point.'

*enhancement conceded:* Showing time remaining on a trashed item would be better — 'I'd concede the point that it's nicer to know when'. Recorded as an ENHANCEMENT under PRINCIPLE-2, not a defect.

*sharpens RULING 4:* R4's 'words the writer AUTHORED are always recoverable' means recoverable FROM ACCIDENTS AND FROM MAUGHAM'S OWN ACTIONS — not recoverable forever from the writer's own deliberate deletion. Without this clause R4 and R23 read as a contradiction; with it there is none.

*premise corrected:* I reported that the op log surviving 'permanently delete' meant R23 was made on a false premise. RULING-24 shows the error was mine: deleting state is not deleting history, and the two have different contracts. R23 stands as ruled.

### RULING-25 — N — annotations ride the writer's history  `RATIFIED_FROM_OPTIONS`

> Annotations — comments, tasks, suggestion status — are protected to the same standard as the work they annotate. Anything Maugham closes on the writer's behalf when they travel through their history is reopened when they travel back. Time travel never costs an annotation permanently or silently.

*basis:* Denver, 2026-08-08, ruling on GAP-R1 as presented: chose SYMMETRIC TRAVEL — annotations are protected to the same standard as the work; anything Maugham closes on the writer's behalf during time travel is reopened when they travel back — over 'marked stale, never closed' (GAP-R6's shape) and 'recoverable by hand' (GAP-R2's shape).

*resolves GAP R1:* RULING-24's partition (the work / research / ingested) had no class for annotations — a tiering root with a hole in the middle of its own domain. This places them: for the travel case they inherit THE WORK's standard. M4-RW-019 — a forward rewind returns the paragraph and the pane task but leaves the comment archived, permanently and silently — is a clean DEFECT under this ruling, no longer settled by RULING-8 alone.

*scope:* Maugham closing an annotation on ITS OWN initiative during history travel — rewind auto-archive and the return journey. The writer's own archive/resolve actions are their intent (RULING-23's shape) and are untouched by this ruling.

*relation to RULING 13:* R13 governs lost IDENTITY: annotations move with the text and are marked STALE, the author adjudicates. This ruling governs TIME TRAVEL, where identity is not lost — the paragraph genuinely did not exist yet at the travelled-to moment. Complementary, not overlapping. GAP-R6's proposal to stretch R13 over the travel case is superseded by this ruling.

*relation to GAP R2:* A Reopen action on the annotations pane (GAP-R2) remains an open surface question, but symmetric travel removes the rewind case's dependency on it: the return journey itself is the recovery route.

*provenance note:* Ruled via a structured question with a recommended option (accepted). The option labels and ALL surrounding rationale text are the agent's, ratified by Denver — a materially weaker basis than the interview-era rulings, whose bases are Denver verbatim. Weigh accordingly when this ruling's basis is load-bearing for a novel case; where the basis is decisive and thin, ask rather than extrapolate.

*scope boundary note:* 'Symmetric travel' compensates MAUGHAM'S OWN travel-archives only — narrower than the phrase suggests (independent verification, 2026-08-08). Lifecycle ops never ride the timeline prefix: rewinding back past the writer's own archive op does not reopen it (their intent has duration, RULING-23's shape), and an ACCEPTED suggestion the rewind archived stays archived on forward travel — its honest forward status would be .accepted, which is unruled and sits in the gap queue. Two edges recorded with it: the genuine-no-op restore path returns before the return journey runs, and the reopen is direction-agnostic (any .rewind restore whose target contains the anchor paragraph), which is broader than M4-RW-019's forward-travel framing.

## Principles — how to judge, not what to decide

### PRINCIPLE-1

> A decision's correctness is a function of how much depends on it. A ruling that was right when three things depended on it can be a bug when thirty do — without anyone changing it.

*basis:* Denver, on RULING-13: 'a decision we made a long time ago, when fewer things depended on it.'
*operational:* The register already carries reverse-dependency counts per claim (Phase 5). AGE x REVERSE-DEPENDENCY is the re-examination queue: old rulings whose dependency count has grown are the ones to revisit, and nothing about the code changing signals it. This is what the Phase 5 ratchet analysis measured without knowing what it was for.

### PRINCIPLE-2

> An enhancement is not a defect. A behaviour that violates no ruling is CORRECT, even where a better experience is imaginable. The register records ruling violations; it must not accumulate wishes.

*basis:* Denver, on RULING-17.
*why it matters:* Without this, every characterization finding reads as a potential bug and the defect queue inflates until nobody reads it. The register's authority depends on a DEFECT meaning exactly one thing: this violates a stated ruling.
*test:* name the ruling it violates. If you cannot, it is not a defect.

### PRINCIPLE-3

> Every finding is answered on TWO INDEPENDENT AXES, in order, and an earlier answer never substitutes for a later one.
  1. VIOLATION — does it violate a stated ruling? The ruling must reach it BY SCOPE, not by symptom. Name the ruling AND show the case falls inside its stated scope.
  2. INTENT — did we mean to offer this surface? Answered INDEPENDENTLY of (1).
  3. DISPOSITION — if unintended: CLOSE if the language allows, GUARD if it does not, ACCEPT only with a stated reason.
A finding may be NOT_A_DEFECT and still CLOSE. Those are different questions.

*basis:* Denver: 'the collapsing is useful so this might just be a sequencing issue — we need to make sure we aren't leaving things as open and accepted that should be tagged as close because it's an unwanted surface.'
*catches over application:* Scope-match instead of symptom-match. RULING-11's scope is Maugham's own invisible metadata — anchors, structural framing. The `kind:` one-shot rule is a CONTENT parsing rule, so R11 does not reach M1-C-021. RULING-1's scope is entry points and content that cannot be read back; a SensoryNote's single-line shape reads back fine, so R1 does not reach InboxEntry #7. Both errors are caught by asking 'is this in scope?' rather than 'did the same kind of thing happen?'
*catches under closure:* Axis 2 runs regardless of axis 1. The five items reclassified NOT_A_DEFECT under PRINCIPLE-2 are unwanted surface and must still carry CLOSE.
*audit step:* After any ruling round, list what the ruling was taken to settle and defend each against the ruling's SCOPE clause. ~30% of this session's resolutions failed that test.

### PRINCIPLE-4

> A ruling violation is a DEFECT regardless of how few writers can reach it. Reachability is recorded separately and governs PRIORITY. A defect may rationally never be fixed on ROI grounds — and that is NOT the same as an accepted limit: an accepted limit is correct by decision, a never-fix defect stays wrong.

*basis:* Denver: 'it is technically an issue but so unlikely that the priority of fixing it is miniscule and it would likely never be worth the ROI.'
*why the distinction matters:* Reachability drifts without anyone deciding anything. A defect parked on ROI re-prioritises itself the day its audience changes; an accepted limit does not, because it was ruled correct. Filing the first as the second loses that.
*relation to PRINCIPLE 1:* Same shape one level down. P1: a DECISION's correctness is a function of what depends on it. P4: a DEFECT's priority is a function of who can reach it. Both drift silently and neither is visible to any test.
*caution:* Reachability is the judgement I have been most wrong about — M1-C-053 was filed as a characterization curiosity until its callers were traced and the palette editor turned out to hand it free text. A reachability rating must cite the call path it was derived from, not an intuition.
