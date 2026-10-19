import Foundation

/// A problem the index found in one document, at one source line.
public struct ManuscriptDiagnostic: Equatable, Sendable {
    /// What is wrong.
    public enum Kind: Equatable, Sendable {
        /// A label already used earlier in the project.
        case duplicateLabel(ManuscriptLabel)
        /// A `fig` label on a heading, a `sec` label on a figure, and so on.
        case labelOnWrongElement(ManuscriptLabel)
        /// A cross-reference to a label nothing in the project defines.
        case unresolvedCrossRef(ManuscriptLabel)
        /// A citation of a key no research item carries.
        case unknownCitationKey(String)
        /// A `[^label]` with no definition in the same document.
        case missingFootnoteDefinition(label: String)
        /// A second `[^label]:` definition in the same document.
        case duplicateFootnoteDefinition(label: String)
        /// A `[^label]:` definition nothing in its document references.
        case unusedFootnoteDefinition(label: String)
        /// A figure path that is a `scheme://` URL or an absolute path.
        case figurePathNotLocal(String)
        /// A trailing `{#…}` block on a heading, caption or figure line that is
        /// not a valid label, e.g. `{#fig:}` or `{#eq:x}`; carries the raw block.
        case malformedLabel(String)
    }

    public let kind: Kind
    public let docID: String
    /// 0-based source line in that document.
    public let line: Int

    public init(kind: Kind, docID: String, line: Int) {
        self.kind = kind
        self.docID = docID
        self.line = line
    }
}

/// The project-wide index of labels and cited keys, with every diagnostic.
/// Labels and citation keys are project-wide; footnote labels are per document.
public struct ManuscriptIndex: Sendable {
    /// One prose document's id and text.
    public struct Doc: Sendable {
        public let id: String
        public let text: String
        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// Where each label is defined; the first occurrence wins.
    public let labels: [ManuscriptLabel: (docID: String, line: Int)]
    /// Every cited key, known or not, unique, in first-use order.
    public let citedKeys: [String]
    /// Diagnostics in document order, then line order.
    public let diagnostics: [ManuscriptDiagnostic]

