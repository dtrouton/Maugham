# Report plan 5 — the table and the formula engine (Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** give MaughamCore a table model with stable row and column ids, an Excel-compatible formula engine over the spec's explicit function set, localised number and date formats, typed-input parsing, and CSV render and import. Plans 6–9 build on it.

**Architecture:** every piece is pure value code in a new `Packages/MaughamCore/Sources/MaughamCore/Table/` folder. There is no I/O, no UI and no op log. This plan stores nothing. Plan 6 derives a `FigureTable` from ops and writes the CSV render. Formulas store references by row and column id and render as A1. A `Workbook` holds a document's named tables, evaluates them through a dependency graph, and recalculates only what an edit touched.

**Tech Stack:** Swift 5.10, Foundation only (`Decimal`, `NumberFormatter`, `DateFormatter`, `Locale`, `Calendar`), XCTest. macOS 14 / iOS 17.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md`, §3.3, §3.4, §5 and §4.1's CSV rule. Read §5 in full before any task.

## Global Constraints

- Core is Apple frameworks only, with no UI imports. Cross-module API is `public`, and every public type is `Sendable`. Model types are `Codable` (plan 6 serialises them into ops).
- **The type name is `FigureTable`, never `Table`.** The app targets import SwiftUI, whose `Table` would collide.
- **Every new `.swift` file is listed on `Packages/MaughamCore/Sources/MaughamCore/AREA.md`'s Map**, under a new heading `### Tables and formulas` placed after `### Publishing and translation shared types`. `DocBudgetTests.test_everyCoreSourceFileIsOnTheCoreMap` fails otherwise.
  - Each task that adds Map words raises that file's ceiling in `DocBudgetTests.wordCeilings` by the exact count, prepending `+N report plan 5 Task K: <what>` to the existing comment.
  - No other ceiling may move.
- **Gate:** `./scripts/test.sh core` after every task. Never a bare `swift test`: the gate lock matters.
  - Plan-wide: `./scripts/test.sh` (Mac) and `./scripts/test.sh phone` must stay green at the whole-branch review. The phone compiles Core.
  - New Core files need no `./gen.sh` (SwiftPM finds them), but run it once before the Mac gate.
- **Excel parity is the contract (spec F5, §5).** Where this plan states a value, the value is Excel's. Never loosen a tolerance or change an expected value to make a test pass. A disagreement means the code is wrong, or this plan is, and the implementer reports it.
- **No volatile results:** nothing reads the clock, a random source or `Locale.current` except where a parameter defaults to it and the tests pass it explicitly.
- **Spec rulings made while writing this plan** (already written into the spec):
  - Row and column ids are 8 characters from the `¶id` alphabet.
  - A research CSV's unsupported function stays a formula and shows `#NAME?`. An unparseable formula becomes text and is reported.

## Review Focus

These are the inputs most likely to bite a person. Each one has its test in the owning task.

1. **Binary floating point leaking into what the writer sees.** `0.1+0.2` must display `0.3`, and `ROUND(2.675, 2)` must give `2.68` (Excel's answer, not binary's `2.67`). Tasks 3 and 7.
2. **Excel's operator precedence:** `=-2^2` is `4` (negation binds tighter than `^`), `=2^-1` is `0.5`, and `=10%*50` is `5`. Tasks 2 and 3.
3. **Numbers typed or pasted in the book's language:** `1.234,5` in Spanish is 1234.5, `1,234.5` in English is the same, and `1.5` in Spanish is 1.5 (not a grouping). `03/04/2026` is 3 April in en-GB and March 4 in en-US. Task 8.
4. **Deleting the first or last row of a `SUM` range shrinks the range,** as in Excel, rather than turning it into `#REF!`. Deleting a single referenced cell is `#REF!`. Tasks 1, 2 and 6.
5. **A cycle,** including a self-reference and one running through two tables, yields `#CIRC!` on every cell in it and never hangs or recurses unboundedly. Task 6.

---

### Task 1: The table model and its ids

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/Table/TableIDs.swift`, `CellValue.swift`, `CellFormat.swift`, `FigureTable.swift` (all under `Table/`)
- Modify: `Packages/MaughamCore/Sources/MaughamCore/AREA.md` (new Map heading, four rows), `Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift` (ceiling)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/FigureTableTests.swift`

**Interfaces — Produces** (later tasks use these names exactly):

```swift
public struct RowID: Hashable, Codable, Sendable { public let raw: String; public init(_ raw: String) }
public struct ColumnID: Hashable, Codable, Sendable { public let raw: String; public init(_ raw: String) }
public enum TableID {
    /// 8 characters from ParagraphID's alphabet ("0123456789abcdefghjkmnpqrstvwxyz"), never one in `used`.
    public static func mint(excluding used: Set<String>) -> String
}
public struct CellKey: Hashable, Codable, Sendable { public let row: RowID; public let column: ColumnID; public init(row:column:) }

public enum FormulaError: String, Codable, Sendable, CaseIterable {
    case divideByZero = "#DIV/0!", ref = "#REF!", name = "#NAME?", value = "#VALUE!", num = "#NUM!", circular = "#CIRC!"
}
public enum CellValue: Equatable, Codable, Sendable {
    case empty, number(Double), date(Int) /* Excel serial day, 1900 system */, text(String), bool(Bool), error(FormulaError)
}
public enum CellContent: Equatable, Codable, Sendable { case value(CellValue), formula(Formula) }   // Formula: Task 2
public struct Cell: Equatable, Codable, Sendable {
    public var content: CellContent; public var format: CellFormat; public var alignment: CellAlignment
    public init(content: CellContent, format: CellFormat = .init(), alignment: CellAlignment = .automatic)
}

public enum DateStyle: String, Codable, Sendable { case day, month, quarter, year, iso }
public enum NumberFormat: Equatable, Codable, Sendable {
    case general
    case number(decimals: Int, grouping: Bool)
    case percent(decimals: Int)
    case currency(symbol: String?, decimals: Int)   // nil = the locale's symbol
    case compact(decimals: Int)
    case date(DateStyle)
}
public enum NegativeStyle: String, Codable, Sendable { case minus, parentheses }
public struct CellFormat: Equatable, Codable, Sendable {
    public var number: NumberFormat = .general; public var negatives: NegativeStyle = .minus; public var zeroAsDash = false
    public init(number: NumberFormat = .general, negatives: NegativeStyle = .minus, zeroAsDash: Bool = false)
}
public enum CellAlignment: String, Codable, Sendable { case automatic, left, center, right }

public struct FigureTable: Equatable, Codable, Sendable {
    public struct Slot<ID: Hashable & Codable & Sendable>: Equatable, Codable, Sendable { public let id: ID; public var isDeleted: Bool }
    public private(set) var rowSlots: [Slot<RowID>]          // order, tombstones included
    public private(set) var columnSlots: [Slot<ColumnID>]
    public private(set) var cells: [CellKey: Cell]
    public var headerRows: Int          // 0 or 1 (clamped)
    public var hasTotalRow: Bool
    public var columnWidths: [ColumnID: Double]
    public init(rows: Int, columns: Int)                      // mints ids; headerRows 0, no total row
    public var rows: [RowID] { get }                          // live, in order
    public var columns: [ColumnID] { get }
    public func rowIndex(of id: RowID) -> Int?                // live position, nil if deleted/unknown
    public func columnIndex(of id: ColumnID) -> Int?
    public func rowSlotIndex(of id: RowID) -> Int?            // position among ALL slots (tombstones too)
    public func columnSlotIndex(of id: ColumnID) -> Int?
    public subscript(key: CellKey) -> Cell? { get }
    public mutating func setCell(_ cell: Cell?, at key: CellKey)   // nil clears; ignored for a deleted/unknown row or column
    @discardableResult public mutating func insertRow(after: RowID?) -> RowID          // nil = top; mints
    public mutating func insertRow(_ id: RowID, after: RowID?)     // plan 6 replays a minted id; no-op if id already present
    @discardableResult public mutating func insertColumn(after: ColumnID?) -> ColumnID
    public mutating func insertColumn(_ id: ColumnID, after: ColumnID?)
    public mutating func deleteRow(_ id: RowID)                // tombstone: slot stays, its cells are removed
    public mutating func deleteColumn(_ id: ColumnID)
    public mutating func moveRow(_ id: RowID, after: RowID?)   // live rows only; the slot moves
    public mutating func moveColumn(_ id: ColumnID, after: ColumnID?)
}
```

