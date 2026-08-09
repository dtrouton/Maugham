# Extension brief — add a `## Textures` section to the palette card

You are extending a Swift type from its written specification, as a controlled experiment.
**You have not seen, and will not be given, the implementation, its doc comments, or its
tests.** Everything known about the required behaviour is in this document.

## Your task

Palette cards are plain-markdown research assets a writer keeps under `research/palette/`.
Add a fourth section, `## Textures`, alongside Swatches / Senses / Images.

A texture entry is a short free-text note about how something feels, optionally prefixed
with a **material tag**. Unlike `Sense`, the material tag is an **arbitrary string**, not a
closed set:

```markdown
## Textures

- slate: cold underfoot, slightly damp
- horsehair plaster: powders when you lean on it
- everything here is gritty
```

Deliver the complete modified contents of `PaletteCard.swift` — the model, the parser and
the renderer — with `textures` as a new stored property on `PaletteCard`. Choose the
element type. `import Foundation` only.

Then deliver your notes (see §6). **The notes matter more than the code.**

## 1. The canonical card format today

```markdown
# The Flat

kind: location

Any prose the writer types between the `kind:` line and the first `##`
heading is captured as `body`. It may run to several paragraphs.

## Swatches

- #8A6F4D
- #2F3B4C

## Senses

- smell: turpentine and cold ash
- sound: tram-rattle through the shutters
- cold quarry tile underfoot

## Images

- ./the-flat_assets/image-1.png
```

Title is the first `# ` heading (else a caller-supplied fallback). `kind:` is captured once,
before any real section. Everything between `kind:` and the first real `##` is `body`.

## 2. Public surface today

```swift
public struct PaletteCard: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable { case location, character, motif, other }
    public enum Sense: String, CaseIterable, Sendable { case sight, sound, smell, touch, taste }
    public struct SensoryNote: Equatable, Sendable {
        public let sense: Sense?
        public let text: String
        public init(sense: Sense?, text: String)
    }

    public let researchItemId: String
    public let title: String
    public let kind: Kind
    public let swatches: [String]      // validated "#RGB" / "#RRGGBB"
    public let notes: [SensoryNote]
    public let imagePaths: [String]    // project-relative
    public let body: String            // freeform prose before the first `##`

    public init(researchItemId: String, title: String, kind: Kind,
                swatches: [String], notes: [SensoryNote], imagePaths: [String],
                body: String = "")

    public var id: String { researchItemId }

    /// "#RRGGBB" / "#RGB" -> normalized rgb components, nil if malformed.
    public static func color(fromHex hex: String) -> (r: Double, g: Double, b: Double)?
}

public enum PaletteCardParser {
    public static func template(title: String, kind: PaletteCard.Kind) -> String
    public static func parse(markdown: String, itemId: String,
                             fallbackTitle: String, cardDirectory: String) -> PaletteCard
}

public enum PaletteCardRenderer {
    public static func render(_ card: PaletteCard, cardDirectory: String) -> String
    public static func relativize(_ path: String, from directory: String) -> String
}

