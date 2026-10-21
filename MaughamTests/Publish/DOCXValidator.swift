import Foundation
import AppKit
@testable import Maugham

/// **A structural check of a `.docx`, without Word** (report plan 4 Task 4,
/// survey §8): the causes of Word's "repair" prompt, each checked by hand.
///
/// `problems(in:)` lists every defect it finds, as sentences; an empty list
/// is a pass. It:
/// - unzips with `ZipArchive.read`, and checks `[Content_Types].xml` is the
///   archive's first entry;
/// - parses every `.xml` and `.rels` part;
/// - checks every part has a content type (an `Override`, or a `Default` for
///   its extension; an `.xml` part needs an `Override`) and every `Override`
///   names a part that exists;
/// - checks every relationship's `Id` is unique in its file, its source part
///   exists, and its internal `Target` exists; the package's
///   `officeDocument` is `word/document.xml`;
/// - checks every `r:embed`/`r:id` in the document resolves;
/// - checks bookmark starts and ends pair one to one, names are unique and
///   legal, and every `REF` field names a bookmark;
/// - checks every `w:footnoteReference` names a footnote, and `settings.xml`'s
///   `w:footnotePr` names the separators;
/// - checks `wp:docPr` ids are unique;
/// - checks each table's grid has as many columns as each row's cells span;
/// - checks every `w:numId` exists in `numbering.xml`, and each `w:num`'s
///   abstract does;
/// - checks every `w:pStyle`/`w:rStyle`/`w:tblStyle` names a style in
///   `styles.xml`, and `settings.xml` has no `w:updateFields`.
///
/// `importedText(of:)` reads the file through AppKit's own Word reader
/// (`NSAttributedString`, `.officeOpenXML`). It is lenient: a pass there
/// does not prove Word won't repair, which is why the checks above exist.
enum DOCXValidator {

    struct Package {
        let parts: [String: Data]
        let xml: [String: XMLDocument]
        let firstEntry: String?
    }

