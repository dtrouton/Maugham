# ADR 0028 — Maugham goes outbound: spawning `claude -p`, and what still holds when it does

**Date:** 2026-08-05 · **Status:** Accepted · **Milestone:** m2-author-compiler (branch `feat/m2-compiler-2026-08-04`)

## Context

Every AI path Maugham has ever had ran **inbound**. Claude Desktop (or Claude Code)
connects to a Unix socket Maugham listens on; Maugham is the server, the writer's other
app is the client, and Maugham initiates nothing ([ADR 0003](0003-mcp-live-only-unix-socket.md),
[ADR 0004](0004-mcp-foundation-scope.md), [ADR 0020](0020-dev-only-test-mcp.md)). The
socket is live-only: no daemon, no launch agent, nothing running when the app isn't. That
shape is a large part of why `docs/constitution.md` must #1's privacy clause — *"nothing
leaves the machine without the writer's explicit intent; AI access is local, live-only,
and switched off with one toggle"* — has been easy to keep. Maugham never had a way to
start a conversation.

M2's compiler inverts it. Pressing ⌘R makes Maugham spawn `claude -p` as a child process,
hand it the writer's changed paragraphs and their intent statement, and read what comes
back. The subprocess talks to Anthropic's API over the network, on the writer's own
account. **This is the first outbound act in the product's history**, and it deserves its
own record rather than a line in the milestone's design, because everything that makes it
acceptable is a property of the invocation that a later refactor could quietly drop.

Two principles are directly in play — must #1's privacy clause above, and must-not #4,
**"No cloud required"** (*position*) — plus must-not #1, **"AI is never the author"**
(*identity*), which constrains what the spawned process is allowed to reach.

## Decision

### 1. The one toggle governs the outbound direction too — the spawn *and* the session's life.

`UserPreferences.mcpEnabled` is the toggle the constitution's privacy clause names. It has
always refused inbound requests per-request (`Maugham/MCP/MCPServer.swift`). It now also:

- **refuses the spawn.** `ClaudeCLISession` re-reads the toggle before *every* spawn, so
  the refusal is enforced at the runner, not at the UI. The menu item stays enabled so the
  explanation is reachable rather than greyed into silence (spec §8).
- **kills a session that is already warm.** A writer who turns Claude off must not have
  one more run answered by a process that was spawned while it was on.

The lifetime rules, which are the reason the outbound surface is bounded rather than
ambient:

- Entering the Author persona never starts a session. Only a run does.
- It dies on the toggle going off, on window/project close, and on app quit.
- It dies quietly after ~10 minutes without a run.
- Death mid-run fails that run visibly, once. The next keystroke starts a fresh session,
  with no state to repair.

**Read the enforcing site for each rule off `Maugham/Compiler/AREA.md`'s table rather than
from a list here** — a prose copy of a wiring table drifts, and this one is spread across
`CompilerOrchestrator`, `CompilerRunModifier`, `ProjectWindow` and `ClaudeCLISession`,
with one rule enforced in two of them at once.

**The sharp edge, recorded because the type cannot defend itself.**
`ClaudeCLISession.deinit` is nonisolated and cannot touch main-actor state, and
deallocating a `Process` neither signals nor reaps its child. A session merely *released*
therefore leaves a live, billing, API-calling `claude` running for as long as it survives
its closed stdin. Every teardown path has to reach `shutdown()` explicitly. A leaked
process is not only a cost bug: it is a process holding the writer's manuscript context
that outlived the toggle they used to stop it, which is the privacy clause failing
quietly. **If you add a fifth way for a window or a persona to go away, it owns a call.**

### 2. Confinement is TWO flags, and the census guards only the stronger half.

This is the milestone's most expensive lesson and the main reason this ADR exists.

The spawned Claude is confined by:

| Flag | What it actually does |
|---|---|
| `--allowedTools <enumerated list>` | **Pre-approves** the tools it names so they skip the permission prompt. It removes nothing. |
| `--tools ""` | **Empties the built-in tool set.** This is what makes "no file access" true. |
| `--strict-mcp-config` | Keeps the writer's *personal* MCP servers out of a Maugham-spawned run. |
| `--mcp-config <per-session file>` | Exactly Maugham's own server, through the bridge binary the setup sheet installs. |

Plus `Process.currentDirectoryURL`, set to the session's own config directory as defence
in depth — an unset cwd is inherited from Maugham, which for a launched `.app` is `/` and
for a debug run is the developer's checkout.

