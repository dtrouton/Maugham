# Maugham — the ruling set

**GENERATED from `register/01-claims-ledger.json` (`_meta.rulings`). Do not hand-edit.**
Regenerate with `python3 register/scripts/23-generate-rulings.py` after any ruling change.

54 rulings, 4 principles.

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
  - **rewind label — FIXED 2026-08-08 (7f741db4), historical evidence only**: 'Rewind to before this…' did ops.prefix(THROUGH: idx) — inclusive — landing AFTER the op; the deep-link now posts the PREDECESSOR op (HistoryPane.predecessorIndex) and the old line numbers no longer hold. The disposition below records the ruling; do not file from this bullet
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

*scope boundary note:* 'Symmetric travel' compensates MAUGHAM'S OWN travel-archives. Lifecycle ops never ride the timeline prefix: rewinding back past the writer's own archive op does not reopen it (their intent has duration, RULING-23's shape). The accepted-then-archived case, recorded here as unruled from 2026-08-08 until later the same day, is now RULED by RULING-26: forward travel restores it to .accepted. Two edges stand: the genuine-no-op restore path returns before the return journey runs, and the reopen is direction-agnostic (any .rewind restore whose target contains the anchor paragraph).

### RULING-26 — N — accepted status rides travel too  `RATIFIED_FROM_OPTIONS`

> Travelling forward past an accept restores the suggestion to ACCEPTED, not merely to present. Where Maugham itself closed an annotation during history travel, the status it had at the travelled-to moment is what returns: full symmetry extends to accepted suggestions whose paragraph and applied text come back.

*basis:* Denver, 2026-08-08, structured question presented WITHOUT a recommendation (ratification-drift mitigation): chose 'Restore to accepted — full symmetry; status rides travel for everything Maugham itself closed' over 'stay archived' (the shipped behaviour) and 'reopen to open'.

*resolves:* The accepted-then-archived residual (independently confirmed blind, reconciliation/Rewind.verification-2026-08-08.json). RULING-25's wasOpen guard was the recorded boundary of the unruled case; this rules it.

*mechanism note:* The status-only .claudeAccept re-emission already exists — it is the rewind-undo's own instrument (Document+RewindUndo re-accepts with empty changes). Step 9 gains an accepted branch beside the reopen branch.

### RULING-27 — O — a missing moment is honoured approximately, never silently replaced  `RATIFIED_FROM_OPTIONS`

> A moment the writer selected in their history that no longer exists restores to the NEAREST SURVIVING MOMENT, the notice names what happened ('that exact moment is gone — restored to the nearest'), and the notice itself carries REVERT — the surfaced undo, one click at the moment of surprise. A missing moment is never quietly replaced by the present.

*basis:* Denver, 2026-08-08, structured question presented WITHOUT a recommendation: chose 'nearest surviving moment' — and ADDED the revert requirement unprompted; it was not among the offered options. The strongest provenance of the questionnaire era: the augmentation is Denver's own, verbatim in intent ('2 but with an option to revert'). The revert-form refinement (in the notice, not just ⌘Z) was recommended and accepted.

*settles:* GAP-R4. M4-RW-003/M4-RW-008/M4-RW-022's silent restore-to-the-present — already a defect under RULING-22 — now has its ruled replacement: nearest, named, revertible.

*relation to RULING 19:* If the vanished-cursor case proves impossible by construction (the UNTRACED note suggests the mirror always contains the cursor), R19's corollary still applies to the DERIVER's silent fallback — a repair defending nothing is deleted, and the nearest-moment behaviour lives at the restore boundary where the writer can be told.

### RULING-28 — M — the collateral report has two halves  `RATIFIED_FROM_OPTIONS`

> An operation that changes more than the writer asked about states the FULL set of collateral changes BEFORE they commit AND confirms what it actually did AFTER. Both halves ship: the confirmation names archives and reopens alike; the post-restore report confirms them. Naming one class of collateral change and omitting another is worse than naming none.

*basis:* Denver, 2026-08-08, structured question, no recommendation marked: chose 'Both halves' — the gap's own proposed text — over toast-only and confirm-only.

*settles:* GAP-R5. ProjectWindow's `_ =` discard of RewindRestoreResult (the truth produced and thrown away) is now a clean defect; RewindWindow's confirm-time impactSummary omitting reopens and archives is the other half of the same defect.

### RULING-29 — H — resolution is the writer's to reverse, from the surface that shows it  `RATIFIED_FROM_OPTIONS`

> Any archived or rejected annotation can be reopened by the writer from the annotations pane. Resolution is the writer's to reverse — whether Maugham made it or they did. A single undo immediately afterwards is not a recovery route; it expires. The pane action does not.

*basis:* Denver, 2026-08-08, structured question, no recommendation marked: chose 'Reopen for all archived' over Maugham-archived-only and no-pane-action. Matches RULING-13's basis: staleness and resolution are signals to the author, 'who decides whether each one still applies'.

*settles:* GAP-R2. Document.reopenAnnotation gains its first non-undo production caller; reopening a withdrawn annotation stays out of scope (withdraw is absence from the projection, a different act).

### RULING-30 — P — a blank replacement is a deletion, said plainly  `RATIFIED_FROM_OPTIONS`

> A suggested change with a BLANK replacement is a legitimate suggestion to DELETE the paragraph — and it must read as exactly that on every surface ('suggests deleting this paragraph', never an empty preview). Accepting it deletes; the writer knew, because RULING-7's clause ('an empty replacement reads as a deletion') was honoured everywhere.

*basis:* Denver: recommended option accepted — the recommendation followed RULING-7's existing text.

*settles:* GAP-A1. The blank-suggestion claims filed NO_RULING_REACHES are re-file candidates.

### RULING-31 — Q — a resolution's reason is part of the note's history  `RATIFIED_FROM_OPTIONS`

> When a rejected annotation is reopened, the written rejection reason stays visible on the annotation as part of its record ('previously rejected: …'). The writer's authored words stay where they would look for them.

*basis:* Denver, no recommendation offered: chose 'keep it as history' over discard and on-demand.

*settles:* GAP-A3. The RULING-29 pane-Reopen fix must carry this.

### RULING-32 — R — the typing sweep reports at the pause  `RATIFIED_FROM_OPTIONS`

> When deleting a paragraph archives open notes, Maugham says so in a BATCHED, quiet summary at the writing pause (the burst boundary): 'While you edited: 3 notes archived.' Silent in the moment — typing flow is never interrupted — and never a prompt.

*basis:* Denver, no recommendation offered: chose the batched third option over tell-at-the-time and silent-but-recoverable.

*settles:* GAP-A4; gives M5-AN-041 its specified replacement behaviour.

### RULING-33 — S — status and manuscript may not disagree  `RATIFIED_FROM_OPTIONS`

> When concurrent lifecycle acts race (accept on one device, reject on another), the STATUS WINNER ALSO DECIDES THE TEXT: a reject that beats an accept carries the inverse, removing the applied change so the note's status and the manuscript agree. REVISIT at the collaboration milestone — this is the correct version of today's semantics, not the final word on collaborative conflict.

*basis:* Denver verbatim: '1 but also 4 — 1 is the more correct version of what happens now but we may want to revisit.' A composed answer: the semantics ruled, the revisit clause attached (RULING-3's deferral pattern). No recommendation was offered.

*shape:* CONVERGENCE — the first ruling proved by a TLA+ model before it was made

*settles:* GAP-A7 / FM-3: the fix is authorised (models are the acceptance tests); the surface-the-conflict option is explicitly NOT chosen for now.

*revisit when:* the collaboration milestone is scoped

### RULING-34 — J — delete is normalised for annotations too  `RATIFIED_FROM_OPTIONS`

> A deleted (withdrawn) annotation is recoverable later: it lands in a findable Deleted view in the pane and can be restored. RULING-15's single meaning of delete extends to annotations; the op log already retains everything — this is surfacing, not new storage.

*basis:* Denver: recommended option accepted (RULING-15 + RULING-25 coherence).

*settles:* GAP-A2.

### RULING-35 — H — a stale mark and no dead controls  `RATIFIED_FROM_OPTIONS`

> A resolved annotation whose paragraph is deleted stays in the pane as history, gains the STALE mark, and its dead actions are DISABLED with the reason ('its paragraph was deleted'). Nothing renders an enabled control that silently does nothing.

*basis:* Denver: recommended option accepted (RULING-13's vocabulary + RULING-22's conviction of M5-AN-030).

*settles:* GAP-A5; specifies M5-AN-030's fix shape.

### RULING-36 — T — the timeline is the writer's own, under any clock  `RATIFIED_FROM_OPTIONS`

> Time travel is required to be CORRECT under clock skew: the live op list stays sorted across merge-then-append, and a rewind's prefix is always the writer's real timeline — never the peer's text. The fix is cheap and the feature's whole job is showing history faithfully.

*basis:* Denver: recommended option accepted, over accepted-limit-until-collaboration and parked-on-ROI.

*settles:* GAP-A6 + the formal spike's §5.1 (merged). M5-AN-046/047 become clean defects with a specified fix.

### RULING-37 — M — an action that changes nothing costs nothing  `RATIFIED_FROM_OPTIONS`

> A Restore that changes nothing costs the writer nothing: the undo-history clear happens only once the restore is certain to change something, and Restore is not offered when there is nothing to do.

*basis:* Denver: recommended option accepted; the module's own comment conceded 'zero benefit'.

*settles:* GAP-R3. M4-RW-021's VIOLATES filing stands and its fix is specified (joins the RULING-27/28 loop's territory).

### RULING-38 — J — a blocked restore still hands the writer their item  `RATIFIED_FROM_OPTIONS`

> A restore blocked by an occupant restores BESIDE it under a distinguishing name, both visible; nothing is overwritten and nothing is refused. The dedupe-the-filename pattern (RULING-16's reclassification of RULING-10) applied to restore.

*basis:* Denver: recommended option accepted.

*settles:* Trash GAP-1; specifies M3-TR-027's fix.

### RULING-39 — K — retention stays quiet policy; its bugs are still bugs  `RATIFIED_FROM_OPTIONS`

> Op-log history retention through Permanently Delete / Empty Trash / the sweep stays silent policy — it is the work's protection (RULING-24 tier 1) and the current labels are acceptable. No new UI is owed. The invisible-immortal trash entry (meta.json never landed → unlistable, unsweepable, forever) is a plain DEFECT to fix regardless.

*basis:* Denver, no recommendation offered: chose keep-retention-fix-only-the-bugs over honest-label-plus-true-destruction and destroy-history-too.

*settles:* Trash GAP-2. M3-TR-021's sweep-by-list bug is authorised for fixing; M3-TR-049 stands as policy.

### RULING-40 — M — one gesture, one restore  `RATIFIED_FROM_OPTIONS`

> Whatever one delete action removed — one item or fifty — one restore returns, or it refuses and says why. The command is action-scoped and its label follows ('Restore Last Deletion'). It never returns part of a deletion and reports nothing about the rest.

*basis:* Denver, no recommendation offered: chose action-scope over label-is-honest and both-commands.

*settles:* Trash GAP-3; convicts M3-TR-037's single-item scope with a specified replacement.

### RULING-41 — C — the binder and the disk agree after a restore  `RATIFIED_FROM_OPTIONS`

> A restored item that cannot go home lands where the binder says it is, and no folder the writer deleted is silently re-created on disk. The phantom folder that later blocks the folder's own restore is never made.

*basis:* Denver: recommended option accepted.

*settles:* Trash GAP-4; specifies M3-TR-039's fix.

### RULING-42 — A — a restore that returns less says so  `RATIFIED_FROM_OPTIONS`

> A restore that returns less than was deleted names what it could not return, at the moment of the restore. Writer-authored arrangement (order, nesting, titles) counts as something returned or named — RULING-4's report-the-drop shape with the right subject.

*basis:* Denver: recommended option accepted.

*settles:* Trash GAP-5; M3-TR-040's fix specified.

### RULING-43 — G — the writer's Trash shows the writer's deletions  `RATIFIED_FROM_OPTIONS`

> The Trash pane shows things the writer deleted, full stop. Maugham's own safety copies and internal artifacts do not appear there. (And the underlying generalisation stands: a trash entry that cannot restore wiring-included is not offered a Restore that claims success.)

*basis:* Denver: recommended option accepted.

*settles:* Trash GAP-6; M3-TR-042's fix specified.

### RULING-44 — K — trash owes no expiry warning  `RATIFIED_FROM_OPTIONS`

> No warning is owed before trash expires: the writer chose to delete, trash is leeway, and they expect it to empty (RULING-23's own basis, now extended to the warning question). Showing time remaining stays the conceded enhancement RULING-23 already records — nice, not owed.

*basis:* Denver, no recommendation offered: chose no-warning-owed over show-and-warn and clock-pauses-while-absent.

*settles:* Trash GAP-7. M3-TR-019/-020/-050 stand as COMPLIES; the retention contract is closed as ruled-quiet.

### RULING-45 — J — delete has one meaning for every row, including links  `RATIFIED_FROM_OPTIONS`

> A research link is restorable like everything else: deleting it creates a trash entry (its URL and title are trivially storable) and restore returns it. The inequality is dissolved, not labelled — RULING-15's single meaning of delete extended to manifest-only items.

*basis:* Denver, no recommendation offered — and the chosen option only entered the option set after Denver asked for the concrete example (note vs link side by side): the example reframed the question from labelling the inequality to dissolving it. Recorded as a method finding.

*settles:* Trash GAP-8; re-files M3-TR-035's forward-facing half with a specified fix.

### RULING-46 — U — canvas undo is scene-scoped, and says so  `RATIFIED`

> A canvas ⌘Z never reaches into the project's files — promotion's artifact stays when its mark is undone, by design (a canvas undo that deletes research files is its own scary surprise, and the Trash is the artifact's honest disposal route). The LABEL tells the truth about that scope: the undo action is named for the mark it takes back, never for the promotion it does not.

*basis:* Denver, 2026-08-09, discussion of M6-PR-077: 'On 77 I agree with you' — the presented read being fix-the-label-keep-scene-scoped-undo, with the full undo living in the Trash. The inverse of the rewind-label case: there the behaviour was wrong and the label right; here the behaviour is right and the label lied.

*settles:* M6-PR-077: the behaviour RATIFIED, the label convicted and fixed.

### RULING-47 — V — the promotion mark is a bookmark  `RATIFIED`

> A region or card's promotion mark is a BOOKMARK, not a promise: promoting again as New moves it, latest wins, because re-promoting IS the writer deciding what the material now relates to. No warning is owed.

*basis:* Denver verbatim, 2026-08-09: 'latest wins is fine - it's a decision the writer makes. I no longer see this as having that relationship it's now this relationship. Bookmark is a good way of capturing it. If we ever support more complex mapping we could review but for now this would be my call.'

*settles:* M6-PR-040: RATIFIED as ruled — the filing's argue-down path taken by ruling, not by default. GAP-P7's warning sentence dissolves (no warning owed on a ruled writer-decision); GAP-P4 (multi-artifact mapping) carries the revisit.

*revisit when:* multi-artifact contribution mapping is ever supported (GAP-P4)

### RULING-48 — P — research protection tiers (RULING-24's family)  `RATIFIED_FROM_OPTIONS`

> The rewrite-keeps-a-version bridge HOLDS THE LINE: a Rewrite sends the note's (or palette card's) current text to the visible Trash before writing, restorable for the same 30-day window a deletion gets. But it is a bridge, not the standard: real research versioning — at least for text notes, RULING-24's own 'in future we might' clause — is SCHEDULED as the research-protection milestone rather than staying parked in the register's history.

*basis:* Denver, 2026-08-09, structured question GAP-P1: chose 'Bridge now, milestone scheduled' over the recommended 'Bridge is the standard' and over permanent rewrite copies — the bridge is ratified as the line-holder AND the milestone leaves the register for docs/roadmap.md, which the milestone file itself said was Denver's call.

*settles:* GAP-P1. The trash-window bridge (preservePriorVersion / trashPriorVersionText, TrashSubject.priorVersion) is ratified behaviour; register/history/MILESTONE-research-protection.md's content moves to docs/roadmap.md as a scheduled milestone. PRINCIPLE-4 ROI-parking of versioning work lifts when that milestone is scoped.

### RULING-49 — M — never surprise the writer (RULING-22's family)  `RATIFIED_FROM_OPTIONS`

> A rewrite is about the CONTENTS. The promotion sheet withholds the Name field entirely on Rewrite — renaming lives where names live, the research pane. One gesture, one meaning: a rewrite never renames and never reverts a rename.

*basis:* Denver, 2026-08-09, structured question GAP-P2: chose 'Withholding is right' over 'An explicit typed name renames'. Ratifies the shipped behaviour (the sheet's namesTheArtifact gating and the .update arm's never-rename).

*settles:* GAP-P2's live half. The rename-with-rewrite gesture is deliberately absent; a writer who wants both renames in the research pane, then rewrites.

### RULING-50 — W — link identity  `RATIFIED_FROM_OPTIONS`

> Two wiki-links are THE SAME LINK when they point at the same artifact, whatever the label: promotion never adds a link to an artifact the note already points at, under any spelling. Symmetric — a plain [[Target]] blocks a labelled [[Target|label]] and vice versa; a link to a different artifact never blocks.

*basis:* Denver, 2026-08-09, structured question GAP-P3 in two rounds. Round 1 Denver asked back: 'What would happen if it blocked the promotion? What's the user experience?' Presented with the facts — today's reachable direction gives the right outcome by accident, the harmful direction (two links to one artifact) unreachable until something other than the writer's own hand writes labelled links — chose the recommended 'State the rule now': make today's good outcome deliberate, symmetric, and future-proof.

*settles:* GAP-P3 / M6-PR-024 (and the survey's PROMO-D7): the raw asymmetric substring test is now a defect against this identity. The fix is target-based comparison in the duplicate-link check.

### RULING-51 — V — the promotion mark is a bookmark (RULING-47's family)  `RATIFIED_FROM_OPTIONS`

> A contribution record is a FACT, and Maugham holds every one: a card whose words fed two artifacts records both, and spec §6.3's rewrite-guard protects EVERY artifact the card contributed to, not just the latest. The MARK stays a single bookmark — latest wins, RULING-47 — because the mark is the writer's stated relationship; the record is what actually happened, and facts are not overwritten by later facts.

*basis:* Denver, 2026-08-09, structured question GAP-P4 in two rounds. Round 1 Denver asked back: 'I'd need to understand how this happens because that's what tells me the user's intent.' Presented with the mechanics — both contributions are the writer's deliberate placements (the card sits in both regions), and latest-wins disarms the §6.3 guard for every earlier artifact, so the one-card-rewrites-a-six-card-note misoffer returns for note A the moment the card contributes to note B — chose the recommended 'A record is a fact — hold every one'.

*settles:* GAP-P4 (RULING-47's carried revisit, resolved without waiting for multi-artifact mapping): M6-PR-073's single-valued record is a defect; M6-PR-072's clear-first re-record is a defect where the clear discards another artifact's fact; M6-PR-074's surviving picture record COMPLIES. The fix: contributedToItemID becomes multi-valued; a rewrite removes and re-records ITS OWN artifact's fact only.

### RULING-52 — M — the collateral report has two halves (RULING-28's family)  `RATIFIED_FROM_OPTIONS`

> An operation that has already changed the project and then fails says what it did as well as what failed. This completes RULING-28's family: BEFORE states the full set, AFTER confirms it, and a PARTIAL failure names both halves — what landed and what did not. Future operations inherit the duty without a new sitting.

*basis:* Denver, 2026-08-09, structured question GAP-P6: chose the recommended 'Rule it generally' over case-by-case. Promotion's own case was already closed by the validate-first fix (a refused promotion leaves nothing behind), so this ruling is the standing sentence for every future operation.

*settles:* GAP-P6. Filings gain a clause to cite when an operation can fail after its first write: either it validates first so a refusal leaves nothing behind (promotion's route), or its failure report names what it already did (this ruling's route). Silence about a partial change is a defect on sight.

### RULING-53 — J — delete is normalised (RULING-15's family)  `RATIFIED_FROM_OPTIONS`

> The inbox trash keeps the project trash's retention: a trashed capture ages out on the same 30-day clock, swept with the same quietness RULING-39 ratified — one retention story for every trash surface. The sweep disposes the ASSET and hides the row; the manifest row itself stays .trashed (a new status value would decode as .new on older phone builds and resurrect the capture — ADR 0015's own tolerance turned against it).

*basis:* Denver, 2026-08-09, structured question GAP-I1: chose the recommended 'Parity — 30-day sweep' over route-to-project-trash and keep-forever, with the mechanics (status-flip trash, unbounded audio accumulation, two trashes answering one question differently) presented first.

*settles:* GAP-I1 (recorded in M8-IN-011's filing as the retention divergence). The two-trash divergence closes: both age out at 30 days.

### RULING-54 — B — never misrepresent (RULING-7's family)  `RATIFIED_FROM_OPTIONS`

> A reader of a durable store treats an unreadable-yet-present file as an ERROR to surface, never as empty; lenient reads are opt-in with a recorded reason. RULING-7's 'unreadable is never presented as empty' becomes the DEFAULT contract for storage readers, not a per-surface conviction. The four existing lenient consumers of JSONLAppendStore.load (op log, checkpoints, publications, tasks) get a scheduled sweep, OP LOG FIRST — an unreadable op-log file at document load presenting the manuscript as shorter than it is would be the forbidden shape at the highest-stakes surface.

*basis:* Denver, 2026-08-09, structured question GAP-I2: chose the recommended 'Rule it generally' over op-log-only-now and case-by-case.

*settles:* GAP-I2 (the Inbox filings' shared-layer residual). The inbox's loadStrict fix (6955c2d8) becomes the pattern; the sweep of the four consumers is queued in START-HERE, op log first, each with its own characterised loop because the surfacing UX differs per consumer.

## The enforcement gradient — how each ruling is held

prose → test → tripwire → type → model. A prose-only ruling with LIVE reach is a
promotion candidate. (Source: `_meta.enforcement`; metadata, outside the ruling hashes.)

- **RULING-1** `test` — entry-point refusal pins (RULING-5 family); breadth prose
- **RULING-2** `prose` — parse-path tolerance — no mechanism wanted
- **RULING-3** `deferred` — multilingual scope undecided
- **RULING-4** `test` — trash restore/validate pins; op-log append-only pins
- **RULING-5** `type+test` — SuggestionSplice.Outcome makes the violation unrepresentable; pins on Mac/phone/core
- **RULING-6** `prose` — surface conventions
- **RULING-7** `test` — unreadable-note, emptyTrash honesty, decline-notice pins
- **RULING-8** `prose` — meta-rule; enforced case-by-case through filings
- **RULING-9** `prose` — ratified surface
- **RULING-10** `test` — dedupe-the-filename pins
- **RULING-11** `test` — MarkdownDisplayFilter round-trip property tests
- **RULING-12** `deferred` — needs re-ruling on the corrected basis
- **RULING-13** `test` — stale-mark pins (ShingleMatcher / annotations)
- **RULING-14** `prose` — ingestion boundary
- **RULING-15** `type+test` — typed mover + TrashSubject.captureAsset; M3-TR-059/060 pins
- **RULING-16** `prose` — process discipline
- **RULING-17** `prose` — ratified behaviour
- **RULING-18** `prose` — attribution boundary
- **RULING-19** `prose` — layering principle; applied in filings
- **RULING-20** `prose` — root
- **RULING-21** `prose` — scope clause on R7
- **RULING-22** `test` — many pins across trash/rewind/annotations
- **RULING-23** `test` — sweep/destroy pins
- **RULING-24** `test` — append-only + derive-exact pins; tier boundaries prose
- **RULING-25** `test` — RewindTravelReopenTests + characterisation
- **RULING-26** `test` — accepted-status travel pins
- **RULING-27** `test` — nearest-resolution pins
- **RULING-28** `test` — RewindImpactTests (preview+toast from one mirror)
- **RULING-29** `test` — caller census + undoable-reopen pins
- **RULING-30** `prose` — RULED, NOT YET RE-FILED: the presentation duty (blank reads as deletion everywhere) is unverified against the pane — residual in PLAN
- **RULING-31** `test` — reason-history pin
- **RULING-32** `test` — DocumentNoticeTests sweep-summary pins
- **RULING-33** `model+test` — AnnotationRace_Fixed config green + AnnotationConvergenceTests
- **RULING-34** `test` — withdrawn-listed-and-restorable pin
- **RULING-35** `test` — AnnotationRowPolicy pin
- **RULING-36** `test` — sorted-mirror pin
- **RULING-37** `test` — no-op-costs-nothing pins
- **RULING-38** `test` — restore-beside pins
- **RULING-39** `test` — directory-sweep pins
- **RULING-40** `test` — gesture-scoped restore pins
- **RULING-41** `test` — disk-matches-binder pin
- **RULING-42** `test` — TrashRestoreReport pin
- **RULING-43** `type+test` — TrashSubject.internalArtifact + refusal pins
- **RULING-44** `prose` — ruled-quiet: no warning owed — nothing to enforce
- **RULING-45** `type+test` — carriesFile:false entries + link round-trip pins

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