    /// Indexes `docs` in binder order. The caller excludes Fountain documents;
    /// `citationKeys` are the project's research keys.
    public init(docs: [Doc], citationKeys: Set<String>) {
        var labels: [ManuscriptLabel: (docID: String, line: Int)] = [:]
        var cited: [String] = []
        var citedSet: Set<String> = []
        // `column` orders diagnostics on one line: a marker's UTF-16 offset, 0 for a block.
        var found: [(doc: Int, column: Int, diagnostic: ManuscriptDiagnostic)] = []
        var crossRefs: [(doc: Int, docID: String, line: Int, column: Int, label: ManuscriptLabel)] = []

        for (d, doc) in docs.enumerated() {
            func report(_ kind: ManuscriptDiagnostic.Kind, _ line: Int, column: Int = 0) {
                found.append((d, column, ManuscriptDiagnostic(kind: kind, docID: doc.id, line: line)))
            }
            func register(_ label: ManuscriptLabel?, _ element: ManuscriptLabel.Kind, _ line: Int) {
                guard let label else { return }
                if label.kind != element {
                    report(.labelOnWrongElement(label), line)
                } else if labels[label] != nil {
                    report(.duplicateLabel(label), line)
                } else {
                    labels[label] = (doc.id, line)
                }
            }

            let source = doc.text.components(separatedBy: "\n")
            var definitions: [(label: String, line: Int)] = []
            var defined: Set<String> = []
            var references: [(label: String, line: Int, column: Int)] = []

            for (block, lines) in ManuscriptBlocks.parse(doc.text) {
                switch block {
                case .heading(_, let text, let label):
                    register(label, .sec, lines.lowerBound)
                    if label == nil, let raw = Self.trailingBlock(text) {
                        report(.malformedLabel(raw), lines.lowerBound)
                    }
                case .table(_, _, let caption, let label):
                    let captionLine = lines.upperBound - 1
                    register(label, .tbl, captionLine)
                    if label == nil, let caption, let raw = Self.trailingBlock(caption) {
                        report(.malformedLabel(raw), captionLine)
                    }
                case .figure(_, let path, let label):
                    register(label, .fig, lines.lowerBound)
                    if Self.isNotLocal(path) { report(.figurePathNotLocal(path), lines.lowerBound) }
                case .footnoteDefinition(let label, _):
                    if defined.contains(label) {
                        report(.duplicateFootnoteDefinition(label: label), lines.lowerBound)
                    } else {
                        defined.insert(label)
                        definitions.append((label, lines.lowerBound))
                    }
                case .other(.fence):
                    continue
                case .other(.paragraph(let paragraph)) where paragraph.count == 1:
                    if let raw = Self.malformedFigureBlock(paragraph[0]) {
                        report(.malformedLabel(raw), lines.lowerBound)
                    }
                case .other:
                    break
                }

                let blockText = source[lines].joined(separator: "\n")
                let breaks = blockText.utf16.enumerated().filter { $0.element == 10 }.map(\.offset)
                for (marker, range) in ManuscriptInlineScanner.scan(blockText) {
                    let line = lines.lowerBound + breaks.prefix { $0 < range.location }.count
                    switch marker {
                    case .footnoteRef(let label):
                        references.append((label, line, range.location))
                    case .citation(let items):
                        for item in items {
                            if citedSet.insert(item.key).inserted { cited.append(item.key) }
                            if !citationKeys.contains(item.key) {
                                report(.unknownCitationKey(item.key), line, column: range.location)
                            }
                        }
                    case .crossRef(let label):
                        crossRefs.append((d, doc.id, line, range.location, label))
                    }
                }
            }

            let referenced = Set(references.map(\.label))
            for ref in references where !defined.contains(ref.label) {
                report(.missingFootnoteDefinition(label: ref.label), ref.line, column: ref.column)
            }
            for def in definitions where !referenced.contains(def.label) {
                report(.unusedFootnoteDefinition(label: def.label), def.line)
            }
        }

        for ref in crossRefs where labels[ref.label] == nil {
            found.append((ref.doc, ref.column, ManuscriptDiagnostic(
                kind: .unresolvedCrossRef(ref.label), docID: ref.docID, line: ref.line)))
        }

        self.labels = labels
        self.citedKeys = cited
        // Stable: equal (doc, line, column) keep the order they were found in.
        self.diagnostics = found.enumerated().sorted {
            ($0.element.doc, $0.element.diagnostic.line, $0.element.column, $0.offset)
                < ($1.element.doc, $1.element.diagnostic.line, $1.element.column, $1.offset)
        }.map(\.element.diagnostic)
    }

    // MARK: - Helpers

    /// The raw `{#…}` block ending `text`, if any. Called only where the block
    /// layer read no label, so any such block is malformed.
    private static func trailingBlock(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("}"),
              let open = trimmed.range(of: "{#", options: .backwards) else { return nil }
        return String(trimmed[open.lowerBound...])
    }

    /// A one-line paragraph that is a figure line but for its malformed
    /// trailing `{#…}` block (the block layer left it plain text).
    private static func malformedFigureBlock(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let raw = trailingBlock(trimmed) else { return nil }
        let image = String(trimmed.dropLast(raw.count)).trimmingCharacters(in: .whitespaces)
        let range = NSRange(image.startIndex..., in: image)
        guard ManuscriptBlocks.imageRegex.firstMatch(in: image, range: range) != nil else {
            return nil
        }
        return raw
    }

    private static let urlScheme = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9+.-]*://")

    /// A `scheme://` URL or an absolute path.
    private static func isNotLocal(_ path: String) -> Bool {
        path.hasPrefix("/")
            || urlScheme.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}
