# Imprints and bilingual editions — design

**Date:** 2026-08-27 · **Status:** approved by Denver in conversation ("go") section by section; unbuilt. Three plans (§10), the first to be built before the second is written (CLAUDE.md rule 11).
**Origin:** a feature request from Claude Desktop ("Editions", two drafts) after the first Serbian preview of the Playlist screenplay piece — the same session that shipped v0.32.1 (translated Fountain structure; hidden-flag-safe scans). The request's "Gap A" (a differently-shaped standalone inside a collection project) and "Gap B" (one piece in two languages in one file) are both in scope: Denver ruled the second was the point of the first.
**Amends:** `2026-07-22-translation-layer` (edition identity `(version, language, format)` gains an imprint axis and a joined-language spelling); `docs/adr/0013` (a second top-level template beside `template.tex`); `EmissionContract` (three new entries, one deliberate byte-gate move).
**Constitution:** *the words are safe* is untouched — nothing here writes a manuscript, and the paragraph anchors live in the compiled artifact, never in the `.md`/`.fountain` (ADR 0019 stands). Must #3 (*delight*: "an export looks like a printout instead of a book") is the reason the bilingual file is a feature and not a stitch.

## 1. What is being built

An **imprint** is a named publishing configuration inside one project — its own template, rendered set, metadata, cover, filename and version counter — chosen at compile time. It lets the Playlist collection ship its book *and* a "Good Luck Babe" special: one piece, 16:9 landscape, a bespoke template, its own title, at its own version, drawing on the same manuscript and the same translation layer. A compile may also name **several languages**, and then the artifact carries one complete single-language body per language, in order, in one file, with each scene heading linked to the same scene in the other bodies.

The word is *imprint* because *edition* already means *language edition* throughout the publish department (`Statement.Kind.editionBrief(language)`, `EditionStatus`, `translation_status`, the guide). Publishing's own word for a named line under one house is what was wanted; rejected: *cut* (a verb elsewhere), *configuration*/*profile* (nothing to confuse, nothing to love), renaming the language axis (touches vocabulary Denver has already ruled in).

## 2. The bilingual page — settled

**Sequential, unrotated.** Two complete bodies, one document: body(en) then body(sr). The pages are 16:9 cinema frames and a split page would destroy them; the Serbian half must read as a film in its own right, never as a crib beside the English. The languages never meet on a page. Rejected by design, not cost: parallel paragraph-aligned columns, facing pages (page-level balancing LaTeX cannot promise), interleaving (a screenplay doubles every cue). Missing or stale paragraphs need no treatment — there are no cells; each body is today's single-language emission behind today's gate, with the source-text fallback under `allow_stale` as now.