// Available to you, already shared:
public enum MarkdownBlockParser {
    /// Every `![alt](path)` in document order.
    public static func findInlineImages(in markdown: String) -> [(alt: String, path: String)]
}
```

## 3. Rulings

**These are binding.** They were made by the product owner, not derived from the code, and
they take precedence over any claim below that appears to conflict with them.

### RULING-1

> Maugham MUST NOT accept, through any of its own entry points, content it cannot read back faithfully. The refusal must be visible at the point of entry rather than discovered later.

- **Scope:** every entry point Maugham itself offers — the editor, MCP writes, canvas promotion, inbox promote
- **Rationale:** Product-level, from the constitution's 'the words are safe'. The writer must never be able to create, from inside the app, content that will later be eaten. Stated by Denver as: 'this is what makes it important there isn't a foot gun and people can't enter things that will get eaten within Maugham'.

### RULING-2

> A file on disk MAY contain content Maugham drops when reading it. That is acceptable. The fidelity obligation is on the ENTRY POINTS, not on the file.

- **Scope:** the parse path, for files arriving from outside — hand-edits, imports, sync
- **Rationale:** Consistent with the existing hard invariant that external .md edits are not honored and the model owns the file. Deliberately NOT symmetric with RULING-1: strictness applies where a person can act, tolerance applies where a file arrives.

## 4. Behavioural claims

`warrant` = how well evidenced the claim is (`HIGH` = a dedicated test asserts it; `LOW` =
observed behaviour nobody has ratified; `CORRECTED` = the claim was wrong and has been
fixed). `verdict` = whether the behaviour is WANTED, per §3. The two are independent: a
well-evidenced claim can still be a `DEFECT`.

| id | scope | warrant | verdict | claim |
|---|---|---|---|---|
| M1-C-001 | `PaletteCard.color(fromHex:)` | LOW | UNRULED | hex bodies of any length other than 3 or 6 characters are rejected |
| M1-C-002 | `PaletteCard.color(fromHex:)` | LOW | UNRULED | surrounding or interior whitespace is not tolerated and yields nil |
| M1-C-003 | `PaletteCard.color(fromHex:)` | LOW | UNRULED | a leading '+' is ACCEPTED as a hex-body character: '#+FFFFF' passes the six-character check and parses as 0x0FFFFF |
| M1-C-004 | `PaletteCard.color(fromHex:)` | LOW | UNRULED | a leading '-' is rejected |
| M1-C-005 | `PaletteCard.color(fromHex:)` | LOW | UNRULED | non-ASCII digit forms (fullwidth, Arabic-Indic) are rejected |
| M1-C-006 | `PaletteCard.color(fromHex:)` | LOW | UNRULED | the empty string is rejected |
| M1-C-007 | `PaletteCard.color(fromHex:)` | LOW | UNRULED | the 3-digit form expands by digit doubling and agrees exactly with the equivalent 6-digit form, case-insensitively |
| M1-C-008 | `PaletteCardParser.parse` | LOW | UNRULED | an empty document yields a fully defaulted card: fallback title, .other, empty everything |
| M1-C-009 | `PaletteCardParser.parse` | LOW | UNRULED | a whitespace-only document becomes BODY, because the structural-framing test is raw.isEmpty rather than a blankness test |
| M1-C-010 | `PaletteCardParser.parse` | LOW | UNRULED | a '# ' line with no title text is not a title (the trimmed probe collapses it to '#') and is kept as body |
| M1-C-011 | `PaletteCardParser.parse` | LOW | UNRULED | a SECOND '# ' heading is kept as body text rather than discarded |
| M1-C-012 | `PaletteCardParser.parse` | LOW | UNRULED | a '#' with no following space is not a title |
| M1-C-013 | `PaletteCardParser.parse` | LOW | UNRULED | an H3 ('### ') heading is neither a title nor a section and falls into body |
| M1-C-014 | `PaletteCardParser.parse` | LOW | UNRULED | section heading matching is case-insensitive |
| M1-C-015 | `PaletteCardParser.parse` | LOW | UNRULED | extra spaces inside and after a section heading are tolerated |
| M1-C-016 | `PaletteCardParser.parse` | LOW | UNRULED | an INDENTED section heading still opens that section, because structure detection runs on the trimmed probe |
| M1-C-017 | `PaletteCardParser.parse` | LOW | UNRULED | a heading with no space after the hashes is not a section |
| M1-C-018 | `PaletteCardParser.parse` | LOW | UNRULED | a repeated section heading appends to the same collection rather than resetting it |
| M1-C-019 | `PaletteCardParser.parse` | LOW | UNRULED | sections may appear in any order |
| M1-C-020 | `PaletteCardParser.parse` | LOW | UNRULED | the kind key tolerates a missing space after the colon and any casing of the key itself |
| M1-C-021 | `PaletteCardParser.parse` | LOW | UNRULED | an EMPTY kind value consumes the one-shot capture: kind becomes .other and a later well-formed kind: line is demoted to body |
| M1-C-022 | `PaletteCardParser.parse` | LOW | UNRULED | a kind: line appearing after a section heading is discarded entirely — neither captured as kind nor kept as body |
| M1-C-023 | `PaletteCardParser.parse` | LOW | UNRULED | a blank line the writer typed between pre-kind prose and the kind: line is silently eaten, but a whitespace-bearing line in the same position survives |
| M1-C-024 | `PaletteCardParser.parse` | LOW | ACCEPTED_LIMIT | a CRLF document parses as ONE line — Swift treats \r\n as a single Character so split(separator:'\n') never fires — and the title swallows the whole file while kind, swatches, senses and images are all lost |
| M1-C-025 | `PaletteCardParser.parse` | LOW | UNRULED | swatches are neither deduplicated nor case-normalised by the parser |
| M1-C-026 | `PaletteCardParser.parse` | LOW | UNRULED | a 3-digit swatch survives parsing unexpanded; expansion happens only inside color(fromHex:) |
| M1-C-027 | `PaletteCardParser.parse` | LOW | UNRULED | an unrecognised sense prefix keeps the WHOLE item text, colon included |
| M1-C-028 | `PaletteCardParser.parse` | LOW | UNRULED | an item beginning with a colon is untagged and keeps the colon |
| M1-C-029 | `PaletteCardParser.parse` | LOW | UNRULED | whitespace around the sense token is tolerated |
| M1-C-030 | `PaletteCardParser.parse` | LOW | UNRULED | a bare '-' or '- ' item is dropped from every section |
| M1-C-031 | `PaletteCardParser.parse` | LOW | UNRULED | dash-item images are NOT deduplicated against each other |
| M1-C-032 | `PaletteCardParser.parse` | LOW | UNRULED | an inline image IS deduplicated against an already-collected dash item, giving the two intake routes different dedup rules |
| M1-C-033 | `PaletteCardParser.parse` | LOW | UNRULED | an absolute path passes through resolution unchanged |
| M1-C-034 | `PaletteCardParser.parse` | LOW | UNRULED | a remote-URL dash item is skipped entirely |
| M1-C-035 | `PaletteCardParser.parse` | LOW | UNRULED | climbing above the project root is clamped rather than rejected: '../../../../x.png' resolves to 'x.png' |
| M1-C-036 | `PaletteCardParser.parse` | LOW | UNRULED | '.' and '..' segments are collapsed in place during resolution |
| M1-C-037 | `PaletteCardParser.parse` | LOW | UNRULED | an empty cardDirectory leaves relative paths bare |
| M1-C-038 | `PaletteCardParser.parse` | LOW | ACCEPTED_LIMIT | an unknown heading BEFORE any real section is kept as body, heading line included, along with the prose under it |
| M1-C-039 | `PaletteCardParser.parse` | LOW | ACCEPTED_LIMIT | an unknown heading AFTER real structure discards itself and everything under it up to the next heading |
| M1-C-040 | `PaletteCardRenderer.render` | LOW | UNRULED | the canonical render of an empty card is a fixed byte string with two blank lines between empty sections |
| M1-C-041 | `PaletteCardParser.template` | LOW | UNRULED | template and render disagree on blank lines between empty sections, so a freshly created card's file changes bytes on its first save; both forms re-parse identically, which is why nothing catches it |
| M1-C-042 | `PaletteCard.Sense` | LOW | UNRULED | Sense declaration order is [sight, sound, smell, touch, taste] and Kind is [location, character, motif, other] |
| M1-C-043 | `PaletteCard` | LOW | DEFECT | a swatch that is not valid hex IS written to the file (uppercased) and is silently lost on the way back in — the round-trip law does not hold for it |
| M1-C-044 | `PaletteCard` | LOW | DEFECT | a newline in the title migrates the remainder into body on round-trip |
| M1-C-045 | `PaletteCard` | LOW | DEFECT | a newline in a note truncates it at the newline on round-trip; the remainder is lost |
| M1-C-046 | `PaletteCard` | LOW | DEFECT | a remote URL in imagePaths is mangled by relativize (the scheme's '//' collapses) and reads back as a single-slash relative path |
| M1-C-047 | `PaletteCard` | LOW | UNRULED | a body spelling a KNOWN section heading loses that body on the first pass (claimed by section detection, any inline image harvested) and is stable from the second pass on |
| M1-C-048 | `PaletteCardRenderer.relativize` | LOW | UNRULED | a path EQUAL to the directory climbs out and comes back in ('research/palette' from 'research/palette' -> '../palette') |
| M1-C-049 | `PaletteCardRenderer.relativize` | LOW | UNRULED | an empty path produces a bare climb ('../../') |
| M1-C-050 | `PaletteCardRenderer.relativize` | LOW | UNRULED | an empty directory yields the './' form |
| M1-C-051 | `PaletteCardRenderer.relativize` | LOW | UNRULED | one '../' is emitted per uncommon directory component |
| M1-C-052 | `PaletteCardRenderer.relativize` | LOW | UNRULED | a sibling directory sharing a textual prefix ('research/paletteX') is not confused for the directory itself |
| M1-T-001 | `PaletteCardParser.parse` | HIGH | UNRULED | the itemId argument is copied verbatim to the returned card's researchItemId; the parser never derives an id from the markdown |
| M1-T-002 | `PaletteCardParser.parse` | HIGH | UNRULED | title is taken from the first `# ` heading, trimmed of surrounding whitespace |
| M1-T-003 | `PaletteCardParser.parse` | HIGH | UNRULED | a `kind:` line whose value matches a Kind rawValue yields that Kind |
| M1-T-004 | `PaletteCardParser.parse` | HIGH | UNRULED | in the Swatches section only `- ` items that pass color(fromHex:) are retained, in document order; malformed items are silently dropped |
| M1-T-005 | `PaletteCardParser.parse` | HIGH | UNRULED | a Senses item of form `<sense>: text` yields a tagged note; the sense token is matched case-insensitively (`SOUND:` -> .sound) |
| M1-T-006 | `PaletteCardParser.parse` | HIGH | UNRULED | a Senses item with no recognised sense prefix yields an untagged note carrying the whole item text |
| M1-T-007 | `PaletteCardParser.parse` | HIGH | UNRULED | an Images `- path` item is resolved against cardDirectory into a project-relative path, with `..` climbing out of that directory |
| M1-T-008 | `PaletteCardParser.parse` | HIGH | UNRULED | an inline ![alt](path) written as loose prose inside the Images section is harvested and appended AFTER the dash items |
| M1-T-009 | `PaletteCardParser.parse` | HIGH | UNRULED | with no `# ` heading present, title falls back to the fallbackTitle argument |
| M1-T-010 | `PaletteCardParser.parse` | HIGH | UNRULED | with no `kind:` line present, kind defaults to .other |
| M1-T-011 | `PaletteCardParser.parse` | HIGH | UNRULED | markdown containing no section headings yields empty swatches, notes and imagePaths (never nil, never a partial parse) |
| M1-T-012 | `PaletteCardParser.parse` | HIGH | UNRULED | a `kind:` value that matches no Kind rawValue degrades to .other rather than failing |
| M1-T-013 | `PaletteCardParser.template` | HIGH | UNRULED | parse(template(title:kind:)) recovers exactly that title and kind |
| M1-T-014 | `PaletteCardParser.parse` | HIGH | UNRULED | text between the `kind:` line and the first recognised `##` section becomes body, with interior blank-line runs preserved |
| M1-T-015 | `PaletteCardParser.parse` | HIGH | UNRULED | body capture stops at the first recognised section heading and does not swallow that section's items |
| M1-T-016 | `PaletteCardParser.parse` | HIGH | UNRULED | a card with no prose between `kind:` and the first section yields body == "" (empty string, not a blank line) |
| M1-T-017 | `PaletteCardParser.parse` | HIGH | UNRULED | an inline ![alt](path) appearing in BODY prose is NOT harvested into imagePaths — body images stay editable prose |
| M1-T-018 | `PaletteCard` | HIGH | UNRULED | a card whose body contains a local inline image satisfies parse(render(card)) == card |
| M1-T-019 | `PaletteCardParser.parse` | HIGH | UNRULED | an inline image with a `://` scheme in body prose is not harvested; remote URLs never enter imagePaths |
| M1-T-020 | `PaletteCard` | HIGH | UNRULED | a card whose body contains a remote inline image satisfies parse(render(card)) == card |
| M1-T-021 | `PaletteCardParser.parse` | HIGH | UNRULED | an inline image inside the Images section IS harvested and resolved relative to cardDirectory, even when written as loose prose rather than a dash item |
| M1-T-022 | `PaletteCard` | HIGH | UNRULED | leading indentation on body lines survives render->parse byte-for-byte |
| M1-T-023 | `PaletteCard` | HIGH | UNRULED | an interior run of more than one blank line inside body survives render->parse byte-for-byte |
| M1-T-024 | `PaletteCard` | HIGH | UNRULED | trailing spaces on body lines survive render->parse byte-for-byte |
| M1-T-025 | `PaletteCard` | HIGH | UNRULED | exactly one leading blank line is structural framing; a body starting with a blank line beyond that pair survives the round trip |
| M1-T-026 | `PaletteCard` | HIGH | UNRULED | exactly one trailing blank line is structural framing; a body ending with a blank line beyond that pair survives the round trip |
| M1-T-027 | `PaletteCard.color(fromHex:)` | HIGH | UNRULED | a well-formed 6-digit `#RRGGBB` string returns a non-nil triple |
| M1-T-028 | `PaletteCard.color(fromHex:)` | HIGH | UNRULED | a 3-digit `#RGB` string is accepted and expanded by digit doubling; hex digits are case-insensitive |
| M1-T-029 | `PaletteCard.color(fromHex:)` | HIGH | UNRULED | a string without a leading `#` returns nil |
| M1-T-030 | `PaletteCard.color(fromHex:)` | CONTRADICTED | UNRULED | a string with non-hex digits returns nil |
| M1-T-031 | `PaletteCard.color(fromHex:)` | HIGH | UNRULED | channels are normalised to 0...1 by dividing the byte by 255, so `#FF0000` yields r == 1.0 |
| M1-T-032 | `PaletteCard` | HIGH | UNRULED | a fully-populated card (title, kind, swatches, tagged+untagged notes, in- and out-of-directory images, multi-paragraph body) satisfies parse(render(card)) == card |
| M1-T-033 | `PaletteCard` | HIGH | UNRULED | a card with every collection empty and an empty body satisfies parse(render(card)) == card |
| M1-T-034 | `PaletteCardRenderer.render` | HIGH | UNRULED | an image path under cardDirectory is emitted card-relative with a `./` prefix |
| M1-T-035 | `PaletteCardRenderer.render` | HIGH | UNRULED | the rendered markdown never contains the project-relative form of an image path |
| M1-T-036 | `PaletteCardRenderer.render` | HIGH | UNRULED | swatch hex is normalised to uppercase on render regardless of the model's case |
| M1-T-037 | `PaletteCard` | HIGH | UNRULED | a body containing an UNKNOWN `## ` heading round-trips: the parser must not truncate body at a heading-like line |
| M1-T-038 | `PaletteCard` | HIGH | UNRULED | a body line spelling `kind: ...` round-trips as body text |
| M1-T-039 | `PaletteCardParser.parse` | HIGH | UNRULED | a `kind:`-looking line inside body must NOT overwrite the card's kind — kind is captured at most once, before any section |
| M1-T-040 | `PaletteCard` | HIGH | UNRULED | a body line beginning `- ` round-trips as body prose and is not captured as a list item |
| M1-T-041 | `PaletteCardRenderer.render` | HIGH | RATIFIED | render never emits a bare `- ` bullet line (one that the parser would drop on reparse) |
| M1-T-042 | `PaletteCardRenderer.render` | HIGH | RATIFIED | an untagged note whose text is empty or whitespace-only is deliberately dropped by render (it cannot round-trip) |
| M1-T-043 | `PaletteCardRenderer.render` | HIGH | UNRULED | dropping an untagged-empty note does not disturb the surviving notes' order or content |
| M1-T-044 | `PaletteCardRenderer.render` | HIGH | UNRULED | a TAGGED note with empty text is kept, rendered as `- <sense>: `, and round-trips |
| M1-T-045 | `PaletteCardRenderer.relativize` | HIGH | UNRULED | a path under `directory` becomes `./` + the remainder |
| M1-T-046 | `PaletteCardRenderer.relativize` | HIGH | UNRULED | a path outside `directory` gets one `../` per uncommon trailing directory component |
| M1-T-047 | `PaletteCard.Sense` | HIGH | UNRULED | Sense.allCases raw values are the single sense vocabulary; downstream surfaces derive from it rather than hard-coding a literal, so adding a case propagates automatically |
| M1-T-048 | `PaletteCard.Sense` | MEDIUM | UNRULED | the DECLARATION ORDER of Sense is sight, sound, smell, touch, taste, and that order is load-bearing for downstream grouping/display |