**Contract notes:**
- **`after:` names a slot,** live or tombstoned, and the new slot goes immediately after it. An unknown `after` inserts at the end, never crashes. Plan 6 replays inserts from other devices that may name a row deleted here.
- **Tombstones are why ranges survive deletes** (Review Focus 4): a range's edges keep a position even when deleted (Task 2). Tombstones are never compacted in this plan.
- **Minting** excludes every id in both slot lists, tombstones included.
- **`init(rows:columns:)`** with 0 is allowed (an empty table).

- [ ] **Step 1: Write the failing tests.** `FigureTableTests`:
  - `test_mint_isEightCharactersOfTheParagraphAlphabet_andAvoidsUsed`: 1,000 mints with a growing `used` set are all unique, each 8 characters, each character in the alphabet.
  - `test_init_mintsDistinctIdsInOrder`: `FigureTable(rows: 3, columns: 2)` → 3 rows, 2 columns, 5 distinct raw ids.
  - `test_insertRow_afterTombstone_landsAfterIt`: rows a b c, delete b, insert x after b → live order a x c; `rowSlotIndex(x) == rowSlotIndex(b) + 1`.
  - `test_insertRow_unknownAfter_appends`, and `test_insertRow_replayedID_isIdempotent`.
  - `test_deleteRow_removesItsCells_keepsSlot`: set a cell in b, delete b → `cells` holds no key with row b; `rowIndex(b) == nil`; `rowSlotIndex(b) != nil`.
  - `test_setCell_onDeletedRow_isIgnored`.
  - `test_moveRow_changesLiveOrder`: a b c, move a after c → b c a.
  - `test_headerRows_clampsToZeroOrOne`.
  - `test_codableRoundTrip`: a table with tombstones, cells of every `CellValue` case and non-default formats encodes and decodes equal. `CellContent.formula` can only be tested once Task 2 lands; add that case in Task 2.
- [ ] **Step 2:** `./scripts/test.sh core` → FAIL (types missing).
- [ ] **Step 3: Implement** the four files. `CellContent.formula(Formula)` needs `Formula`, so add a minimal `public struct Formula: Equatable, Codable, Sendable {}` placeholder in `Table/Formula.swift` and put it on the Map now. Task 2 replaces its body.
- [ ] **Step 4:** `./scripts/test.sh core` → PASS. Add the Map heading and rows, one line each, for example:
  - "`FigureTable.swift` — a table's rows and columns as ordered id slots with tombstones, its cells, header/total rows; the model plan 6 derives from ops."
  - Raise the ceiling as the Global Constraints describe, and re-run.
- [ ] **Step 5: Commit:** `core: figure table model — row and column ids with tombstones, cell values and formats (report plan 5 Task 1)`.

---

### Task 2: A1 addresses and formula syntax

**Files:**
- Create: `Table/CellAddress.swift`, `Table/FormulaParser.swift`; replace the body of `Table/Formula.swift`
- Modify: AREA.md Map, DocBudgetTests ceiling
- Test: `FormulaParserTests.swift`, `CellAddressTests.swift`

**Interfaces — Produces:**

```swift
public enum A1 {
    public static func columnLetters(_ index: Int) -> String          // 0 → "A", 25 → "Z", 26 → "AA", 701 → "ZZ", 702 → "AAA"
    public static func columnIndex(_ letters: String) -> Int?         // inverse; case-insensitive; nil for non-letters
    public static func parse(_ text: String) -> (row: Int, column: Int, rowAbsolute: Bool, columnAbsolute: Bool)?  // "$B$2" → (1, 1, true, true); 0-based
}

public enum RefTarget: Hashable, Codable, Sendable { case this, figure(name: String), research(name: String) }
public enum RefAnchor: Hashable, Codable, Sendable {
    case id(row: RowID, column: ColumnID)     // this / figure, when resolvable at entry
    case position(row: Int, column: Int)      // research always; a figure ref read from a CSV
}
public struct FormulaRef: Hashable, Codable, Sendable { public var target: RefTarget; public var anchor: RefAnchor; public var rowAbsolute: Bool; public var columnAbsolute: Bool }
public struct FormulaRange: Hashable, Codable, Sendable { public var start: FormulaRef; public var end: FormulaRef }   // same target
public enum UnaryOperator: String, Codable, Sendable { case negate, plus, percent }
public enum BinaryOperator: String, Codable, Sendable { case add, subtract, multiply, divide, power, equal, notEqual, less, greater, lessOrEqual, greaterOrEqual }
public indirect enum FormulaExpr: Equatable, Codable, Sendable {
    case number(Double), text(String), bool(Bool), missing          // `missing` = an empty argument: PV(r, n, , 0)
    case ref(FormulaRef), range(FormulaRange)
    case unary(UnaryOperator, FormulaExpr), binary(BinaryOperator, FormulaExpr, FormulaExpr)
    case call(name: String, arguments: [FormulaExpr])               // name uppercased; unknown names are kept
    case error(FormulaError)                                        // a ref that fell off the grid in a fill
}
public struct Formula: Equatable, Codable, Sendable { public var expr: FormulaExpr; public init(_ expr: FormulaExpr) }

public struct FormulaParseError: Error, Equatable, Sendable { public let message: String; public let offset: Int }   // writer-facing message
public enum FormulaParser {
    /// `text` is what follows the "=". `table` resolves unqualified refs to ids; `figures` resolves `name!B2`.
    public static func parse(_ text: String, in table: FigureTable, figures: [String: FigureTable] = [:]) -> Result<Formula, FormulaParseError>
    /// Positional parse for a CSV: every ref is `.position`, no table needed (Task 9).
    public static func parsePositional(_ text: String) -> Result<Formula, FormulaParseError>
    /// The formula as A1 text (no leading "="), by current positions.
    public static func render(_ formula: Formula, in table: FigureTable, figures: [String: FigureTable] = [:]) -> String
    /// Fill/copy: relative parts shift by the live-position delta from `from` to `to`.
    public static func translate(_ formula: Formula, from: CellKey, to: CellKey, in table: FigureTable) -> Formula
}
```

