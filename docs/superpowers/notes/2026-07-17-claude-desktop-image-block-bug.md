# Claude Desktop drops MCP image content blocks from tool results (2026-07-17)

Evidence dossier for an upstream report to Anthropic. Conclusion: **Claude
Desktop-side bug** — Maugham and its bridge are exonerated at every layer.

## Symptom

In Claude Desktop, every `maugham:read_document` call against a `kind=image`
research asset returns what the model describes as "an image block with no
content I can resolve". Text tools in the same session work. Failure is
**size-independent** (reproduced at 256, 800, 1350, 1400, 1600, 2048, 2400 px
requests; payloads 39KB–620KB, all far under the 1MB MCP cap) and identical
for whole-image and `region`-crop paths. The workflow previously worked
(notebook pages transcribed successfully in an earlier session); Maugham's
image code path did not change in between — Claude Desktop auto-updates.

## Layer-by-layer discrimination (all on 2026-07-17, Maugham 0.22.0)

1. **Server, raw Unix-socket probe** (python, no bridge): `tools/call
   read_document` for the exact failing asset/params (`res-b4e1648a`,
   `max_dimension 1350`) → well-formed envelope, `content[0]` =
   `{type:"image", mimeType:"image/jpeg", data:<620,256 base64 chars>}` →
   decodes to a 465,190-byte JPEG, valid SOI/EOI, visually verified legible.
2. **stdio bridge** (`maugham-mcp`, the exact binary Claude Desktop spawns,
   driven over stdin/stdout exactly as Desktop does): byte-identical result.
3. **Different MCP client, same server code**: Claude Code session connected
   to the Maugham dev build with a copy of the same project open; the model
   (Claude) called `read_document` on the same asset at 1350px and **received
   and read the image** (transcribable handwriting).
4. **Claude Desktop**: same block shape → its model reports no image, at
   every size, including a 39KB payload at 256px.

Other ruled-out hypotheses: protocol-version mismatch (Maugham echoes the
client's `protocolVersion` in `initialize`); mixed text+image vs image-only
envelopes (both fail in Desktop); stale bridge binary (user config repointed
to the installed `/Applications` bridge, verified; failure persists).

## What Desktop's model reports from inside

(From the in-Desktop Claude's own bug report.) Envelope arrives well-formed —
resize-fallback *text* blocks in the same `content` array are visible to the
model ("cap → 1350px"), the *image* block is present but carries nothing the
model can use. This localizes the drop between Desktop's MCP layer and the
model's context: the client receives the block (text siblings prove envelope
delivery) and strips or fails to attach the image payload.

## Suggested repro for Anthropic

Any MCP stdio server returning
`{"content":[{"type":"image","data":"<base64 png/jpeg>","mimeType":"image/jpeg"}]}`
from `tools/call`; ask the model to describe the image. Compare with the same
server under Claude Code (works).

## Workaround (Maugham users)

Until fixed: run image-transcription sessions through Claude Code with the
Maugham MCP connected (`claude mcp add maugham
/Applications/Maugham.app/Contents/MacOS/maugham-mcp`) — image blocks reach
the model there. No Maugham-side change is warranted; the server emits
spec-correct blocks that other clients consume.