    static func open(_ url: URL) throws -> Package {
        let parts = try ZipArchive.read(url)
        var xml: [String: XMLDocument] = [:]
        for (name, data) in parts where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            xml[name] = try XMLDocument(xmlString: keepingSpaces(String(decoding: data, as: UTF8.self)))
        }
        return Package(parts: parts, xml: xml, firstEntry: try firstEntryName(url))
    }

    /// The name in the archive's first local file header.
    private static func firstEntryName(_ url: URL) throws -> String? {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count > 30, bytes[0] == 0x50, bytes[1] == 0x4b, bytes[2] == 0x03, bytes[3] == 0x04
        else { return nil }
        let length = Int(bytes[26]) | Int(bytes[27]) << 8
        guard 30 + length <= bytes.count else { return nil }
        return String(decoding: bytes[30..<(30 + length)], as: UTF8.self)
    }

    /// NSXML drops a whitespace-only text node under every option (see
    /// `DOCXBodyEmitterTests.keepingSpaces`): the spaces are parked in a
    /// private-use character so the parse keeps the node.
    static let parkedSpace: Character = "\u{E000}"
    static func keepingSpaces(_ xml: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"(<w:t xml:space="preserve">)( +)(</w:t>)"#)
        var out = xml
        for m in pattern.matches(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)).reversed() {
            out = (out as NSString).replacingCharacters(
                in: m.range(at: 2), with: String(repeating: parkedSpace, count: m.range(at: 2).length))
        }
        return out
    }

    /// Every element named `name` under `node`, in document order, walked by
    /// hand (NSXML's element-relative XPath reads past its context node).
    static func elements(_ node: XMLNode?, _ name: String) -> [XMLElement] {
        guard let node else { return [] }
        return (node.children ?? []).compactMap { $0 as? XMLElement }.flatMap { child in
            (child.name == name ? [child] : []) + elements(child, name)
        }
    }

    static func attr(_ e: XMLElement, _ name: String) -> String? {
        e.attribute(forName: name)?.stringValue
    }

    /// Every visible `w:t` under `node`, joined, the parked spaces restored.
    static func text(_ node: XMLNode?) -> String {
        elements(node, "w:t").compactMap(\.stringValue).joined()
            .replacingOccurrences(of: String(parkedSpace), with: " ")
    }

    // MARK: - the checks

    static func problems(in url: URL) -> [String] {
        let package: Package
        do { package = try open(url) } catch { return ["the package won't open or a part won't parse: \(error)"] }
        var out: [String] = []
        let parts = package.parts
        let xml = package.xml

        if package.firstEntry != "[Content_Types].xml" {
            out.append("the first entry is \(package.firstEntry ?? "nothing"), not [Content_Types].xml")
        }

        // Content types.
        guard let types = xml["[Content_Types].xml"] else { return out + ["no [Content_Types].xml"] }
        let defaults = Set(elements(types, "Default").compactMap { attr($0, "Extension")?.lowercased() })
        let overrides = elements(types, "Override").compactMap { attr($0, "PartName") }
        for name in overrides where parts[String(name.dropFirst())] == nil {
            out.append("an Override names \(name), which is not in the package")
        }
        let overridden = Set(overrides.map { String($0.dropFirst()) })
        for name in parts.keys where name != "[Content_Types].xml" {
            // `.rels` is all extension: NSString reads it as a name with none.
            let last = (name as NSString).lastPathComponent
            let ext = (last.split(separator: ".").last.map(String.init) ?? "").lowercased()
            // `xml`'s Default is the generic application/xml, which is no
            // Word part's type: an .xml part needs its own Override.
            if !overridden.contains(name), ext == "xml" || !defaults.contains(ext) {
                out.append("\(name) has no content type of its own")
            }
        }

        // Relationships.
        var documentRelationshipIDs: Set<String> = []
        for (name, rels) in xml where name.hasSuffix(".rels") {
            let folder = (name as NSString).deletingLastPathComponent          // x/_rels
            let base = (folder as NSString).deletingLastPathComponent          // x
            let sourceName = String((name as NSString).lastPathComponent.dropLast(".rels".count))
            let source = base.isEmpty ? sourceName : base + "/" + sourceName
            if !sourceName.isEmpty, parts[source] == nil {
                out.append("\(name) belongs to \(source), which is not in the package")
            }
            var ids: Set<String> = []
            for r in elements(rels, "Relationship") {
                let id = attr(r, "Id") ?? ""
                if !ids.insert(id).inserted { out.append("\(name) repeats the relationship id \(id)") }
                guard attr(r, "TargetMode") != "External", let target = attr(r, "Target") else { continue }
                let resolved = target.hasPrefix("/") ? String(target.dropFirst())
                    : (base.isEmpty ? target : base + "/" + target)
                let normalised = (resolved as NSString).standardizingPath
                if parts[normalised] == nil {
                    out.append("\(name)'s \(id) targets \(target), which is not in the package")
                }
            }
            if name == "word/_rels/document.xml.rels" { documentRelationshipIDs = ids }
        }
        let officeDocument = elements(xml["_rels/.rels"], "Relationship").first {
            attr($0, "Type")?.hasSuffix("/officeDocument") ?? false
        }
        if officeDocument.flatMap({ attr($0, "Target") }) != "word/document.xml" {
            out.append("_rels/.rels has no officeDocument relationship to word/document.xml")
        }

        guard let document = xml["word/document.xml"] else { return out + ["no word/document.xml"] }
        let footnotes = xml["word/footnotes.xml"]
        let stories = [document, footnotes].compactMap { $0 }

        // Every r:embed / r:id in the document resolves.
        for e in elements(document, "a:blip") {
            if let id = attr(e, "r:embed"), !documentRelationshipIDs.contains(id) {
                out.append("an image embeds \(id), which document.xml.rels doesn't define")
            }
        }

        // Bookmarks.
        var starts: [String: String] = [:]   // id → name
        var ends: [String: Int] = [:]
        var names: Set<String> = []
        let legal = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]{0,39}$"#)
        for story in stories {
            for s in elements(story, "w:bookmarkStart") {
                let id = attr(s, "w:id") ?? "", name = attr(s, "w:name") ?? ""
                if starts[id] != nil { out.append("bookmark id \(id) starts twice") }
                starts[id] = name
                if !names.insert(name).inserted { out.append("bookmark name \(name) is used twice") }
                if legal.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) == nil {
                    out.append("bookmark name \(name) breaks Word's rule")
                }
            }
            for e in elements(story, "w:bookmarkEnd") { ends[attr(e, "w:id") ?? "", default: 0] += 1 }
        }
        for (id, name) in starts where ends[id] != 1 {
            out.append("bookmark \(name) (id \(id)) has \(ends[id] ?? 0) ends")
        }
        for id in ends.keys where starts[id] == nil { out.append("bookmark end \(id) has no start") }
        for story in stories {
            for instruction in elements(story, "w:instrText").compactMap(\.stringValue) {
                let words = instruction.split(separator: " ")
                if words.first == "REF", words.count > 1, !names.contains(String(words[1])) {
                    out.append("REF names \(words[1]), which no bookmark has")
                }
            }
        }

        // Footnotes.
        let noteIDs = elements(footnotes, "w:footnote").compactMap { attr($0, "w:id") }
        if Set(noteIDs).count != noteIDs.count { out.append("a footnote id is used twice: \(noteIDs)") }
        for story in stories {
            for r in elements(story, "w:footnoteReference") {
                let id = attr(r, "w:id") ?? ""
                if !noteIDs.contains(id) { out.append("footnote reference \(id) has no footnote") }
            }
        }
        let settings = xml["word/settings.xml"]
        let separators = elements(elements(settings, "w:footnotePr").first, "w:footnote")
            .compactMap { attr($0, "w:id") }
        if separators != ["-1", "0"] { out.append("settings.xml's footnotePr names \(separators), not -1 and 0") }
        for id in separators where !noteIDs.contains(id) {
            out.append("settings.xml names footnote \(id), which footnotes.xml lacks")
        }
        if !elements(settings, "w:updateFields").isEmpty {
            out.append("settings.xml asks Word to update fields on open")
        }

        // Drawings.
        let drawingIDs = stories.flatMap { elements($0, "wp:docPr") }.compactMap { attr($0, "id") }
        if Set(drawingIDs).count != drawingIDs.count { out.append("a docPr id is used twice: \(drawingIDs)") }

        // Tables: grid columns = each row's spanned cells.
        for story in stories {
            for table in elements(story, "w:tbl") {
                let grid = elements(childElements(table, "w:tblGrid").first, "w:gridCol").count
                for row in childElements(table, "w:tr") {
                    let span = childElements(row, "w:tc").reduce(0) { sum, cell in
                        let gridSpan = elements(childElements(cell, "w:tcPr").first, "w:gridSpan").first
                        return sum + (gridSpan.flatMap { attr($0, "w:val") }.flatMap(Int.init) ?? 1)
                    }
                    if span != grid { out.append("a table row spans \(span) cells over a \(grid)-column grid") }
                }
            }
        }

        // Numbering.
        let numbering = xml["word/numbering.xml"]
        let abstracts = Set(elements(numbering, "w:abstractNum").compactMap { attr($0, "w:abstractNumId") })
        var nums: Set<String> = []
        for num in elements(numbering, "w:num") {
            nums.insert(attr(num, "w:numId") ?? "")
            let abstract = elements(num, "w:abstractNumId").first.flatMap { attr($0, "w:val") } ?? ""
            if !abstracts.contains(abstract) { out.append("w:num points at a missing abstract \(abstract)") }
        }
        for story in stories {
            for n in elements(story, "w:numId") where !nums.contains(attr(n, "w:val") ?? "") {
                out.append("a paragraph's numId \(attr(n, "w:val") ?? "") isn't in numbering.xml")
            }
        }

        // Styles.
        let styleIDs = Set(elements(xml["word/styles.xml"], "w:style").compactMap { attr($0, "w:styleId") })
        for story in stories {
            for kind in ["w:pStyle", "w:rStyle", "w:tblStyle"] {
                for s in elements(story, kind) where !styleIDs.contains(attr(s, "w:val") ?? "") {
                    out.append("\(kind) \(attr(s, "w:val") ?? "") isn't defined in styles.xml")
                }
            }
        }
        return out
    }

    private static func childElements(_ e: XMLElement, _ name: String) -> [XMLElement] {
        (e.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == name }
    }

    // MARK: - AppKit's reader

    /// The document's text as AppKit's Word reader gets it; throws when it
    /// won't import.
    static func importedText(of url: URL) throws -> String {
        let imported = try NSAttributedString(
            url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil)
        return imported.string
    }
}