**Grammar** (Excel's precedence, from loosest to tightest):
1. comparison `= <> < > <= >=`
2. `+ -`
3. `* /`
4. `^` (left-associative, as in Excel: `2^3^2` = 64)
5. postfix `%`
6. prefix `- +`
7. primary: number, `"text"` (`""` is a quote), `TRUE`/`FALSE`, ref, range `A1:B2`, `name!A1`, `name!A1:B2`, `research:name!A1`, a function call, `( … )`

Further rules:
- Prefix binds tighter than `^`, so `-2^2` parses as `(-2)^2`.
- Whitespace is allowed between tokens.
- Figure names match `[A-Za-z0-9_-]+`; research names match `[A-Za-z0-9 _.-]+` and may be quoted, as in `research:'model v3'!B2`.
- Function names are case-insensitive. Arguments are separated by `,`, and an empty argument is `.missing`.

**Contract notes:**
- **Entry resolves refs to ids.** An unqualified ref resolves against `table`; one outside its live grid fails with `"B12 is outside this table"`. `name!B2` with an unknown name fails with `"There is no table named name"`. A research ref is never bounds-checked.
- **Rendering tombstoned refs.** A single ref whose row or column is tombstoned renders `#REF!`.
  - A range edge on a tombstone renders as the nearest live slot moving inward, toward the other edge. That's Excel's shrink.
  - A range with no live slot between its edges renders `#REF!`.
  - Render the same way for a figure target against `figures`, and a figure missing from `figures` renders `name!#REF!`.
- **Translate** shifts relative row and column positions, and leaves `$` parts alone. A result outside the live grid becomes `.error(.ref)` for that ref, or for the whole range if either edge falls off.
- **Number literals render** as integers without `.0` when integral and below 1e15, otherwise up to 15 significant digits, trailing zeros trimmed, never `e` notation below 1e15.

- [ ] **Step 1: Write the failing tests.**
  - `CellAddressTests`: the five `columnLetters` values above and their inverses; `parse("$B$2")`, `parse("b2")` → (1, 1, false, false); `parse("A0") == nil`; `parse("2B") == nil`.
  - `FormulaParserTests`, against a 4×3 table:
    - `test_precedence_negationBeforePower`: `-2^2` → `.binary(.power, .unary(.negate, 2), 2)`.
    - `test_power_isLeftAssociative`: `2^3^2`.
    - `test_percentPostfix`: `10%*50`.
    - `test_comparison_isLoosest`: `1+1=2`.
    - `test_rangeAndAbsolute`: `SUM($A$1:B3)` resolves its anchors to the right ids with absolute flags.
    - `test_unknownFunction_parses` (`VLOOKUP(A1)`).
    - `test_emptyArgument_isMissing` (`PV(1,2,,0)`).
    - `test_outsideTable_fails_withMessage` (`D9`), and `test_unknownFigure_fails`.
    - `test_researchRef_isPositional_quotedName`.
    - `test_render_roundTrips` for 12 formulas: the parse → render text equals the input, with case normalised to uppercase function names and refs.
    - `test_render_afterDeletingRangeEdge_shrinks`: `SUM(A1:A4)`; delete row 4 → `SUM(A1:A3)`; delete row 1 → `SUM(A1:A2)`, the old A2:A3 now at A1:A2.
    - `test_render_afterDeletingSingleRef_isREF`.
    - `test_render_rangeWhollyDeleted_isREF`.
    - `test_translate_fillDown`: `A1+$B$1` from C1 to C2 → `A2+$B$1`.
    - `test_translate_offGrid_isREF`.
    - `test_formulaCodableRoundTrip`. Also extend `FigureTableTests.test_codableRoundTrip` with a formula cell.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** implement a hand-written recursive-descent parser (no regex for the grammar), the renderer and translate.
- [ ] **Step 4:** run → PASS. Add the Map rows and the ceiling.
- [ ] **Step 5: Commit:** `core: formula syntax — Excel precedence, refs stored by id and rendered as A1, ranges that shrink on delete, fill translation (report plan 5 Task 2)`.

---

### Task 3: The evaluator, totals, rounding, logic and conditional totals

**Files:**
- Create: `Table/FormulaEvaluator.swift`, `Table/FormulaFunctions.swift`, `Table/ExcelRounding.swift`
- Modify: Map, ceiling
- Test: `FormulaEvaluatorTests.swift`, `FormulaFunctionsTests.swift`

**Interfaces — Produces:**

```swift
public enum FormulaArgument: Sendable { case scalar(CellValue), range([[CellValue]]), missing }
public struct FormulaEnvironment: Sendable {
    public var cell: @Sendable (FormulaRef) -> CellValue
    public var range: @Sendable (FormulaRange) -> [[CellValue]]?      // nil = the range is #REF!
    public init(cell:range:)
}
public enum FormulaEvaluator {
    public static func evaluate(_ formula: Formula, in env: FormulaEnvironment) -> CellValue
}
public enum ExcelRounding {
    /// Excel ROUND: half away from zero on the value's 15-significant-digit decimal form.
    public static func round(_ x: Double, digits: Int) -> Double
    public static func roundUp(_ x: Double, digits: Int) -> Double      // away from zero
    public static func roundDown(_ x: Double, digits: Int) -> Double    // toward zero
}
```

Function dispatch lives in `FormulaFunctions` as a table of name → implementation taking `[FormulaArgument]`. Tasks 4 and 5 add entries to it. Unknown names give `#NAME?`.

**Semantics (Excel's, which the tests pin):**
- **Arithmetic operands:**
  - number as is; date as its serial; `TRUE` = 1; empty = 0;
  - text that reads as a plain number (`"3"`, `"-1.5"`, `"1e3"`, POSIX) coerces, any other text is `#VALUE!`;
  - an error propagates, the left operand's first.
- **Arithmetic results:**
  - date ± number → `.date`; date − date → `.number`; any other arithmetic with a date → `.number`;
  - `/0` → `#DIV/0!`;
  - `0^0` → `#NUM!`; a negative base with a non-integer exponent → `#NUM!`;
  - a non-finite result → `#NUM!`.
- **Comparison:**
  - numbers (dates as serials) < text < booleans;
  - text compares case-insensitively;
  - empty equals `0`, `""` and `FALSE` against those types.
- **Range arguments** to `SUM AVERAGE MIN MAX COUNT MEDIAN`: only numbers and dates count; text, booleans and empties are skipped; the first error in row-major order propagates.
  - Direct scalar arguments count numbers, dates, booleans and numeric text. Non-numeric text is `#VALUE!`, except in `COUNT`, which ignores it.
  - `AVERAGE` with nothing → `#DIV/0!`; `MIN`/`MAX` with nothing → `0`; `MEDIAN` with nothing → `#NUM!`.
  - A range in a scalar position (`=A1:A3+1`) → `#VALUE!` (no implicit intersection).
- **`ROUND`, `ROUNDUP`, `ROUNDDOWN`, `ABS`:**
  - `ROUND(2.675, 2) = 2.68`, `ROUND(-2.5, 0) = -3`, `ROUND(1234.5, -2) = 1200`;
  - `ROUNDUP(3.141, 2) = 3.15`, `ROUNDUP(-3.141, 2) = -3.15`, `ROUNDDOWN(-3.149, 2) = -3.14`;
  - implement via `Decimal(string: String(format: "%.15g", x))`, then `NSDecimalRound` with `.plain`, `.up` or `.down` on the magnitude.
- **`IF(c, a, [b])`:**
  - number ≠ 0 is true; empty is false; text is `#VALUE!`;
  - a missing `b` → `FALSE`; a missing `a` (`IF(c,,1)`) → `0`.
- **`IFERROR(v, alt)`:** `alt` when `v` is any error.
- **`SUMIF(range, criteria, [sum])`, `COUNTIF(range, criteria)`, `AVERAGEIF(range, criteria, [avg])`:**
  - A numeric criteria matches equal numbers.
  - A string criteria may start with `= <> < > <= >=`. A numeric operand compares numerically, matching only number or date cells. A text operand compares case-insensitively, with `*`, `?` and `~` (escape) wildcards for `=` and `<>`.
  - `""` matches empty cells; `"<>"` matches non-empty ones.
  - `sum`/`avg` take `range`'s shape from their own top-left, clipped to their size.
  - `AVERAGEIF` with no match → `#DIV/0!`.

- [ ] **Step 1: Write the failing tests.** Build a `FormulaEnvironment` over a dictionary of A1 → value in the test (a small helper in the test file). Every bullet above gets at least one assertion, plus these exact cases:
  - `=0.1+0.2` evaluates to a number whose `ExcelRounding.round(_, 15)` is `0.3`. Display is Task 7.
  - `=-2^2` = 4; `=2^-1` = 0.5; `=10%*50` = 5; `="3"+1` = 4; `="a"+1` = `#VALUE!`.
  - `=SUM(A1:A4)` over [1, "x", TRUE, 2] = 3; `=SUM(1, TRUE, "2")` = 4; `=COUNT(A1:A4)` over the same = 2; `=AVERAGE(A1:A2)` over [empty, "x"] = `#DIV/0!`.
  - `=MEDIAN(A1:A4)` over [1, 2, 3, 4] = 2.5.
  - `=SUMIF(A1:A4, ">2")` over [1, 2, 3, 4] = 7; `=COUNTIF(A1:A4, "n*")` over ["North", "south", "NE", "Norway"] = 3; `=COUNTIF(A1:A3, "~*")` over ["*", "a", "**"] = 1; `=SUMIF(A1:A3, "north", B1:B3)` with B = [10, 20, 30] and A = ["North", "West", "NORTH"] = 40.
  - `=IF(A1>100, "Over", "Under")`; `=IFERROR(1/0, "—")` = "—"; `=1/0` = `#DIV/0!`; `=NOSUCH(1)` = `#NAME?`.
  - `=A1:A2+1` = `#VALUE!`.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** run → PASS, then the Map and ceiling.
- [ ] **Step 5: Commit:** `core: formula evaluator — Excel coercion and comparison, totals, ROUND on the decimal form, IF/IFERROR, the …IF criteria with wildcards (report plan 5 Task 3)`.

---

### Task 4: Finance — cash flows, annuities, growth

**Files:**
- Create: `Table/FinanceFunctions.swift`
- Modify: `Table/FormulaFunctions.swift` (register the names), Map, ceiling
- Test: `FinanceFunctionsTests.swift`

**Interfaces — Produces** (pure numerics, also registered as formula functions):

```swift
public enum Finance {
    public static func npv(rate: Double, _ flows: [Double]) -> Result<Double, FormulaError>
    public static func irr(_ flows: [Double], guess: Double = 0.1) -> Result<Double, FormulaError>
    public static func mirr(_ flows: [Double], financeRate: Double, reinvestRate: Double) -> Result<Double, FormulaError>
    public static func pv(rate: Double, periods: Double, payment: Double, future: Double = 0, atStart: Bool = false) -> Result<Double, FormulaError>
    public static func fv(rate: Double, periods: Double, payment: Double, present: Double = 0, atStart: Bool = false) -> Result<Double, FormulaError>
    public static func pmt(rate: Double, periods: Double, present: Double, future: Double = 0, atStart: Bool = false) -> Result<Double, FormulaError>
    public static func nper(rate: Double, payment: Double, present: Double, future: Double = 0, atStart: Bool = false) -> Result<Double, FormulaError>
    public static func rate(periods: Double, payment: Double, present: Double, future: Double = 0, atStart: Bool = false, guess: Double = 0.1) -> Result<Double, FormulaError>
    public static func cagr(start: Double, end: Double, years: Double) -> Result<Double, FormulaError>
}
```

**Formula argument rules (Excel):**
- `NPV(rate, v1, …)`: values from ranges count numbers only (text, booleans, empties and dates are ignored); direct arguments count numbers, booleans and numeric text; errors propagate. `IRR`/`MIRR` take one range or array, and only numbers count.
- `type` is truthy → payments at the start of each period. `.missing` arguments take the default.

**Closed forms:**
- **`PV`:** with r = 0, −(fv + pmt·n); otherwise −(fv + pmt·(1+r·t)·((1+r)ⁿ−1)/r)/(1+r)ⁿ.
- **`FV`:** with r = 0, −(pv + pmt·n); otherwise −(pv·(1+r)ⁿ + pmt·(1+r·t)·((1+r)ⁿ−1)/r).
- **`PMT`:** with r = 0, −(pv+fv)/n; otherwise −r·(fv + pv·(1+r)ⁿ)/((1+r·t)·((1+r)ⁿ−1)).
- **`NPER`:** with r = 0, −(pv+fv)/pmt; otherwise ln((pmt·(1+r·t) − fv·r)/(pmt·(1+r·t) + pv·r))/ln(1+r). A non-positive log argument → `#NUM!`.
- **`NPV`:** Σ vᵢ/(1+r)ⁱ for i from 1. r = −1 → `#DIV/0!`.
- **`MIRR`:** with n flows, ((−NPV(rr, positives)·(1+rr)ⁿ)/(NPV(fr, negatives)·(1+fr)))^(1/(n−1)) − 1, where NPV here uses each flow's own period index (zeros keep their slot). Fewer than one positive and one negative → `#DIV/0!`.
- **`CAGR`:** (end/start)^(1/years) − 1. start = 0 or years = 0 → `#DIV/0!`; a negative ratio with a non-integer exponent → `#NUM!`.

**Iteration (`IRR`, `RATE`):**
- Newton's method from `guess`, with an analytic derivative, at most 100 steps, converged when |step| < 1e-10.
- If Newton fails (it diverges, the derivative is 0, or a rate ≤ −1), bracket and bisect on (−0.999999, 10).
- No sign change in the flows (IRR), or no root found → `#NUM!`.

Excel gives up after 20 iterations, so where Excel converges we must give its root. Where Excel fails we may still answer. That's a ruling; record it in the ledger.

- [ ] **Step 1: Write the failing tests.** These are Microsoft's documented function examples (the values are Excel's), written at the precision Microsoft shows. Assert within half a unit of the last digit shown. Every iterative result also asserts its defining property, which is exact:
  - `NPV(10%, -10000, 3000, 4200, 6800)` = 1188.44.
  - `NPV(8%, 8000, 9200, 10000, 12000, 14500) + (-40000)` = 1922.06; with an extra `-9000` flow → −3749.47.
  - `IRR(-70000, 12000, 15000, 18000, 21000)` ≈ −0.021245 (Microsoft: −2.1%).
  - `IRR(-70000, 12000, 15000, 18000, 21000, 26000)` ≈ 0.086631 (8.7%).
  - `IRR(-70000, 12000, 15000, guess: -0.1)` ≈ −0.443507 (−44.4%).
  - **For every IRR:** also assert the defining property, |NPV at the result of the flows with the first undiscounted| < 1e-6 × the largest flow.
  - `MIRR(-120000, 39000, 30000, 21000, 37000, 46000; 10%, 12%)` ≈ 0.12609; the first four flows (Microsoft's A2:A5) ≈ −0.04804; reinvesting at 14% ≈ 0.13476.
  - `PMT(8%/12, 10, 10000)` = −1037.03; with `type` 1 → −1030.16.
  - `PV(8%/12, 240, 500)` = −59777.15.
  - `FV(6%/12, 10, -200, -500, 1)` = 2581.40.
  - `NPER(12%/12, -100, -1000, 10000, 1)` = 59.6738657; without `type` → 60.0821229; with pv only (`NPER(1%, -100, -1000)`) → −9.57859404.
  - `RATE(48, -200, 8000)` ≈ 0.0077 (Microsoft shows 1% monthly and 9.24% a year; assert ×12 ≈ 0.0924). Also assert PV(result, 48, −200) ≈ 8000 within 1e-6.
  - `CAGR(100, 150, 3)` ≈ 0.144714; `CAGR(0, 1, 1)` = `#DIV/0!`.
  - Zero-rate branches: `PMT(0, 10, 1000)` = −100; `PV(0, 10, -100)` = 1000; `NPER(0, -100, 1000)` = 10.
  - `IRR(100, 200)` = `#NUM!` (no sign change); `NPV(-1, 1)` = `#DIV/0!`.
  - Formula level: `=NPV(B1, C1:F1)` over a range holding text and an empty, which are ignored; `=PV(1%, 12, , 1000)` (a missing payment) = −887.449; `=PMT(8%/12, 10, 10000, , TRUE)` uses `type` 1.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS; Map and ceiling.
- [ ] **Step 5: Commit:** `core: finance functions — NPV, IRR, MIRR and the annuity family to Excel's documented values, CAGR (report plan 5 Task 4)`.

---

### Task 5: Dates — serials, date arithmetic, `YEAR`, `MONTH`, `EDATE`, `XNPV`, `XIRR`

**Files:**
- Create: `Table/DateSerial.swift`, `Table/DateFunctions.swift`
- Modify: `FormulaFunctions.swift` (register), Map, ceiling
- Test: `DateSerialTests.swift`, `DateFunctionsTests.swift`

**Interfaces — Produces:**

```swift
public enum DateSerial {
    public static let earliest: Int   // serial of 1900-03-01 (61)
    public static let latest: Int     // serial of 9999-12-31 (2958465)
    public static func serial(year: Int, month: Int, day: Int) -> Int?     // nil outside earliest...latest or invalid
    public static func components(_ serial: Int) -> (year: Int, month: Int, day: Int)?
    public static func isoString(_ serial: Int) -> String                   // "2026-10-24"
    public static func serial(iso: String) -> Int?
    public static func addingMonths(_ months: Int, to serial: Int) -> Int?  // EDATE: day clamped to month end
}
```

- **Serial = days since 1899-12-30,** proleptic Gregorian, computed arithmetically with no `Calendar` and no time zones. Below 1900-03-01 isn't supported (`nil` → `#NUM!`), so Excel's 1900 leap-year bug never matters.
- **Formula functions:**
  - `YEAR(d)` and `MONTH(d)` take a date or a number (a serial).
  - `EDATE(d, months)` returns `.date`, truncating `months`.
  - `XNPV(rate, values, dates)` = Σ vᵢ/(1+r)^((dᵢ−d₀)/365). `values` and `dates` must have the same count, else `#NUM!`; any date before d₀ → `#NUM!`.
  - `XIRR(values, dates, [guess])` solves XNPV = 0 the same way as Task 4's IRR, with no sign change → `#NUM!`.
  - Dates in ranges for `XNPV`/`XIRR` may be `.date` or numbers.
- **Date arithmetic** is Task 3's evaluator (serials). This task adds calendar meaning.

- [ ] **Step 1: Write the failing tests:**
  - `serial(2008, 1, 1)` = 39448; `serial(2026, 10, 24)` = 46319; `serial(1900, 3, 1)` = 61; `serial(1900, 2, 28) == nil`; `serial(2026, 2, 29) == nil`; `components(46319)` = (2026, 10, 24); round-trip every 37th day across 1900-03-01…2100-12-31.
  - `addingMonths(1, to: 2026-01-31)` → 2026-02-28; `(1, 2024-01-31)` → 2024-02-29; `(-1, 2026-03-31)` → 2026-02-28; `(12, 2025-02-28)` → 2026-02-28.
  - Formula level, with dates as `.date` cells:
    - `=B1-A1` (2026-10-24 minus 2026-01-01) = `.number(296)`; `=A1+30` → `.date`;
    - `=YEAR(A1)`, `=MONTH(A1)`; `=EDATE(A1, 3)` → `.date`.
  - `XNPV(0.09; -10000, 2750, 4250, 3250, 2750; 2008-01-01, 2008-03-01, 2008-10-30, 2009-02-15, 2009-04-01)` = 2086.65 (Microsoft's example).
  - `XIRR` of the same flows ≈ 0.373362535 (within 1e-6), and XNPV at that rate ≈ 0.
  - `XNPV` with mismatched counts = `#NUM!`.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS; Map and ceiling.
- [ ] **Step 5: Commit:** `core: dates in formulas — 1900-system serials, EDATE, YEAR, MONTH, XNPV and XIRR to Excel's documented values (report plan 5 Task 5)`.

---

### Task 6: The workbook — tables that reference each other, research pins, recalculation, cycles

**Files:**
- Create: `Table/Workbook.swift`, `Table/DependencyGraph.swift`
- Modify: Map, ceiling
- Test: `WorkbookTests.swift`

**Interfaces — Produces:**

```swift
public struct CellAddress: Hashable, Codable, Sendable { public let table: String; public let key: CellKey }
public protocol ResearchPinSource: Sendable {
    /// The pinned value of a research cell (0-based position), or nil when no pin exists (→ #REF!). Plan 6 implements it.
    func pinnedValue(research name: String, row: Int, column: Int) -> CellValue?
}
public enum FormulaNote: Hashable, Sendable {
    case npvFirstFlowDiscounted(CellAddress)   // spec §5: an NPV whose first value is negative
}
public struct Workbook: Sendable {
    public init(pins: ResearchPinSource)
    public private(set) var tables: [String: FigureTable]
    /// Adds, replaces or (nil) removes a table, recalculating what changed. Returns every address whose VALUE changed.
    @discardableResult public mutating func setTable(_ table: FigureTable?, named name: String) -> Set<CellAddress>
    /// After plan 6 refreshes pins: recalculates every cell that reads the named research item.
    @discardableResult public mutating func pinsChanged(research name: String) -> Set<CellAddress>
    public func value(at address: CellAddress) -> CellValue          // .empty for a missing cell or table
    public var notes: Set<FormulaNote> { get }
    /// Which cells read which research items, directly or through another table (spec §4.3's markers).
    public func researchReaders() -> [CellAddress: Set<String>]
    /// Test seam: how many formula cells the last setTable/pinsChanged evaluated.
    public var lastEvaluationCount: Int { get }
}
```

**Contract notes:**
- **Resolution.** `.this` resolves against the formula's own table; `.figure(name)` against `tables[name]` (missing → `#REF!`); `.research` against `pins`.
  - `.position` anchors resolve by live position. Ranges collect the live slots between the edges' slot indices, which gives the shrink.
  - A single ref to a tombstone → `#REF!`.
- **Dependencies.** A formula depends on each cell it names, and on every live cell its ranges cover.
- **Structural changes.** If a table's row or column slots change, every formula in that table, and every formula elsewhere that references it, is re-resolved.
- **Content changes.** Otherwise only cells whose `content` changed, plus their transitive dependents, are re-evaluated. Formats never trigger recalculation.
- **Order and cycles.** Evaluate in topological order. Detect cycles with Tarjan's strongly connected components, iteratively, with no recursion depth proportional to the table. Every cell in a cycle (or a self-reference) gets `.error(.circular)`. Cells depending on a cycle get `#CIRC!` too, as an error propagating.
- **The NPV note** fires when an `NPV` call's first value argument is a range whose first counted number is negative, or a direct negative literal or reference.

- [ ] **Step 1: Write the failing tests:**
  - `test_crossTableReference_isLive`: `summary!B1 = cashflow!E5`; edit `cashflow` E5 → the returned set contains the summary address and its value updates.
  - `test_researchRef_readsPin_andPinsChangedRecalculates`: a stub `ResearchPinSource`.
  - `test_missingResearchPin_isREF`, and `test_missingFigure_isREF`.
  - `test_deleteRangeEdgeRow_shrinksSum`: `SUM(B1:B4)` = 10 over 1, 2, 3, 4; delete row 4 → 6, not `#REF!`. Deleting a singly referenced row → `#REF!`.
  - `test_insertRowInsideRange_grows`: insert a row between B2 and B3, set it to 5 → the sum includes it.
  - `test_selfReference_isCIRC`; `test_twoTableCycle_isCIRC_onBoth`; `test_dependentOfCycle_isCIRC`; `test_cycleBroken_recovers`.
  - `test_editOneCell_evaluatesOnlyItsDependents`: a 1,000×10 table whose column J is `=SUM(A{r}:I{r})` per row, and a total row summing J. Editing A500 → `lastEvaluationCount == 2` (J500 and the total). This is a counting budget, never a wall clock.
  - `test_formatChange_evaluatesNothing`.
  - `test_npvFirstFlowNote` fires for `=NPV(8%, B1:F1)` with B1 negative, and not for `=B1+NPV(8%, C1:F1)`.
  - `test_researchReaders_followsThroughTables`: summary reads cashflow, which reads research model-v3 → summary's cell is listed with "model-v3".
  - `test_deepChain_noStackOverflow`: a 20,000-cell chain `A{n} = A{n-1}+1` evaluates.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS; Map and ceiling.
- [ ] **Step 5: Commit:** `core: workbook — live cross-table references, research pins, incremental recalculation by dependency graph, cycles as #CIRC!, the NPV first-flow note (report plan 5 Task 6)`.

---

### Task 7: Display — formats in the book's language

**Files:**
- Create: `Table/TableLocale.swift`, `Table/CellDisplay.swift`
- Modify: Map, ceiling
- Test: `CellDisplayTests.swift`

**Interfaces — Produces:**

```swift
public struct TableLocale: Equatable, Sendable {
    /// `languageTag` as stored on a body ("en-GB", "es", "en_us", nil = the source). Region: the tag's, else `fallbackRegion`
    /// (the paper-size rule R-S5). `financialYearStartMonth` 1...12.
    public init(languageTag: String?, fallbackRegion: String? = Locale.current.region?.identifier, financialYearStartMonth: Int = 1)
    public let locale: Locale            // language + resolved region
    public let decimalSeparator: String
    public let groupingSeparator: String
    public let currencySymbol: String
    public let dayFirst: Bool            // from the locale's "dMy" template: d before M
    public let financialYearStartMonth: Int
}
public enum CellDisplay {
    public static func string(for value: CellValue, format: CellFormat, locale: TableLocale) -> String
}
```

**Rules:**
- **Pre-rounding.** Every numeric format first rounds with `ExcelRounding.round(_, digits:)` to the digits shown. Only then is it formatted, so binary artefacts never show (Review Focus 1).
- **`.general` for numbers:**
  - round to 10 significant digits and trim trailing zeros, with no grouping and the locale's decimal separator;
  - |x| ≥ 1e11, or 0 < |x| < 1e-9 → scientific with up to 6 significant digits, `1.23457E+11`.
- **`.general` for dates** → the `.day` style.
- **`.number`, `.percent`, `.currency`** use `NumberFormatter` with the locale, `minimumFractionDigits = maximumFractionDigits = decimals`, grouping as asked, and `.halfUp` rounding (already pre-rounded). Percent and currency patterns, including symbol position and spacing, are the locale's. `currency(symbol: nil)` uses `locale.currencySymbol`.
- **`.compact`** uses Foundation's compact-name notation in the locale, with `decimals` fraction digits: English shows `1.2K`, `3.4M`, `5.6B`. That's a ruling, recorded beside spec §5.1's "1.2k / 1.2m".
- **Negatives.** `.parentheses` formats the magnitude and wraps it: `(1,200)`, `(£1,200)`. `.minus` uses the locale's minus.
- **`zeroAsDash`:** a value that is zero after rounding, or empty, shows `—`.
- **Date styles**, via `DateFormatter` templates in the locale, GMT, Gregorian:
  - `.day` = template `dMMMy`;
  - `.month` = `MMMy`;
  - `.quarter` = `QQQy` (whatever the locale gives);
  - `.year` = `y`;
  - `.iso` = `DateSerial.isoString`.
- **Financial year.** With a start month other than 1:
  - `.quarter` shows `Q<n> FY<yy>` and `.year` shows `FY<yyyy>`;
  - the financial year is named by the calendar year it ends in, and quarters count from the start month;
  - the FY labels are English in every language (a ruling).
- **A number with a date format** shows the date of that serial. **A date with a number format** shows its serial, formatted.
- **Other values:** `bool` → `TRUE`/`FALSE`; `error` → its code; `text` as is; `empty` → `""` unless `zeroAsDash`.

- [ ] **Step 1: Write the failing tests** (pass `fallbackRegion` explicitly everywhere):
  - General: `0.1+0.2` → "0.3"; `1234.5` → "1234.5"; `es`: `1234.5` → "1234,5"; `123456789012` → "1.23457E+11"; `2/3` → "0.6666666667".
  - `.number(decimals: 2, grouping: true)`: en-GB `1234.567` → "1,234.57"; es-ES → "1.234,57"; `2.675` → "2.68".
  - `.percent(decimals: 1)` of `0.1234` → "12.3%" (en-GB). For es-ES, assert `NumberFormatter`'s output for the same input built the same way, so the test pins the locale route, not ICU's spacing.
  - `.currency(symbol: nil, decimals: 0)`: en-GB `1234` → "£1,234"; en-US → "$1,234"; `es` with `fallbackRegion: "ES"` → contains "€"; `currency(symbol: "$")` in en-GB → "$1,234".
  - Negatives: `(1,200)` and `(£1,200)` for `.parentheses`; zero with `zeroAsDash` → "—"; `0.004` at 2 decimals with `zeroAsDash` → "—".
  - Dates for serial 46319: en-GB `.day` → "24 Oct 2026"; en-US `.day` → "Oct 24, 2026"; en-GB `.month` → "Oct 2026"; `.iso` → "2026-10-24"; `.year` → "2026".
  - Financial year starting April: 2026-10-24 → `.quarter` "Q3 FY27", `.year` "FY2027"; 2026-03-31 → "Q4 FY26".
  - Errors and bools show their codes and words.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS; Map and ceiling.
- [ ] **Step 5: Commit:** `core: cell display — number, percent, currency, compact and date formats in the book's language, Excel-rounded first, financial years (report plan 5 Task 7)`.

---

### Task 8: Typed and pasted input

**Files:**
- Create: `Table/CellInput.swift`
- Modify: Map, ceiling
- Test: `CellInputTests.swift`

**Interfaces — Produces:**

```swift
public enum CellEntry: Equatable, Sendable {
    case empty
    case value(CellValue, suggested: NumberFormat?)   // the format Excel would apply on entry, or nil
    case formula(String)                              // the text after "=", for FormulaParser
}
public enum CellInput {
    public static func parse(_ text: String, locale: TableLocale) -> CellEntry
}
```

**Rules, in order:**
1. Trim whitespace. Empty → `.empty`.
2. `=` with more after it → `.formula(rest)`.
3. A leading `'` → `.text` of the rest.
4. `TRUE`/`FALSE` (case-insensitive) → `.bool`.
5. **Numbers:**
   - optional sign, or parentheses for negative; an optional currency symbol before or after (the locale's, or `£ $ € ¥`); an optional trailing `%`;
   - read first with the locale's separators, where grouping must be valid groups of three after the first group;
   - otherwise POSIX (`.` decimal, no grouping);
   - otherwise it isn't a number.
6. **Suggested formats:**
   - `%` → `.percent(decimals: typed decimals)`, value ÷ 100;
   - currency → `.currency(symbol: nil if it's the locale's, else the typed symbol, decimals: typed decimals)`;
   - grouped digits → `.number(decimals: typed, grouping: true)`;
   - otherwise `nil`.
7. **Dates,** in the locale's order when ambiguous:
   - `d/m/y`, `d-m-y`, `d.m.y` (or m/d/y when `!dayFirst`), with 2-digit years 00–29 → 20xx and 30–99 → 19xx → `.date(.day)`;
   - `24 Oct 2026` and `Oct 24, 2026`, plus full month names, in the locale's names and English → `.date(.day)`;
   - `Oct 2026` → the 1st, `.date(.month)`;
   - `Q4 2026` → the first day of the quarter, `.date(.quarter)`;
   - `2026-10-24` → `.date(.iso)`;
   - an invalid date (`31/02/2026`) is text.
8. Otherwise `.text`.

- [ ] **Step 1: Write the failing tests:**
  - en-GB:
    - `"1,234.5"` → 1234.5, suggested `.number(1, true)`;
    - `"12%"` → 0.12 `.percent(0)`; `"12.5%"` → `.percent(1)`;
    - `"£1,200"` → 1200 `.currency(nil, 0)`; `"$5"` → `.currency("$", 0)`;
    - `"(1,200)"` → −1200;
    - `"03/04/2026"` → 3 April 2026; `"24/10/26"` → 2026-10-24; `"31/02/2026"` → text;
    - `"Oct 2026"` → 2026-10-01 `.month`; `"Q4 2026"` → 2026-10-01 `.quarter`; `"2026-10-24"` → `.iso`;
    - `"=SUM(A1:A3)"` → `.formula("SUM(A1:A3)")`; `"'=not"` → text "=not"; `"true"` → bool.
  - en-US: `"03/04/2026"` → March 4.
  - es-ES:
    - `"1.234,5"` → 1234.5; `"1.5"` → 1.5 (POSIX fallback, since "5" isn't a group of three); `"1.234"` → 1234 grouped;
    - `"24 oct 2026"` → date; `"12 %"` → 0.12.
  - `"1,23,4"` (bad grouping) en-GB → text.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS; Map and ceiling.
- [ ] **Step 5: Commit:** `core: cell input — numbers, percentages, currency and dates typed or pasted in the book's language, with the format Excel would suggest (report plan 5 Task 8)`.

---

### Task 9: CSV — the clean render, research files, import

**Files:**
- Create: `Table/TableCSV.swift`
- Modify: Map, ceiling
- Test: `TableCSVTests.swift`

**Interfaces — Produces:**

```swift
public struct CSVReadProblem: Equatable, Sendable { public let row: Int; public let column: Int; public let message: String }   // 0-based
public enum TableCSV {
    /// figures/<name>.csv (spec §3.4): computed values only, by live order. Numbers POSIX with no grouping
    /// (integers without ".0", else up to 15 significant digits), dates ISO, TRUE/FALSE, error codes, "" for empty.
    public static func render(_ table: FigureTable, value: (CellKey) -> CellValue) -> String
    /// A research copy (spec §4.2): formulas as "=" + their A1 text, values as in `render`.
    public static func renderResearch(_ table: FigureTable, figures: [String: FigureTable] = [:]) -> String
    /// RFC 4180 rows. Strips a UTF-8 BOM. Separator auto-detected on the first line, outside quotes:
    /// the most frequent of "," ";" "\t" (a tie or none → ",").
    public static func rows(_ text: String) -> (rows: [[String]], separator: Character)
    /// Reads a CSV into a new table (Use in document, Import from CSV): cells through CellInput with `locale`
    /// (a ";" file reads decimals with "," whatever the locale); "=" cells through FormulaParser.parsePositional,
    /// then resolved to ids against the new table. Unparseable formulas become text holding their "=…" and a problem.
    /// headerRows = 1 when the first row is all non-numeric text and a later row holds a number.
    public static func read(_ text: String, locale: TableLocale) -> (table: FigureTable, problems: [CSVReadProblem])
}
```

**Contract notes:**
- **Writing.** Quote a field when it contains the separator, `"`, CR, LF, or leading or trailing spaces; double the `"`. Rows end in `\n`, and so does the last row. Ragged input rows are padded with empties to the widest row on read.
- **Resolving positional refs after reading.** A `.this` positional ref inside the new table's bounds becomes an id ref. One outside the bounds stays positional, renders as A1 and evaluates `#REF!`. A positional `name!A1` stays positional against that figure (Task 6 resolves positions). `research:` refs stay positional.
- **Unknown functions** stay formulas and evaluate `#NAME?` (spec §4.1).

- [ ] **Step 1: Write the failing tests:**
  - `render`: a 3×3 table with a formula total renders its computed value; text with a comma, a quote and a newline is quoted correctly; `0.1+0.2` renders "0.3"; a date renders "2026-10-24"; an error renders "#DIV/0!".
  - `renderResearch` → `read` round trip: formulas, absolute refs and values survive; `SUM(B2:B4)` comes back as a formula resolving to the new ids, and evaluates the same in a `Workbook`.
  - `rows`: a BOM is stripped; CRLF; a quoted field with an embedded newline; `;` detection; tab detection.
  - `read`: an Excel-exported `;` file with `1,5` reads 1.5 in en-GB; `"=VLOOKUP(A1,B1:C3,2)"` → a formula that evaluates `#NAME?`; `"=SUM(B:B)"` (a whole column, not in the grammar) → text holding `=SUM(B:B)` plus one problem; the header-row heuristic both ways; ragged rows are padded.
  - `test_readThenRender_isStableForValues`: render(read(x)) == render(read(render(read(x)))) for a fixture of 20 mixed rows.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS; Map and ceiling.
- [ ] **Step 5: Commit:** `core: table CSV — the clean values render, research copies with formulas, reading CSV with separator detection and problems (report plan 5 Task 9)`.

---

## After the last task

- `./gen.sh`, then `./scripts/test.sh core`, `./scripts/test.sh` and `./scripts/test.sh phone`: all green.
- The whole-branch review gets the ledger. The seams to name:
  - Task 2's render-after-delete against Task 6's resolution (they must agree on the shrink);
  - Task 3's coercion against Task 4's argument rules for `NPV` ranges;
  - Task 7's pre-rounding against Task 3's `ExcelRounding`;
  - Task 8's day order against Task 7's `dayFirst`;
  - Task 9's positional refs against Task 6.
