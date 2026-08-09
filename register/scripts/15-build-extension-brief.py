#!/usr/bin/env python3
"""Phase 15: build the EXTENSION brief — the real Naur test.

Unlike Phase 8's regeneration (rebuild what exists), this asks for a change that
does not exist anywhere: a new `## Textures` section. No prior knowledge of the
codebase can supply the answer, because there is no answer yet — which is what
makes this run resistant to the contamination that voided Phases 11-13.

The brief is claims + rulings + interfaces. No implementation, no test source.
"""
import json, sys, re

LEDGER = "register/01-claims-ledger.json"
OUT = "register/15-extension-brief.md"
SRC = "Packages/MaughamCore/Sources/MaughamCore/PaletteCard.swift"

d = json.load(open(LEDGER))
claims = [c for c in d["claims"] if c["claim_id"].startswith("M1")]
rulings = d["_meta"]["rulings"]

CLAUSES = {
 "M1-A-01": "MUST satisfy `parse(render(card)) == card` for any editor-reachable model",
 "M1-A-02": "MUST NOT let a body line spelling a KNOWN section heading survive as body — this residual is accepted, and the round trip converges from the second render",
 "M1-A-03": "MUST treat the model as owner of the file: re-rendering normalises hand edits rather than preserving them",
 "M1-A-04": "MUST preserve body bytes verbatim — indentation, trailing whitespace, interior blank-line runs — stripping only the renderer's single structural blank-line pad",
 "M1-A-05": "MUST NOT let an inline `![]()` in BODY prose enter `imagePaths`",
 "M1-A-06": "MUST NOT let a remote URL (`://`) enter `imagePaths`, regardless of section",
 "M1-A-07": "MUST capture `kind:` at most once, before any real section; a later `kind:`-looking line is ordinary body prose",
 "M1-A-08": "MUST degrade an unknown/missing `kind` to `.other` rather than failing",
 "M1-A-09": "MUST NOT emit an untagged note whose text is empty/whitespace-only — it cannot round-trip",
 "M1-A-10": "MUST keep a TAGGED note with empty text — `- smell: ` round-trips",
 "M1-A-11": "MUST validate swatches as `#RGB`/`#RRGGBB` and silently ignore others",
 "M1-A-12": "MUST normalise to canonical form on render: uppercase swatches, `./`-relative image paths, all sections always present",
 "M1-A-13": "MUST treat an unknown `##` heading before any real section as body, and after real structure as a dropped section",
 "M1-A-14": "MUST resolve card-relative image paths to project-relative on the way in and invert exactly on the way out",
 "M1-A-15": "MUST NOT hold a second copy of the inline-image scanner — the shared `MarkdownBlockParser.findInlineImages` is the one matcher",
 "M1-A-16": "MUST derive every downstream sense vocabulary from `Sense.allCases`, never a re-typed literal",
 "M1-A-17": "MUST be usable from both Mac and phone as one shared implementation",
 "M1-A-18": "MUST NOT let structure detection see indentation — the trimmed probe is for structure, the raw line for storage",
 "M1-A-19": "MUST accept the writer's title verbatim from the first `# ` heading, falling back only when absent",
 "M1-A-21": "MUST be robust to arbitrary text, never trapping or throwing — `parse` is total",
 "M1-A-22": "MUST keep ids out of the file: `researchItemId` is supplied by the caller",
 "M1-B-01": "MUST round-trip a body containing an unknown `## ` heading (the parser must not truncate body at a heading-like line)",
 "M1-B-02": "MUST round-trip a body line beginning `- ` as prose, not a list item",
 "M1-B-03": "MUST have `parse(template(t, k))` recover exactly `t` and `k`",
 "M1-B-04": "The `Sense` DECLARATION ORDER is load-bearing for downstream display grouping",
 "M1-B-06": "The four body-byte-preservation cases are separately guaranteed: indentation, trailing spaces, leading extra blank, trailing extra blank",
 "M1-B-07": "The round-trip law is enforced at MODEL granularity, never at BYTE granularity",
}

# ---- public surface, mechanically extracted, bodies and doc comments removed
src = open(SRC).read()
SIGNATURES = """```swift
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
```"""

CANONICAL = """```markdown
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
```"""

