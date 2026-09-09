# The reader's own session — liveness, identity, and a complete briefing

**Date:** 2026-09-09 · **Status:** built 2026-09-09 on branch `claude/readers-own-session-2026-09-09`; effort table deferred to the evals spec
**Session:** "first reader timeouts on a 450-paragraph screenplay"

*Brainstormed with Denver 2026-09-09, out of four checks on one screenplay
that all died at the 300 s per-turn budget. Every number below is read off
the spawned CLI's own transcripts (`~/.claude/projects/…-T-maugham-compiler/`)
and the MCP bridge's logs (`~/Library/Caches/claude-cli-nodejs/…/mcp-logs-maugham/`),
not estimated. Amends the compiler's second-draft spec where it describes the
per-turn budget and the session's spawn arguments; amends the references-shelf
design's §2 (the briefing lists pins by title only). Everything else stands.*

## 1. The problem, measured

Denver's first reader reads a screenplay of ~450 paragraphs (under 6,000
words — a screenplay is many short paragraphs). Four checks on it in one
morning, all on Opus, all through Author's ⌘R:

| time | paragraphs briefed | before the first tool call | after the tools | outcome |
|---|---|---|---|---|
| 08:53 | 457 | 255 s of thinking, 17,250 output tokens | three `read_document`s (one failed: a web link), thinking | killed at 300 s |
| 09:30 | 457 | 180 s, 12,588 tokens | same three reads, thinking | killed at 300 s |
| 09:36 | 247 | 22 s | four calls, two answering `{"exists":false}`, then 273 s with nothing written | killed at 300 s |
| 09:42 | 91 | 8 s | six calls, four answering nothing, then 129 s of thinking (12,504 tokens), 54 s writing | **finished at 202 s** |

No report section ever began in the three that died. On 6 September a
26-paragraph Sonnet check finished in 275 s, with four thinking phases. Deltas
have been living at the edge of the budget; the screenplay pushed a whole-piece
read over it.

Three causes, each its own section below:

1. **The budget kills a model that is visibly working.** The session already
   receives every stream line, including thinking deltas and the CLI's own
   `system/thinking_tokens` progress events, and classifies them as
   `.ignore`. A model streaming reasoning at ~68 tokens/s on Opus is the
   opposite of hung, and the timer kills it anyway — throwing away the 250 s it
   just paid for. This is the failure the 2026-08-18 ruling named when it
   raised 120 to 300: a budget measured on the wrong run.
2. **The session is a coding agent carrying the writer's global settings.**
   The spawned CLI loads the full Claude Code system prompt (fifteen blocks,
   10.6k chars — "software engineering tasks", the memory directory, Agent-tool
   rules), then Denver's user-level SessionStart hook injecting the superpowers
   skill text (3.3k chars, "You MUST invoke skills"), then all sixty MCP tool
   schemas. The reader's preamble is the LAST 1.2k chars of a ~23k-token prefix.
   It also inherits `effortLevel: high` from `~/.claude/settings.json`, which is
   why a first reader "reporting what happened in her" deliberates for 17k
   tokens. On 6 September a check called `get_help` with topic `skills` — the
   hook talking.
3. **The briefing sends the model fetching.** Pinned references are listed by
   title with "fetch full contents with `read_document`"; the 09:36 briefing
   listed 42 of them and the model read two. The notes it did fetch were 713,
   795 and 2,273 characters. In the two 457-paragraph runs the model thought
   over the whole piece BEFORE deciding to fetch, then had to think over it
   again after — the fetch-on-demand shape forces two thinking phases. It also
   spends calls discovering absences: `read_craft_intent` and `read_lessons`
   answered `{"exists":false}` six times across two runs, and one pin was
   advertised for `read_document` when it is a web link.

Tools are not the wall-clock cost — every MCP call completed in 3–8 ms.
Thinking is. But the tool shape multiplies the thinking.

**Not the cause:** the paragraph count as input (46k chars ≈ 12k tokens of
briefing; prefill is seconds), the op-log performance step parked before P2
(milliseconds on a cold open), or the CLI's MCP transport.

## 2. Liveness replaces the per-turn kill

`ClaudeCLISession` keeps two numbers instead of one:

- **`silenceTimeout` — 180 s.** Every line the child writes to stdout, of ANY
  type — a `stream_event` carrying a text, thinking or signature delta, a
  `system/thinking_tokens` progress event, an `assistant` message, a
  `rate_limit_event`, a line that is not JSON — resets it. The classifier's
  `.ignore` verdict is about what a line MEANS for the answer; liveness is
  about whether the child is still speaking, and those are different questions
  answered at different points in `receive(line:)`. Silence is what "genuinely
  hung" means: a CLI that has stopped writing.
- **`runTimeout` — the ceiling, 1,200 s (20 min).** One constant for every
  session type. `translationRunTimeout` (900 s) is deleted and the two
  factories that passed it pass nothing; the test that asserted they did is
  retired with it. The ceiling is safe above `idleTimeout` (600 s) for the
  reason the 900 s constant already recorded: `idleDidExpire` refuses while a
  turn is in flight.