**The trap:** under `-p`, tools that would prompt (Bash, Edit, Write) are in fact
unreachable, so an enumerated `--allowedTools` list *looks* like a sandbox. But the
built-in read tools — Read, Glob, Grep — never prompt inside the working directory. An
allowlist on its own therefore leaves the spawned model free to read any file it can
reach: the raw `.md` as truth (tripwire 20's exact shape, since the `.md` lags the op log
by a debounce), or a journal, or `~/.ssh`, and ship it to the API on the writer's bill.

This shipped through the whole implementation and was caught by the whole-branch review
(`.superpowers/sdd/2026-08-04-m2-compiler-loop/final-review.md`, C1), which proved it
live in both directions against `claude` 2.1.221: the same invocation returned a scratch
file's exact contents without `--tools ""` and answered "CANNOT" with it. Fixed in
`a688b381`, and re-verified against 2.1.222 on 2026-08-05, including separately that
`--tools ""` does *not* disturb the MCP tools — those arrive through `--mcp-config`, not
from the built-in set.

**Why it was invisible, recorded so it is never re-derived:** the spec, this milestone's
own ADR obligation, `Maugham/Compiler/AREA.md` and the `CLAUDE.md` compiler row all
asserted "nothing outside MCP, no Bash, no file access" — and `docs/guide/compiler.md`
told the writer their compiler "reads your manuscript". None of it was enforced.
`CompilerAllowlistTests` was a real census with planted offenders, but it guarded the
*contents of the list* — the strong half — while the weak half was what the flag means to
the CLI. The Task 0 spike verified the flags **compose**; nobody verified they
**confine**. One task reviewed the list, another reviewed the spawn, and the semantics
between them had no owner.

**The rule that generalises out of it: an enumerated allowlist is not a sandbox.** Any
future outbound invocation must state, per flag, whether it *removes* a capability or
merely *pre-approves* one, and prove the removal against the live tool rather than the
documentation. `ClaudeCLISessionTests.test_spawnArgumentsMatchTheSpike` now asserts both
flags (parsing argv with `components` rather than `split`, because the flag's value is the
empty string), and `ClaudeCLISession.arguments` is the single place to read the real
invocation.

### 3. The allowlist is read-only, and nothing in it — or in the catalogue — can write a statement.

The MCP membrane has write tools (`add_note`, `add_canvas_scraps`, `promote_inbox_entry`,
`move_research_item`, `write_translation`, the publish writes). The compiler's Claude gets
none of them. `CompilerAllowlistTests` asserts that every entry resolves to a catalogue
tool, that no entry is a write, and that no statement-writing tool exists in the allowlist
**or the catalogue** — each with a planted-offender companion so none of the assertions
can be quietly unfalsifiable.

The statement clause is the one worth arguing, because it is not merely tidy. The compiler
is judged against the writer's declared intent, and it can say the intent looks stale
(spec §5.1). **A model that could also write that intent could move the standard until
nothing it produced was ever flagged again.** That is must-not #1's shape one level up
from the manuscript: not AI authoring the prose, but AI authoring the yardstick the prose
is measured by. The only route from a diagnostic into a statement is
`IntentAppendPerformer`, whose input is a sentence the writer typed
([ADR 0027](0027-the-compiler-and-the-editor-boundary.md) §1).

`preview_compile` was removed from the allowlist during implementation (`7be99c98`) for
the same class of reason: it is nominally a read, and it spawns tectonic.

### 4. A warm session, with `--resume` pre-authorized and not built.

**Decision: one long-lived `claude -p` process per orchestrator, spawned lazily on the
first run, one stream-json user message down stdin per subsequent run.** The Task 0 spike
(`docs/superpowers/notes/2026-08-04-m2-spike.md`) measured it on the dev machine against
`claude` 2.1.221:

- Warm multi-turn, one process, two turns: **3.0 s** cold (including spawn), **1.3 s**
  warm, same `session_id`.
- Fully composed — the same shape plus `--mcp-config`, `--strict-mcp-config`,
  `--allowedTools` and `--model haiku`: turn 1 **called a real Maugham tool through the
  bridge** in 8.0 s; warm turn 2 in 1.5 s.
- Socket concurrency: `MCPServer.acceptLoop` spawns a detached task per connection and
  re-accepts immediately; half-duplex is per-connection only. Verified live with the
  compiler's client and a Claude Desktop connection open simultaneously — **two clients,
  both served.** The compiler does not evict the writer's other Claude.

This is what buys the spec's 2–4 s first-note budget, and it is why the session exists at
all: a per-run process pays the 3 s spawn every time.