**The book's own title page appears once per body, in that body's language** (Denver's choice over once-in-the-first-language and once-bilingual). The mechanism is §5's `MaughamBody` environment plus per-body metadata; the pieces already carry their own front and back matter (Fountain title block, `>ЗА ГАЛУ<`).

## 3. Config and resolution

`.maugham/publish/config.json` gains one key, decoded tolerated-missing like `language_overrides` — no schema bump, and a config without it round-trips byte-identical:

```json
"imprints": {
  "special-glb": {
    "template": "templates/special-glb.tex",
    "sections": { "doc-2c6051f2": {} },
    "metadata": { "title": "Good Luck Babe", "subtitle": null },
    "cover": { "path": "covers/glb-cover.jpg" },
    "outputs": { "filename_template": "{title}-{imprint}-v{version}{language}{label_suffix}.{ext}" },
    "next_version": "0.1"
  }
}
```

**Resolution is one pure function** — `PublishConfig.resolved(imprint: String?) throws -> PublishConfig` — and everything downstream reads a plain config (approach chosen over threading `imprint` through every compiler like `language`, and over a config-per-imprint on disk that forks metadata and lets counters drift; the edition-identity milestone's lesson — a resolved value must reach every sink — is what resolving once guarantees):

- `nil` → `self`, untouched. Pinned by an equality test.
- Unknown name → throws; the message lists the known names.
- `template` **replaces** (default `template.tex`).
- `sections` is an **allowlist**: the imprint's map *is* its rendered set; a piece absent from the map is excluded (the inverse of the top level, where absent means included — a one-entry map under the top-level rule would ship the whole book in 16:9). Each entry is a full `Section` with today's defaults, so `title_override`, `style_file`, `start_on`, `include_in_toc` work per imprint. Absent `sections` key → inherit the project's map and rule.
- `metadata`, `outputs`, `cover` **deep-merge**, `null` deletes — RFC 7396, through the merger `PublishConfigStore.applyPatch` already has; no second implementation.
- `next_version` is the imprint's own counter and replaces.
- The resolved config carries `imprint` (the name, `nil` for the book) and `template` as first-class fields. `language_overrides` still apply after resolution, per body (§5).

**Validation** (`PublishConfigValidator`, at save through `set_publish_config` and at compile): names `[a-z0-9-]+`; `template` exists under `.maugham/publish/` and cannot escape it; an allowlist is non-empty and names only manuscript pieces. An imprint template is a **full** template, peer of the default — the piece-`style_file` prohibitions (`\usepackage`, geometry) do not apply, and `EMISSION.md` says so.

Unchanged: `set_publish_config` reaches `imprints.*` through merge-patch; templates are authored with `write_publish_file`; the Designer's rounds stay pointed at the default template (an imprint-aware design round is not this milestone; nothing forbids it).

## 4. Identity, versioning, the mint gate

**Key:** `(imprint, version, language, format)`. `Publication.imprint: String?`, tolerated-missing on decode; `nil` is the book. Nothing writes the empty string — the default is the absence, as source language is today. The existing catalog loads unchanged.

**Language** stays one `String?` with one more spelling: a `+`-joined list in listed order, the source named by `metadata.language` — `"en+sr"`. Single-language records are unchanged. `list_publications`' `language` filter and `read_publication_page` match the string exactly; the `"source"` sentinel still means untagged rows only.

**Counters.** Each imprint has its own `next_version`; the book's is the top-level one. `CompileOrchestrator`'s existing post-compile bump writes to the counter the resolved config came from. **A source compile** is one whose `languages` set is empty or contains the source language: `compile(imprint: "special-glb", languages: ["en","sr"])` mints at the imprint's `next_version` and bumps it; `languages: ["sr"]` is an edition of an existing version of that imprint — pinned by `version`, else the imprint's latest original source record — today's rule, scoped per imprint. A pin naming a version that exists only under another imprint is refused with the imprint named. (Without this, the special cut cannot exist until someone compiles it English-only first.)

**Filename.** `OutputFilenameBuilder` gains `{imprint}` with `{language}`'s strip-one-dangling-separator rule and the same collision guard: an imprint compile whose template lacks `{imprint}` gets `-<imprint>` inserted before the extension, so an imprint never overwrites the book's file. The joined language renders into `{language}` as-is.

**`PublishMintGate.Key`** gains the imprint and takes the joined language string: a bilingual compile and an sr-only compile of one imprint at one version are two keys; two bilingual compiles collide. `dry_run` stays exempt.

## 5. The multi-language compile

**Call.** `compile`/`preview_compile` take `languages: [String]?` beside `language`; both given must agree or `invalid_argument`. Order is emission order; the source is `metadata.language` or `"source"`; `["sr"]` ≡ `language: "sr"`; empty/absent ≡ source; duplicates and unknown tags refuse.

**Bodies.** `ProjectASTBuilder.build` runs once per language over the same resolved config through `ProjectStoreASTSource(language:)`, so each body is exactly today's single-language AST (the identity-equivalence tests keep pinning that). Each body emits to its own file — `build/body.<tag>.tex`, per-body XHTML — and `build/body.tex` is the sequence:

```latex
\ifdefined\MaughamBody\else\newenvironment{MaughamBody}[1]{\clearpage}{}\fi
\begin{MaughamBody}{en}\input{build/metadata.en}\input{build/body.en}\end{MaughamBody}
\begin{MaughamBody}{sr}\input{build/metadata.sr}\input{build/body.sr}\end{MaughamBody}
```

`metadata.<tag>.tex` is `effectiveMetadata(language:)` rendered as the `\renewcommand`s the preamble receives today, so each half opens under its own language's overrides; a template that wants a title page per half defines `MaughamBody`; one that doesn't gets a page break. Per-piece `style_file` resolves its language suffix per body; the imprint **template** is used unsuffixed for a multi-language compile (suffixing stays a single-language affair). A single-language compile emits the same wrapper with one body — one contract, not two.

**Anchors.** `PieceRef` hands the builder its paragraphs as `(¶id, text)` in `sequence` order instead of one joined string; the builder stamps each paragraph's id on the **first node it produces** — Fountain by the tokenizer's line ranges against paragraph offsets (the seam `TranslatedFountainStructure` uses), prose by the shared block parser's line ranges (verify at plan time; if absent, add them in MaughamCore, where the phone gets them too). Emission: `\hypertarget{p-<tag>-<¶id>}{}` before the node; `id="p-<tag>-<¶id>"` on the XHTML element. Every compile emits them. The manuscript on disk is untouched.

**Cross-links, scene headings only.** Translations are keyed by source `¶id` and every paragraph exists in every body (missing → source-text fallback), so a slugline in body(en) targets `p-sr-<same id>` and the target always exists — no pair table. Emitted as `\MaughamCrossLink{p-sr-x}{\scene{…}}` with a `\providecommand` fallback that renders the heading unlinked. Three languages: a heading links to each other body in order. EPUB: `<a href="#p-sr-x">` on the heading; bodies are separate chapter files with `xml:lang`; the nav groups per body.

**Gate.** Runs once per translated language over the imprint's rendered set; any block refuses the whole compile with each language's errors; `allow_stale` applies to all; drift warnings carry their language.

## 6. Tools and the desk

Tools — the catalogue count moves by zero; every change widens an existing tool:
- `compile`, `preview_compile`: `imprint?`, `languages?`. Unknown imprint → `invalid_argument` naming the known ones; the mint-gate refusal names the imprint.
- `list_publications`: rows carry `imprint` (`null` for the book); new `imprint` filter with `"book"` as the untagged sentinel, mirroring `language: "source"`.
- `read_publication_page`: `imprint` joins `version`/`language` disambiguation; `publication_id` wins outright.
- `get_publish_config`/`set_publish_config`: `imprints` rides through; the post-patch validation refuses a bad imprint at write time with the validator's sentence.
- `translation_status`, `read_edition_brief`: per language, unchanged — an imprint changes which pieces, not which languages exist.
- `get_help`: `docs/guide/publishing.md` gains "Imprints"; the bootstrap skill's template-authoring section says an imprint template is a full template.

The desk (`DetailSegment.department`): one new control, an **Imprint** picker at its head — "Book" plus each named imprint, persisted per project in `UIState`. Everything below reads it: rows filter to it (the book's rows under "Book", so today's desk is what a writer sees until an imprint exists); the edition-status table scopes its rendered set to the allowlist; a translator's run targets the imprint's pieces.

**There is no in-app compile today** — every compile and preview is an MCP call (`CompileTools.swift`; the desk runs translators and the designer, never tectonic). Denver's choice of "show + choose" ("produce the special cut without Claude in the loop") therefore adds one: a **Compile…** action on the desk — format, the `languages` set drawn from the desk's own language rows ("English + Serbian" is two checks), the imprint from the picker — running `CompileOrchestrator` through `PublishingStores` with the same mint gate and coverage gate the tool uses, reporting into the desk the way a translator's run does, and resetting `PublishPreviewCentre`'s publication picker on completion exactly as an MCP compile does. It is the desk's first non-AI action and the first time the book can be compiled without Claude; scoped to plan 3 with the picker. No create/rename/edit of an imprint in v1 — config-only, and the desk says so in one line when the picker holds only "Book" (rule 8 satisfied by inspection plus action; editing is the explicit v2).

Everywhere a compiled book is named — the Exports footer, `PublishPreviewCentre`'s publication picker, the desk rows — carries the imprint after the version, read off the record and never re-derived from the filename.

## 7. Snapshots, republish, the emission contract

Snapshots capture the **resolved** config (imprint applied; `template`, `imprint`, threaded `nextVersion`) and the `languages` list. `Republisher` reads both and runs the same per-language loop as a fresh compile — it never sees the word imprint; a republished bilingual record reproduces both bodies from the frozen checkpoint. `PublicationSnapshotStore` skips by name only (`DotfileScan`), so `templates/special-glb.tex` is captured like any file.

`EmissionContract.swift` gains three entries and `EMISSION.md` regenerates: the `MaughamBody` environment (one argument, the tag; guarded), `\MaughamCrossLink{target}{content}` (guarded; degrades to `content`), and the anchor form `\hypertarget{p-<tag>-<¶id>}{}` — documented as stable and addressable from a template, the first artifact-side id a writer can rely on. The byte-gate over the default template's output moves **once**, deliberately; the identity-translation and English-preview equivalence tests are widened to "unchanged except wrapper and anchors", never loosened.

`initialize_publish_template`'s default template gains a `MaughamBody` definition (`\clearpage` plus a per-half title page from the same `\MaughamTitle…` macros, so §2's choice works out of the box) and one comment pointing at the guide.

## 8. What is deliberately not here

- Creating, renaming or editing an imprint in the UI (v2).
- Per-imprint EPUB overrides beyond what deep-merge gives.
- `language_overrides` nested inside an imprint (nest later if a combination ever needs it).
- Parallel, facing or interleaved bilingual layouts (§2 — rejected by design).
- Per-paragraph link chrome (anchors exist for it; links are headings only).
- An imprint-aware Designer round.
- Any phone surface: the phone reads no publish output.

## 9. Testing

- *Resolution:* `resolved(nil) == self`; allowlist excludes absent pieces; deep-merge with `null` deletion through the existing merger; unknown name throws naming the known; validator refuses an escaping template path, an empty allowlist, a non-manuscript id.
- *Identity:* Publication round-trips with and without `imprint`; the old catalog fixture loads unchanged; `"en+sr"` is a plain exact-match string in both tools; mint-gate keys distinguish `["sr"]` from `["en","sr"]`; the per-imprint bump leaves the book's counter alone; a version pinned under the wrong imprint is refused naming the imprint.
- *Bodies:* the bilingual AST is the two single-language ASTs in order, pinned against `ProjectStoreASTSource(language:)`; wrapper and per-body metadata land in `body.tex`; a template lacking `MaughamBody` still compiles (real tectonic, behind `TectonicProbe.requireReady()`); the gate blocks on either language and reports both.
- *Anchors and links:* every paragraph's id lands once, on its first node — a Fountain block (cue + dialogue), coalesced action, a prose blockquote, the fenced-code-with-blank-line fixture; a slugline in body(en) links to the same `¶id` in body(sr) and the target exists; a single-language compile has anchors and no links.
- *Desk:* the picker persists and filters rows; **Compile…** passes `imprint` + `languages` + format to `CompileOrchestrator` through the real delivery path (the mode-UX lesson) and is refused by the same mint gate and coverage gate as the tool; the Exports row names the imprint from the record, not the filename.
- *Censuses:* every production sink of a publication's identity reads the record's `imprint` — grep with a planted offender (the "reach every sink" lesson, made enforceable).
- *Byte-gate:* one deliberate move of the golden output; English preview of Playlist before/after differs only by wrapper and anchors.

## 10. Plans

1. **Imprint resolution and identity** — §3, §4, snapshots, the tools' `imprint` argument, the filename token. Usable alone: the special cut in one language.
2. **Bilingual bodies** — §5 minus anchors: `languages`, per-body emission, wrapper, per-body metadata, the gate loop. Written against plan 1's built code.
3. **Anchors, cross-links, and the desk** — the AST paragraph ids, `\MaughamCrossLink`, `EMISSION.md`, the picker, the desk's **Compile…** action, and every naming surface. Smallest risk last; the desk waits until there is something to pick and something to compile.

Each plan gets a whole-branch review; the milestone lands on main whole and releases as one, Mac-only (no manifest schema change).

## 11. Acceptance (Denver's, restated with the decisions applied)

1. `preview_compile(imprint: "special-glb", languages: ["sr"], format: "pdf")` renders only `doc-2c6051f2`, in the imprint template's geometry, titled "Good Luck Babe", passing the gate against that one piece; `read_preview_page(1)` shows it.
2. `compile(imprint: "special-glb", languages: ["en","sr"])` mints `(special-glb, 0.1, "en+sr", pdf)`, bumps only the imprint's counter, and the file holds body(en) then body(sr), each opening under its own title page, every slugline in one linking to the same scene in the other.
3. A subsequent plain `compile()` of the collection is unaffected, and its output differs from pre-feature output only by the `MaughamBody` wrapper and the anchors.
4. A config with no `imprints` key round-trips untouched; existing publications list, address and `republish` as the book.