Why 180 s: a retry backoff on an overloaded API can reach tens of seconds per
attempt, and the gap between a tool result and the next request's first byte
is a few seconds; 180 s covers both with room. Why 1,200 s: the 457-paragraph
read would have wanted roughly eight to ten minutes at Opus/high; twenty is
the bound that still stops a runaway session from billing indefinitely.

**The failure says which.** `CompilerRunFailure.timedOut` gains a typed
reason: `.silence(after: TimeInterval)` or `.ceiling(TimeInterval)`, plus the
thinking-token estimate the session last saw. `RoundNarrative.failureCopy`
speaks it in both homes (Author's pane, Review's cockpit): *"Claude went quiet
for 3 minutes and was stopped"* / *"The read passed 20 minutes and was stopped
— 31,000 tokens of thinking so far."* The marker and the briefing hash stay
where they were, as today.

`DeclaredWorldDeriver`'s one-shot keeps its own 120 s deadline; it is a
different runner with a short, bounded answer and was not implicated.

## 3. The session is the reader's own

`ClaudeCLISession.arguments` changes in three places, all verified live on
`claude` 2.1.266 (2026-09-09, one Haiku call, OAuth login, in the scratchpad):

- **`--setting-sources ""`.** No user, project or local settings file is read:
  no hooks, no plugins' SessionStart injection, no CLAUDE.md auto-discovery,
  no inherited `effortLevel`. The probe's transcript carried no hook
  attachment at all. MCP servers still come from `--mcp-config`, permissions
  from `--allowedTools`, the built-ins are still emptied by `--tools ""`, and
  OAuth still authenticated. **`--bare` was considered and rejected**: its help
  text says Anthropic auth is then "strictly `ANTHROPIC_API_KEY` or
  `apiKeyHelper` … OAuth and keychain are never read", which would log the
  compiler out on every writer who signs in the ordinary way.
- **`--system-prompt <preamble>` replaces `--append-system-prompt`.** Each
  orchestrator's `sessionSystemPreamble` — the compiler's, the designer's, the
  translator's, `ColdCall`'s — becomes the WHOLE system prompt. The probe's
  `prompt_snapshot` was exactly the 41 characters passed. Each preamble is
  read once in the plan for whether it stands alone as an identity (they
  already open "You are …"); nothing from the coding-agent prompt is carried
  over on purpose.