L = []
w = L.append
w("# Extension brief — add a `## Textures` section to the palette card")
w("")
w("You are extending a Swift type from its written specification, as a controlled experiment.")
w("**You have not seen, and will not be given, the implementation, its doc comments, or its")
w("tests.** Everything known about the required behaviour is in this document.")
w("")
w("## Your task")
w("")
w("Palette cards are plain-markdown research assets a writer keeps under `research/palette/`.")
w("Add a fourth section, `## Textures`, alongside Swatches / Senses / Images.")
w("")
w("A texture entry is a short free-text note about how something feels, optionally prefixed")
w("with a **material tag**. Unlike `Sense`, the material tag is an **arbitrary string**, not a")
w("closed set:")
w("")
w("```markdown")
w("## Textures")
w("")
w("- slate: cold underfoot, slightly damp")
w("- horsehair plaster: powders when you lean on it")
w("- everything here is gritty")
w("```")
w("")
w("Deliver the complete modified contents of `PaletteCard.swift` — the model, the parser and")
w("the renderer — with `textures` as a new stored property on `PaletteCard`. Choose the")
w("element type. `import Foundation` only.")
w("")
w("Then deliver your notes (see §6). **The notes matter more than the code.**")
w("")
w("## 1. The canonical card format today")
w("")
w(CANONICAL)
w("")
w("Title is the first `# ` heading (else a caller-supplied fallback). `kind:` is captured once,")
w("before any real section. Everything between `kind:` and the first real `##` is `body`.")
w("")
w("## 2. Public surface today")
w("")
w(SIGNATURES)
w("")
w("## 3. Rulings")
w("")
w("**These are binding.** They were made by the product owner, not derived from the code, and")
w("they take precedence over any claim below that appears to conflict with them.")
w("")
for rid, r in rulings.items():
    w(f"### {rid}")
    w("")
    w(f"> {r['statement']}")
    w("")
    w(f"- **Scope:** {r['scope']}")
    w(f"- **Rationale:** {r['rationale']}")
    w("")
w("## 4. Behavioural claims")
w("")
w("`warrant` = how well evidenced the claim is (`HIGH` = a dedicated test asserts it; `LOW` =")
w("observed behaviour nobody has ratified; `CORRECTED` = the claim was wrong and has been")
w("fixed). `verdict` = whether the behaviour is WANTED, per §3. The two are independent: a")
w("well-evidenced claim can still be a `DEFECT`.")
w("")
w("| id | scope | warrant | verdict | claim |")
w("|---|---|---|---|---|")
for c in sorted(claims, key=lambda x: x["claim_id"]):
    stmt = c["statement"].replace("|", "\\|")
    v = c.get("verdict", "UNRULED")
    w(f"| {c['claim_id']} | `{c['scope']}` | {c['warrant']} | {v} | {stmt} |")
w("")
w("## 5. Intent envelope")
w("")
w("| id | clause |")
w("|---|---|")
for cid in sorted(CLAUSES):
    w(f"| {cid} | **{CLAUSES[cid].replace('|', chr(92)+'|')}** |")
w("")
w("## 6. What to deliver")
w("")
w("1. The complete modified `PaletteCard.swift`.")
w("2. Notes covering:")
w("   - **(a)** every design decision the specification did not determine, and what you chose;")
w("   - **(b)** any claim or clause your change makes false, quoted by id, and what you did about it;")
w("   - **(c)** anything about this extension that you believe is a **trap** — a way an ordinary")
w("     implementation would violate a rule stated above without the compiler or an obvious test")
w("     noticing;")
w("   - **(d)** what you would need to know to be more confident.")
w("")
w("Be blunt. A long list is the desired outcome.")
w("")
w("3. A final section `## CONTAMINATION SELF-REPORT` stating honestly whether you had any prior")
w("   or injected context about this codebase before reading this brief, and whether anything")
w("   outside this brief influenced your work. Answer truthfully even if it invalidates the run.")

brief = "\n".join(L)

# leak guard — no implementation tokens, no verbatim doc-comment lines
BANNED = ["seenSectionHeading", "kindCaptured", "bodyLines", "imagesSectionLines",
          "omittingEmptySubsequences", "func resolve(path", "dropFirst(3)"]
leaks = [t for t in BANNED if t in brief]
if leaks:
    sys.exit(f"LEAK: implementation tokens in the brief: {leaks}")
for line in src.splitlines():
    s = line.strip()
    if s.startswith("///") or s.startswith("//"):
        body = s.lstrip("/ ").strip()
        if len(body) > 50 and body in brief:
            sys.exit(f"LEAK: doc-comment line reproduced: {body!r}")

open(OUT, "w").write(brief)
print(f"wrote {OUT}: {len(claims)} claims, {len(CLAUSES)} clauses, "
      f"{len(rulings)} rulings, {len(brief.splitlines())} lines")
print("leak guard: clean")
