import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// **A book of table figures behind a real `FigureCardCache`** (report plan 7a
/// Task 7), for the harness and budget suites that drive the whole chain a
/// window wires: the cache fills from `source` (counting every read — a read
/// is a fill), `onVersionChange` writes `EditorControl.figureCardVersion`
/// exactly as `EditorHost.attachFigureCards` does, and the coordinator reads
/// each figure line's card through `model(forLinePath:documentPath:)`.
///
/// The test changes a table's row count with `setRows(_:table:)` and lands it
/// as a remote change with `cache.invalidate()` — what `DocumentStore`'s
/// figure triggers do when another device's ops arrive.
@MainActor
final class FigureCardBook {
    let cache = FigureCardCache()
    let control = EditorControl()
    /// Every `source.read` the cache made: its fills.
    private(set) var reads = 0
    private var rows: [Int]

    /// `tables` table figures, each of `rows` rows, registered at
    /// `figures/t<i>.csv`.
    init(tables: Int, rows: Int) {
        self.rows = Array(repeating: rows, count: tables)
        control.theme = .light
        control.typography = .defaults
        let control = control
        cache.onVersionChange = { control.figureCardVersion = $0 }   // EditorHost's own closure
    }

    static func id(_ i: Int) -> String { String(format: "fig-%08x", i) }

    /// Table `i` now has `count` rows (lands at the next fill).
    func setRows(_ count: Int, table i: Int) { rows[i] = count }

    var source: FigureCardCache.Source {
        FigureCardCache.Source(read: { [weak self] in
            guard let self else { return nil }
            reads += 1
            return inputs()
        })
    }

    private func inputs() -> FigureCardInputs {
        var book = Workbook(pins: FigurePinIndex())
        var records: [FigureRecord] = [], states: [String: FigureState] = [:]
        for (i, count) in rows.enumerated() {
            let id = Self.id(i)
            var table = FigureTable(rows: count, columns: 2)
            for (r, row) in table.rows.enumerated() {
                table.setCell(Cell(content: .value(.text("Row \(r)"))),
                              at: CellKey(row: row, column: table.columns[0]))
                table.setCell(Cell(content: .value(.number(Double(r)))),
                              at: CellKey(row: row, column: table.columns[1]))
            }
            book.setTable(table, id: id)
            records.append(FigureRecord(id: id, name: "t\(i)", kind: .table, piece: nil,
                                        path: "figures/t\(i).csv"))
            states[id] = FigureState(kind: .table, table: table)
        }
        return FigureCardInputs(records: records, states: states, workbook: book, pinChanged: [],
                                locale: TableLocale(languageTag: "en-GB", fallbackRegion: "GB"))
    }

    /// Wire `coordinator` to this book as `EditorHost` does: the card
    /// provider (for a document at `documentPath`), a resolver that finds no
    /// picture, a whole-document paint, the control plane, then the first
    /// fill — settled through the control plane onto the coordinator.
    func wire(_ coordinator: EditorCoordinator, documentPath: String, textView: NSTextView) async {
        paintWhole(coordinator, documentPath: documentPath, textView: textView)
        coordinator.observeControl(control)
        cache.attach(source)
        await landFill(on: coordinator)
    }

    /// Give `coordinator` this book's cards (no control plane, no fill) and
    /// paint its whole document: the reference a refreshed or windowed paint
    /// must equal.
    func paintWhole(_ coordinator: EditorCoordinator, documentPath: String, textView: NSTextView) {
        let cache = cache
        coordinator.figureImageResolver = { _ in .notLocal }
        coordinator.figureCardModel = { cache.model(forLinePath: $0, documentPath: documentPath) }
        coordinator.attach(to: textView)   // a whole-document paint, the overlay installed
    }