## 5. Intent envelope

| id | clause |
|---|---|
| M1-A-01 | **MUST satisfy `parse(render(card)) == card` for any editor-reachable model** |
| M1-A-02 | **MUST NOT let a body line spelling a KNOWN section heading survive as body — this residual is accepted, and the round trip converges from the second render** |
| M1-A-03 | **MUST treat the model as owner of the file: re-rendering normalises hand edits rather than preserving them** |
| M1-A-04 | **MUST preserve body bytes verbatim — indentation, trailing whitespace, interior blank-line runs — stripping only the renderer's single structural blank-line pad** |
| M1-A-05 | **MUST NOT let an inline `![]()` in BODY prose enter `imagePaths`** |
| M1-A-06 | **MUST NOT let a remote URL (`://`) enter `imagePaths`, regardless of section** |
| M1-A-07 | **MUST capture `kind:` at most once, before any real section; a later `kind:`-looking line is ordinary body prose** |
| M1-A-08 | **MUST degrade an unknown/missing `kind` to `.other` rather than failing** |
| M1-A-09 | **MUST NOT emit an untagged note whose text is empty/whitespace-only — it cannot round-trip** |
| M1-A-10 | **MUST keep a TAGGED note with empty text — `- smell: ` round-trips** |
| M1-A-11 | **MUST validate swatches as `#RGB`/`#RRGGBB` and silently ignore others** |
| M1-A-12 | **MUST normalise to canonical form on render: uppercase swatches, `./`-relative image paths, all sections always present** |
| M1-A-13 | **MUST treat an unknown `##` heading before any real section as body, and after real structure as a dropped section** |
| M1-A-14 | **MUST resolve card-relative image paths to project-relative on the way in and invert exactly on the way out** |
| M1-A-15 | **MUST NOT hold a second copy of the inline-image scanner — the shared `MarkdownBlockParser.findInlineImages` is the one matcher** |
| M1-A-16 | **MUST derive every downstream sense vocabulary from `Sense.allCases`, never a re-typed literal** |
| M1-A-17 | **MUST be usable from both Mac and phone as one shared implementation** |
| M1-A-18 | **MUST NOT let structure detection see indentation — the trimmed probe is for structure, the raw line for storage** |
| M1-A-19 | **MUST accept the writer's title verbatim from the first `# ` heading, falling back only when absent** |
| M1-A-21 | **MUST be robust to arbitrary text, never trapping or throwing — `parse` is total** |
| M1-A-22 | **MUST keep ids out of the file: `researchItemId` is supplied by the caller** |
| M1-B-01 | **MUST round-trip a body containing an unknown `## ` heading (the parser must not truncate body at a heading-like line)** |
| M1-B-02 | **MUST round-trip a body line beginning `- ` as prose, not a list item** |
| M1-B-03 | **MUST have `parse(template(t, k))` recover exactly `t` and `k`** |
| M1-B-04 | **The `Sense` DECLARATION ORDER is load-bearing for downstream display grouping** |
| M1-B-06 | **The four body-byte-preservation cases are separately guaranteed: indentation, trailing spaces, leading extra blank, trailing extra blank** |
| M1-B-07 | **The round-trip law is enforced at MODEL granularity, never at BYTE granularity** |

## 6. What to deliver

1. The complete modified `PaletteCard.swift`.
2. Notes covering:
   - **(a)** every design decision the specification did not determine, and what you chose;
   - **(b)** any claim or clause your change makes false, quoted by id, and what you did about it;
   - **(c)** anything about this extension that you believe is a **trap** — a way an ordinary
     implementation would violate a rule stated above without the compiler or an obvious test
     noticing;
   - **(d)** what you would need to know to be more confident.

Be blunt. A long list is the desired outcome.

3. A final section `## CONTAMINATION SELF-REPORT` stating honestly whether you had any prior
   or injected context about this codebase before reading this brief, and whether anything
   outside this brief influenced your work. Answer truthfully even if it invalidates the run.