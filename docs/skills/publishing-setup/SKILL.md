---
name: publishing-setup
description: Configure and compile a Maugham book's PDF, EPUB or Word output beyond the template itself — language editions and version families, the coverage gate, republish, imprints in config.json, bilingual bodies and the MaughamBody seam, and previewing a subset. Use when asked to set up or explain how a compile, an edition, an imprint or a bilingual volume behaves.
---

# Publishing setup

The writer's guide (`get_help` topic `publishing`) says what the writer does
from the app: Compile… on an edition's Book, the imprint picker, the
Editions checkboxes, Allow stale translations. This skill is the machinery
behind those, for you: the publish config, the compile tools' parameters,
and how editions, imprints and bilingual bodies resolve.

## Where the files are

The template, preamble, per-piece style files and `config.json` live under
`.maugham/publish/`. The PDF pipeline is a bundled tectonic (an XeTeX-based
LaTeX engine), so nothing is installed. `EMISSION.md` there is the
authoritative contract for what the body emitter produces for each source
pattern: read it before writing template hooks. A Word export's conversion of PDF and SVG figures happens
after the publish checks, so `dry_run` can't tell you one won't convert.

## Language editions and version families

A publication is identified by three dimensions here — **version, language, and format** — so `1.0/en/pdf`, `1.0/es/pdf`, and `1.0/es/epub` coexist as one family. (A fourth dimension, imprint, is covered under Imprints below; the book's own publications are the ones no imprint compiled.)

**The source edition is the authority:** Compile the manuscript in the source language first (no `language` parameter). This is when `next_version` bumps — each source compile gets the next available version number. Once a source publication exists at `1.0`, you can compile translated editions of it.

**Language editions are renderings of existing source versions:** `compile language:es` (without a `version` parameter) renders the latest source publication's version as a Spanish edition — it borrows that source's version number (e.g., `1.0`) as its identity. If you want to pair a translation with a *specific* earlier source version, pass `version: 1.0` alongside `language: es`. Importantly, language compiles never bump `next_version` — translations don't mint new versions, they render existing ones.

The manuscript text in a language edition is the *current* text, not the frozen text from when the source version was compiled. The same holds for the edition's *piece set*: a pinned edition renders the pieces currently included (sections you exclude or include after the source compile change the edition accordingly), and republishing reproduces that historical included subset from the snapshot. To recompile an edition with the design it had (its template, styles and config from the snapshot), use `republish`; the text is still the current manuscript, so tell the writer that a republish does not bring back old words — their earlier file in `Exports/` does. Note that republished `-r…` rows sit outside the version families — they carry a distinct republish-marked version and aren't themselves pinnable as an edition's source version. A republish always writes its own file: the `-r` version is minted before the compile runs, so it goes into the filename and into the version stamped inside the artifact, the edition you republished from keeps its own file in `Exports/` untouched, and republishing the same edition twice leaves you with two distinct files rather than one overwritten one.

**Refusals.** If you try to compile a language edition but no source publication exists yet, it refuses with a clear message: *"no source publication exists — compile the source edition first (or pass version to pin one) before rendering the es edition."* And if a compile of the same version, language and format is already running, a second one refuses straight away — *"Publication v1.0 (source, pdf) on the book is already compiling; wait for it to finish."* (under an imprint it says *"under imprint 'special'"* instead — the book and an imprint each count their own versions, so a refusal has to say whose v1.0 it means) — instead of racing it into a half-written file. Poll the one in flight with `compile_status`, or compile a different *language* in the meantime — language editions of the same book still compile side by side. Two formats of the same source at once is the one pairing worth waiting out: which version each ends up carrying depends on which finishes first. A `dry_run` is never refused by any of this — it asks a question and changes nothing, so it answers even while the real compile runs. And if something is already sitting at the filename a republish is about to write, it stops and tells you the path rather than deleting the file: move it aside yourself and republish again.

**Coverage gate:** Language editions are behind a translation-coverage gate: paragraphs that aren't yet translated (or are stale because the source changed) block the compile by default. The text cells of tables used in the edition's pieces are gated the same way (parked tables are not), and a language's status counts a chapter or table with no translation of its own as missing once that language has any translation in the edition. `dry_run: true` answers "would this edition compile right now?" without producing output. If you want to publish a partial edition anyway (for a preview), pass `allow_stale: true` to override the gate.

**Publish problems:** A cross-reference that points nowhere, a citation key no research source carries, a label used twice, a footnote with no definition, or a figure image that can't be used is a publish problem, and each one names the piece and the paragraph it came from. In a Report, those problems stop a `compile` or `republish` before any version is minted; the smaller ones (an unused footnote, a malformed label) are only warnings. In every other kind of project nothing stops — a novel that happens to say `[@sarah]` still compiles, with a warning. A preview never stops on them either, and `dry_run` lists them without compiling.

**Filenames and language tags:** Output filenames auto-suffix with the language (e.g. `-es`) unless the `filename_template` includes a `{language}` placeholder. If it does, that placeholder expands to the language tag for translations, and to nothing for the source edition. The template engine is smart about separators: if a placeholder expands to empty (the source case) and is immediately preceded by a separator like `-`, `_`, or `.`, that separator is dropped, so a single template `{title}-v{version}-{language}.{ext}` yields clean names like `Lighthouse-v1.0.pdf` and `Lighthouse-v1.0-es.pdf`.

**Template variants by language:** Compiling with a `language` set resolves `template.<lang>.tex` and per-piece `<piece>.<lang>.tex` automatically when they exist, falling back to the base file otherwise. This resolution only covers the template and per-piece style files themselves — it doesn't follow `\input` lines inside them. If the template inputs partials (preamble, frontmatter, backmatter), the edition needs its own `template.<lang>.tex` whose `\input` lines point at the `<lang>` partial variants; the resolver picks the template variant, and everything else follows from it.

## Imprints

An **imprint** is a named publishing configuration living inside one project — its own template, its own rendered set of pieces, its own metadata, cover and filename, and its own version counter — chosen at compile time. It's how a collection ships both its book and, say, a single-piece special edition with a completely different look, without forking the project or the manuscript: both draw on the same pieces and the same translation layer.

Declare one under `imprints` in `.maugham/publish/config.json` (via `set_publish_config`'s merge patch):

```json
"imprints": {
  "special-keeper": {
    "template": "templates/special-keeper.tex",
    "sections": { "doc-2c6051f2": {} },
    "metadata": { "title": "The Keeper", "subtitle": null },
    "cover": { "path": "covers/keeper-cover.jpg" },
    "outputs": { "filename_template": "{title}-{imprint}-v{version}{language}{label_suffix}.{ext}" },
    "next_version": "0.1"
  }
}
```

**`sections` is an allowlist**, the inverse of the top-level rule: at the top level, absent means *included*; inside an imprint, absent means *excluded*. The imprint's map *is* its rendered set — naming a piece is what includes it, so a one-entry map ships exactly that one piece rather than the whole book. Each entry is a full section (`title_override`, `style_file`, `start_on`, `include_in_toc` all work per imprint). Everything else an imprint doesn't name (`metadata`, `outputs`, `cover`) merges over the project's own — `null` deletes a key, and an absent `sections` key inherits the project's map.

**Resolution happens once, at compile time**, before anything else runs: pass `imprint: "special-keeper"` to `compile` or `preview_compile` and everything downstream — the emitter, the coverage gate, the snapshot — sees an ordinary, already-resolved config and never learns an imprint was involved. Omit `imprint` (or pass nothing) and you get the book, as always.

**Validation** happens both when you save the config and when you compile: an imprint name must match `[a-z0-9-]+`; its `template` must be a relative path that exists under `.maugham/publish/`; its `sections` allowlist, if given, must be non-empty and name only pieces that exist in the project. A *top-level* `imprint` key is refused at both doors: that field is set by resolution when you compile, never written — a hand-written one would misname the book's own output files while its catalog rows said otherwise. An imprint's own template is a **full** template — a peer of the book's `template.tex`, not a per-piece style-file hook — so it may `\usepackage` and set its own `\geometry` freely (`EMISSION.md` says the same). One more rule is about the *filesystem*, not the config: tectonic's output directory is flat and names each compiled file by the template's own basename, so an imprint's template basename (with any language suffix stripped) must differ from the book's and from every other imprint's, or one compile's output would silently overwrite another's intermediate files. And because tectonic resolves `\input` relative to the *template's own directory*, an imprint template living in a subdirectory (e.g. `templates/special-keeper.tex`) reaches a shared `preamble.tex` at the project root with `\input{../preamble}`, not `\input{preamble}`.

**Identity gains a fourth dimension.** A publication is keyed on `(imprint, version, language, format)` — the book's `1.0/en/pdf` and the special edition's `0.1/en/pdf` are independent publications with independent version counters, and compiling one never blocks or races the other. `list_publications`, `read_publication_page`, `compile` and `preview_compile` all take an `imprint` parameter (exact name match); the sentinel `"book"` selects the publications no imprint compiled, mirroring `"source"` for the untagged source language. Output filenames carry a `{imprint}` token with the same strip-one-dangling-separator behavior as `{language}`; if the `filename_template` doesn't mention `{imprint}`, the imprint name is inserted before the extension automatically, so an imprint compile never overwrites the book's file.

## Bilingual editions

A book doesn't have to choose one language per file. Pass `languages` to `compile` or `preview_compile` — an ordered list, e.g. `["en", "sr"]` — and you get one document holding a complete body per language, **sequential and unrotated**: the source runs start to finish, then the translation runs start to finish, never interleaved paragraph by paragraph. Each half is meant to read as a book in its own right — a Serbian reader gets a Serbian book, not a bilingual facing-page curiosity — rather than as a study aid for comparing the two side by side.

Say which body is the untranslated one with `"source"` in the list, or just name the book's own `metadata.language` directly — both spellings mean the same body. A `languages` set that includes the source is a source compile: it mints at `next_version` and bumps the counter, same as an ordinary source compile. A set without the source is an edition of an *existing* source version, exactly like a single-language `language: es` — it doesn't mint a new version. `languages: ["sr"]` is equivalent to `language: "sr"`; if you pass both, they have to agree, or the compile refuses. The same reading applies to the older single `language` parameter: naming the book's own tongue — `language: "en"` on a book whose `metadata.language` is `en` — names the *source* body, so it is a source compile like any other. It mints at `next_version` and bumps the counter, and no translation-coverage gate runs, because there is nothing to translate; it does not go looking for an existing English edition to render. Duplicate or invalid tags refuse the same way a single bad tag always has.

**The identity carries every language, joined.** A bilingual compile of English and Serbian is `(imprint, version, "en+sr", format)` — its own publication, sitting beside the English-only and Serbian-only editions of the same version rather than overwriting either. The filename's `{language}` placeholder expands to `en+sr` the same way it expands to `es` for a single translated edition; `list_publications`'s `language` filter and `read_publication_page` match the joined string exactly, not either half of it. A bilingual publication counts as a source edition for version-pinning purposes when its set includes the source body, same as any other source compile.

**The gate runs once per translated tongue.** Each language in the list gets its own translation-coverage check; a compile refuses only if at least one blocked tongue exists, and when it does, the refusal lists *every* blocked tongue's errors together — not just the first — each prefixed with its own tag (e.g. `[sr] paragraph ¶3f2a is untranslated`) so you can see every gap in one pass rather than compiling once per language to find them all. `allow_stale` applies uniformly: pass it and every tongue with gaps falls back to source text for the missing paragraphs instead of blocking.

**`MaughamBody` is the seam between the halves.** `build/body.tex` is not the book itself but a thin wrapper: a guard line that defines a default `MaughamBody` environment if the template hasn't, followed by one `\begin{MaughamBody}{<tag>}...\end{MaughamBody}` block per rendered language, each `\input`-ing that language's own body and metadata. The default behavior is a `\clearpage` between halves and nothing else — a single-language compile still emits exactly one `MaughamBody` block and paginates exactly as it always has. To give each half its own title page, redefine the environment in the template and key the frontmatter on its argument:

```latex
\renewenvironment{MaughamBody}[1]{\clearpage\input{frontmatter-#1}}{}
```

`#1` is the language tag, so that line expects a `frontmatter-en.tex` and a `frontmatter-sr.tex` sitting beside the template — the starter `preamble.tex`'s own commented-out `MaughamBody` example shows the same pairing.

The document-level title page, running heads and PDF metadata are always the **first** listed body's — a bilingual PDF is one book, titled in its source language, with the translated half's own title (if any) applying only inside its own `MaughamBody` group.

**Per-body metadata comes from `language_overrides`**, the same config key that already drives a single translated edition's title, subtitle and the rest — nothing new to configure for a second language beyond what an ordinary `language: sr` compile would already need.

**Every paragraph carries its own place.** A compiled document — bilingual or not — anchors every paragraph invisibly, so a template (or a reader's PDF viewer following a link) can address any paragraph directly. In a multi-language compile, that anchor is what lets a **scene heading link across the halves**: tap a slugline in one language's half and you land on the same scene in the other. In the EPUB, the same tap crosses from one language's section file into the other's. Only scene headings link across the halves; every other paragraph is anchored but links nowhere.

## Iterating on a subset of a book

For a multi-piece collection, you don't have to recompile the whole thing to check one piece's typography. Turn off `sections.<id>.include` for the pieces you want to skip, then run `preview_compile` (pass `language` too, for a translated edition) to render just the included subset without touching the project's published version history — `compile`'s `dry_run` option is the companion check when you just want to know whether an edition's translation-coverage gate would pass, without producing output at all. `read_preview_page` closes the loop the same way `read_publication_page` does for a real Publication — you read the rendered page directly rather than working blind. Once the subset looks right, turn the excluded sections back on and compile the full edition.