**The `--resume` fallback stays pre-authorized and is NOT implemented.** Per-run
`claude -p --resume <session-id>` gives the same context-reuse semantics with simpler
process management, and the `CompilerRunner` seam makes it a swap: the orchestrator holds
a protocol and reads only `send(...)` and `sessionEpoch`. Note what would have to move
with it — `sessionEpoch` is what lets an unchanged intent be elided from a message, so a
per-run process must still answer "is this the same context that read the intent last
time"; for `--resume` that is the resumed session id, not the process.
`ClaudeCLISession.arguments` is the place to check whether it is still unbuilt, not this
paragraph.

### 5. Runs bill the writer's own Claude login, and must-not #4 still holds.

Maugham ships no API key, holds no account, and operates no server. The compiler locates
whatever `claude` the writer already installed, by PATH probe, and that CLI uses the
writer's own login. The spike measured ~$0.01–0.02 per trivial Haiku turn, and
`total_cost_usd` arrives on every result event — **surfaced nowhere**, deliberately, since
a per-run price tag on a feature designed to feel free to reach for is exactly the pushed
metric must #2 excludes.

Against must-not #4's stated bar (*"the offline core remains fully functional, the
cloud-dependent capability is additive and opt-in, and manuscript content never rests on
infrastructure Maugham controls"*):

- **The offline core is untouched.** Writing, structuring, research, safety, undo, rewind,
  publishing to PDF and EPUB all work with the toggle off and no network. The compiler is
  a capability the writer opts into by pressing a key, in a persona they chose, with an
  app they installed and an account they hold.
- **Nothing rests anywhere.** A run is a request and a response. Diagnostics land in a
  per-device sidecar on the writer's own disk, and losing that file costs nothing durable.
- **Maugham controls no infrastructure**, so there is nothing for manuscript content to
  rest *on*.

**The honest edge, stated plainly rather than buried:** what goes over the wire *is*
manuscript text. The delta's paragraphs and the writer's intent statement are the payload;
that is the whole point of the feature. must #1's privacy clause is satisfied by
*"explicit intent"* — a keystroke, per run, with a toggle that refuses the spawn — and not
by any claim that the text stays local. **The falsifiable version: if manuscript text ever
leaves the machine without a writer keystroke immediately preceding it — a warm-up turn, a
prefetch, a background run, a telemetry ping — this decision was violated**, regardless of
how small or how helpful the leak is.

## Consequences

- Maugham is now a process parent as well as a socket server. The teardown discipline in
  §1 is load-bearing in a way no test can fully cover: a leaked child is invisible to the
  suite and visible on the writer's bill.
- The two-flag confinement rule (§2) is the standing precedent for any future outbound
  invocation. "It composed in the spike" is not evidence of confinement.
- The compiler is a peer MCP *client* of Maugham's own server, alongside the writer's
  Claude Desktop. The catalogue did not grow for M2 — no new tool in either direction —
  and the socket's per-connection concurrency is now load-bearing rather than incidental.
- The read-only allowlist plus the statement prohibition (§3) mean the compiler cannot
  author the manuscript *or* the yardstick. Both are enforced by census with planted
  offenders rather than by convention.
- `docs/guide/compiler.md` and `Maugham/Compiler/AREA.md` describe a confinement that is
  now true. They were describing it before it was.

## References

- `docs/constitution.md` must #1 (the words are private — *"nothing leaves the machine
  without the writer's explicit intent; AI access is local, live-only, and switched off
  with one toggle"*), must-not #4 ("No cloud required" — §5 argues against its stated
  bar), must-not #1 ("AI is never the author" — §3's statement prohibition), must #2 ("Get
  out of the way" — why cost is surfaced nowhere)
- Spec: `docs/superpowers/specs/2026-08-04-m2-author-compiler-design.md` §3.4, §3.5, §8,
  §9.2, §10
- Spike: `docs/superpowers/notes/2026-08-04-m2-spike.md` (the measurements in §4)
- Whole-branch review: `.superpowers/sdd/2026-08-04-m2-compiler-loop/final-review.md` C1
  (the confinement gap, proved live; fixed in `a688b381`)
- [ADR 0003](0003-mcp-live-only-unix-socket.md) — the inbound transport this inverts
- [ADR 0027](0027-the-compiler-and-the-editor-boundary.md) — the other half of this
  milestone's constitutional accounting: where the answer is allowed to appear
- `Maugham/Compiler/AREA.md` — the lifetime table, and the shutdown contract in full