- **`--effort <level>` explicit — and, in this milestone, unchanged.**
  Ignoring the settings files also drops the `effortLevel: high` every run
  inherits today, so the CLI would fall back to its own default; the argument
  is therefore passed explicitly at every spawn. `ClaudeCLISession.Effort`
  is an enum over the CLI's accepted set (`low`, `medium`, `high`, `xhigh`,
  `max`; an unknown value is ignored by the CLI with a warning, so the set is
  pinned by a test). **Every session kind passes `high`** — the value Denver's
  runs have carried all along — so this milestone changes the session's
  identity, its liveness and its briefing and NOT how hard the model thinks.
  One variable at a time.

  **The per-kind table is decided by evals, not here** (Denver, 2026-09-09:
  *"the effort thing I think we need to tie to developing a set of evals for
  review, translation etc. Without tests we're just guessing"*). What this
  milestone contributes to that decision is the instrumentation: effort is
  recorded on every run beside its timing (§5), so an eval can read what a
  run was asked for and what it cost. The evals are their own spec and their
  own milestone; the table moves when they say so. No writer-facing dial in
  the meantime — the depth menu chooses the model and stays what it is.

`DeclaredWorldDeriver` spawns the same way (`--setting-sources ""`,
`--system-prompt`, `--effort high`) because it is the same shape of process
and inherits the same hook today.

**Enforced:** `TripwireGrepTests` gains a census — `--append-system-prompt`
appears nowhere under `Maugham/`, and every production `claude` spawn site
(`ClaudeCLISession.arguments`, `DeclaredWorldDeriver`) emits
`--setting-sources` — with a planted-offender control for each direction.
`ClaudeCLISessionTests.test_spawnArgumentsMatchTheSpike` and its bridged/sealed
sibling pin the three new arguments.

## 4. The briefing is complete

Three changes to `CompilerPrompt` and the pinned-listing builder in
`CompilerEnvironment+Project.swift`:

1. **Small pinned notes travel inline.** A `.research` pin whose asset is a
   text document under `inlineBodyCap` (4,000 chars) carries its body in the
   listing under its own title line; over the cap, the line says "fetch full
   contents with `read_document` (N words)". A whole briefing inlines at most
   `inlineBudget` (40,000 chars) in shelf order; past the budget, pins revert
   to fetch lines. A `.link` asset is listed as *"web link, not readable"*
   with its URL, never with a tool name; image, PDF and audio assets stay
   title-only as today; palette, scrap and photo pins are unchanged. The
   `pinnedListingCap` of 40 pins stays.
2. **The listing joins the hashed unit.** The pinned listing (bodies included)
   is folded into `briefingHashInput`, so a warm session is not re-sent an
   unchanged shelf on every ⌘R — the same treatment the essay, the declared
   world, the bible slice and the lessons ledger already get. This is what
   makes inlining affordable on a 42-note shelf: it is paid once per session
   and again only when the shelf changes.
3. **Absences are stated, and the message says it is the whole read.** When
   no essay is briefed: *"No craft intent has been declared for this piece or
   its project."* When the reader is a first reader: *"You are deliberately
   not briefed on the writer's lessons ledger or their process."* In the tail,
   for every kind: *"Everything this read is judged against is in this
   message. A pinned note that is not inlined can be fetched; a statement or
   ledger that is not listed here does not exist — do not go looking for it,
   and do not read the outline or other documents."* `search_text` and
   `find_references` remain available to a round for a continuity question
   that needs them; the sentence forbids exploring, not checking.

## 5. The run knows how long it took

The CLI's `result` event carries `duration_ms`, `duration_api_ms`, `ttft_ms`,
`num_turns`, `usage.output_tokens`, `usage.output_tokens_details.thinking_tokens`
and `total_cost_usd`; its `system/thinking_tokens` events carry
`estimated_tokens` while a turn is live (both observed 2026-09-09).

- **`RunTiming`** (new, `Maugham/Compiler/`): elapsed, time to first stream
  line (Maugham's own clock, since `ttft_ms` is the CLI's), turns, output
  tokens, thinking tokens, cost, model, effort. `ClaudeCLISession` builds it
  per turn and exposes `lastTurnTiming`; `CompilerRunner` gains that as a
  defaulted optional so the fakes do not change. The orchestrator copies it
  onto `CompilerRun.timing: RunTiming?` (optional — a legacy sidecar loads
  without it; tripwire 11).
- **While a run is live**, the session publishes the thinking-token estimate
  through the existing partial channel's sibling, and the Checking strip in
  both homes draws elapsed and progress: *"Checking… 2m 10s · thinking
  (12k tokens)"*. This is the writer's first visible sign in five minutes that
  anything is happening, and `RoundNarrative.checkingCopy` stays the one
  author of the sentence.
- **Afterwards**, the pane's *"Last checked 3m ago · 457 new ¶"* line gains
  *"· read in 4m 12s"*, with a help tooltip carrying first token, turns,
  thinking tokens, effort, model and cost; the round cockpit mirrors the line.
  The Statistics window is NOT touched — this is a run's property, not the
  writer's process.

## 6. Out of scope

- Chunking a translate or fix leg into several bounded turns — its own plan,
  already recorded in the roadmap.
- A writer-facing effort dial, deriving effort from the depth menu, or any
  per-kind effort value: the evals milestone decides those.
- `MAX_THINKING_TOKENS`; effort is the API's own dial and the CLI's.
- Trimming the sixty MCP tool schemas out of the prefix (the CLI's, and cached).
- Chunking a check over a long piece: a reader reads the whole thing.

## 7. Testing

- `ClaudeCLISessionTests`: a fake CLI that streams noise lines past the old
  300 s budget is NOT killed (the silence timer resets; the ceiling is far);
  one that stops writing IS killed at the silence budget with `.silence`; one
  that streams forever is killed at the ceiling with `.ceiling`; the spawn
  argument pins for `--setting-sources ""`, `--system-prompt`, `--effort`, and
  the absence of `--append-system-prompt`; `Effort`'s raw values are the
  CLI's five; `lastTurnTiming` is built from a fake `result` line carrying
  the real event's shape (captured verbatim, as the stream constants are).
- `CompilerPromptTests`: an inlined body under the cap, the fetch line over it
  with a word count, the budget cut-off in shelf order, the web-link line, the
  three absence sentences, and the listing's presence in the hash (a changed
  body changes the hash; an unchanged shelf does not re-embed).
- `RoundNarrativeTests`: the two stall sentences and the live checking copy.
- `DiagnosticsPaneTests` / `ReviewRoundCockpitTests`: the elapsed line and
  its tooltip over a run with timing; a legacy run without timing draws the
  old line unchanged.
- `TripwireGrepTests`: the two spawn-site censuses with planted offenders.
- Every orchestrator test that asserted `translationRunTimeout` is retired or
  re-pointed at the one ceiling.
- **Smoke (Denver):** the 457-paragraph screenplay check finishes, the strip
  shows progress while it runs, and the pane's line reports the elapsed time.
  A second ⌘R on the same warm session with an unchanged shelf is briefed
  without the bodies (visible in the compiler transcript's message length).

## 8. Gates and shape

One plan, at most ten tasks, subagent-driven; opus on the session and prompt
changes, haiku reviewers. Task 1 is the session's spawn arguments and
liveness, built first so the later tasks are written against real code
(default workflow rule 11). Every task green on `./scripts/test.sh`; the full
gate and a Release build before merge. Merge to local `main` unpushed; Denver
decides the release cadence.