    /// Wait for the pending fill, then for the control plane's re-arm hop to
    /// hand its version to `coordinator` (`armControlObservation` applies on
    /// the next main-actor turn). Bounded by turns, never by a clock.
    func landFill(on coordinator: EditorCoordinator,
                  file: StaticString = #filePath, line: UInt = #line) async {
        await cache.idle()
        for _ in 0..<100 where coordinator.figureCardVersion != cache.version { await Task.yield() }
        XCTAssertEqual(coordinator.figureCardVersion, cache.version,
                       "the control plane carried the fill's version to the coordinator", file: file, line: line)
    }

    /// A manuscript of `tables` table figure lines written from
    /// `manuscript/`, each between two prose paragraphs; `endsOnFigure` puts
    /// the last one on the document's last line.
    static func manuscript(tables: Int, endsOnFigure: Bool = false) -> String {
        var parts = ["Opening paragraph of plain prose."]
        for i in 0..<tables {
            parts.append(line(i))
            if !(endsOnFigure && i == tables - 1) {
                parts.append("Paragraph \(i) of prose under its table.")
            }
        }
        if !endsOnFigure { parts.append("Closing paragraph.") }
        return parts.joined(separator: "\n\n")
    }

    static func line(_ i: Int) -> String { "![Table \(i)](../figures/t\(i).csv){#tbl:t\(i)}" }
}

/// Records every edit the storage sends its layout manager (ruling R7a-5:
/// what re-lays out is measured, not reasoned about).
final class EditRecordingLayoutManager: NSLayoutManager {
    struct Edit: Equatable {
        let charactersChanged: Bool
        let range: NSRange
    }
    var edits: [Edit] = []
    override func processEditing(
        for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
        range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange
    ) {
        edits.append(Edit(charactersChanged: editMask.contains(.editedCharacters), range: newCharRange))
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    /// Install a recorder on `textView`, with a container as tall as the text
    /// (as the editor's own is), laid out in full and sized to fit.
    @MainActor
    static func install(on textView: NSTextView) -> EditRecordingLayoutManager {
        let layout = EditRecordingLayoutManager()
        let container = textView.textContainer!
        container.replaceLayoutManager(layout)
        container.size = NSSize(width: container.size.width, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        layout.ensureLayout(for: container)
        textView.sizeToFit()
        layout.edits.removeAll()
        return layout
    }

    /// The attribute-only edits that touched any of `lines`. Pass the lines'
    /// text without their terminators: a settle paint's window starts at the
    /// newline ending the line above the typed paragraph (it re-applies the
    /// body style there, and attribute fixing keeps the paragraph's own), so
    /// a terminator is touched by every paint of the paragraph below it.
    func styleEdits(touching lines: [NSRange]) -> [Edit] {
        edits.filter { edit in
            !edit.charactersChanged && lines.contains { NSIntersectionRange($0, edit.range).length > 0 }
        }
    }
}

/// Reading a harness's figure lines (report plan 7a Task 7).
extension EditorIntegrationHarness {
    var nsText: NSString { textView.string as NSString }
    var storage: NSTextStorage { textView.textStorage! }

    /// The `paragraphSpacing` at the first occurrence of `needle`.
    func spacing(at needle: String) -> CGFloat {
        let at = nsText.range(of: needle).location
        return (storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?
            .paragraphSpacing ?? -1
    }

    /// The whole line (terminator included) holding `needle`.
    func lineRange(of needle: String) -> NSRange {
        nsText.lineRange(for: NSRange(location: nsText.range(of: needle).location, length: 0))
    }

    /// The top of the line fragment holding `needle`, laid out.
    func lineTop(of needle: String) -> CGFloat {
        let lm = textView.layoutManager!
        let glyph = lm.glyphIndexForCharacter(at: nsText.range(of: needle).location)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    /// Every paragraph-style run, to compare two paints.
    func paragraphStyles() -> [(NSRange, NSParagraphStyle?)] {
        var out: [(NSRange, NSParagraphStyle?)] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in out.append((range, value as? NSParagraphStyle))
        }
        return out
    }

    /// Type `s` one key at a time, each through the full delegate path.
    func type(_ s: String) { for c in s { typeCharacter(c) } }
}
