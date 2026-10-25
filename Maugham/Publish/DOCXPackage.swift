import Foundation
import MaughamCore

/// **The `.docx` package** (report plan 4, Task 4): the emitter's parts plus
/// the package's own, zipped by `ZipArchive` with `[Content_Types].xml`
/// first. Pure apart from reading each image's bytes.
///
/// | Part | What |
/// |---|---|
/// | `[Content_Types].xml` | a `Default` for `rels`, `xml` and each image extension present; an `Override` for every other part |
/// | `_rels/.rels` | `officeDocument`, core, app (and custom) |
/// | `word/document.xml` | the emitter's, on the compiler's page |
/// | `word/_rels/document.xml.rels` | styles, numbering, footnotes, settings (and theme) as `rId1…`, then one `rIdImg<hash>` per image |
/// | `word/styles.xml` | the built-in styles, or a `reference.docx`'s merged over them (`Styles`) |
/// | `word/theme/theme1.xml` | only when a reference supplied one, so its theme fonts resolve |
/// | `word/numbering.xml`, `word/footnotes.xml` | the emitter's |
/// | `word/settings.xml` | `w:footnotePr` naming the separators -1 and 0; no `w:updateFields` |
/// | `word/media/<hash>.<ext>` | each image once |
/// | `docProps/core.xml` | title, creator, created (W3CDTF) |
/// | `docProps/app.xml` | the application's name |
/// | `docProps/custom.xml` | only when there are custom properties (the export label, Task 5) |
enum DOCXPackage {

    struct Metadata {
        let title: String
        let author: String
        let created: Date
    }

    /// One `docProps/custom.xml` property: a string (`vt:lpwstr`), or a
    /// 4-byte integer (`vt:i4`).
    struct CustomProperty: Equatable {
        let name: String
        let value: String
        let isInteger: Bool

        init(name: String, value: String) {
            self.name = name
            self.value = value
            self.isInteger = false
        }

        init(name: String, integer: Int) {
            self.name = name
            self.value = String(Int32(clamping: integer))
            self.isInteger = true
        }
    }

    enum PackageError: Error, Equatable {
        /// The emitter named an image the compiler never rasterised (R-S3):
        /// a programming error, refused rather than shipped as a relationship
        /// to bytes Word can't show.
        case unrasterised(String)
    }

    // MARK: namespaces and types

    fileprivate static let declaration = DOCXBodyEmitter.declaration
    fileprivate static let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
    private static let relationshipsNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let officeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private static let wordML = "application/vnd.openxmlformats-officedocument.wordprocessingml."

    /// The parts every package has, with their content types.
    private static let fixedParts: [(path: String, type: String)] = [
        ("word/document.xml", wordML + "document.main+xml"),
        ("word/styles.xml", wordML + "styles+xml"),
        ("word/numbering.xml", wordML + "numbering+xml"),
        ("word/footnotes.xml", wordML + "footnotes+xml"),
        ("word/settings.xml", wordML + "settings+xml"),
        ("docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml"),
        ("docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml"),
    ]
    private static let themePart = (path: "word/theme/theme1.xml",
                                    type: "application/vnd.openxmlformats-officedocument.theme+xml")
    private static let customPart = (path: "docProps/custom.xml",
                                     type: "application/vnd.openxmlformats-officedocument.custom-properties+xml")

    /// The image types Word embeds, by extension.
    static func imageType(_ ext: String) -> String? {
        switch ext.lowercased() {
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        default:            return nil
        }
    }

    // MARK: the package

    /// Every entry, `[Content_Types].xml` first. Throws when an image can't
    /// be read or isn't one Word embeds.
    static func entries(body: DOCXBody, styles: Styles, metadata: Metadata,
                        customProperties: [CustomProperty]) throws -> [ZipArchive.Entry] {
        var media: [(path: String, data: Data)] = []
        for item in body.media {
            guard !item.needsRaster, imageType((item.name as NSString).pathExtension) != nil else {
                throw PackageError.unrasterised(item.name)
            }
            media.append(("word/media/" + item.name,
                          try Data(contentsOf: item.source))) // adr-0018-ok: a figure image's bytes, already staged for Word
        }
        let hasCustom = !customProperties.isEmpty
        var overrides = fixedParts
        if styles.theme != nil { overrides.append(themePart) }
        if hasCustom { overrides.append(customPart) }

        var out: [ZipArchive.Entry] = []
        func add(_ path: String, _ text: String) {
            out.append(.init(path: path, data: Data(text.utf8), compress: true))
        }
        add("[Content_Types].xml", contentTypes(overrides: overrides,
                                                imageExtensions: media.map { ($0.path as NSString).pathExtension }))
        add("_rels/.rels", packageRelationships(custom: hasCustom))
        add("word/document.xml", body.documentXML)
        add("word/_rels/document.xml.rels", documentRelationships(body.relationships, theme: styles.theme != nil))
        add("word/styles.xml", styles.xml)
        if let theme = styles.theme { out.append(.init(path: themePart.path, data: theme, compress: true)) }
        add("word/numbering.xml", body.numberingXML)
        add("word/footnotes.xml", body.footnotesXML)
        add("word/settings.xml", settings)
        // Images are already compressed: stored as they are.
        out += media.map { .init(path: $0.path, data: $0.data, compress: false) }
        add("docProps/core.xml", core(metadata))
        add("docProps/app.xml", app)
        if hasCustom { add(customPart.path, custom(customProperties)) }
        return out
    }

    static func write(body: DOCXBody, styles: Styles, metadata: Metadata,
                      customProperties: [CustomProperty], to url: URL) throws {
        try ZipArchive.write(entries(body: body, styles: styles, metadata: metadata,
                                     customProperties: customProperties), to: url)
    }

    // MARK: the package's own parts

    static func contentTypes(overrides: [(path: String, type: String)], imageExtensions: [String]) -> String {
        var defaults: [(String, String)] = [
            ("rels", "application/vnd.openxmlformats-package.relationships+xml"),
            ("xml", "application/xml"),
        ]
        for ext in Set(imageExtensions.map { $0.lowercased() }).sorted() {
            if let type = imageType(ext) { defaults.append((ext, type)) }
        }
        return declaration
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + defaults.map { "<Default Extension=\"\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined()
            + overrides.map { "<Override PartName=\"/\($0.path)\" ContentType=\"\($0.type)\"/>" }.joined()
            + "</Types>"
    }

    private static func relationship(_ id: String, _ type: String, _ target: String) -> String {
        "<Relationship Id=\"\(id)\" Type=\"\(type)\" Target=\"\(OOXMLEscape.attribute(target))\"/>"
    }

    static func packageRelationships(custom: Bool) -> String {
        declaration + "<Relationships xmlns=\"\(relationshipsNS)\">"
            + relationship("rId1", officeRel + "officeDocument", "word/document.xml")
            + relationship("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties",
                           "docProps/core.xml")
            + relationship("rId3", officeRel + "extended-properties", "docProps/app.xml")
            + (custom ? relationship("rId4", officeRel + "custom-properties", customPart.path) : "")
            + "</Relationships>"
    }

    /// The document's own parts as `rId1…`; the images keep the emitter's
    /// `rIdImg<hash>`, which cannot collide with them.
    static func documentRelationships(_ images: [DOCXRelationship], theme: Bool) -> String {
        var parts = [("styles", "styles.xml"), ("numbering", "numbering.xml"),
                     ("footnotes", "footnotes.xml"), ("settings", "settings.xml")]
        if theme { parts.append(("theme", "theme/theme1.xml")) }
        return declaration + "<Relationships xmlns=\"\(relationshipsNS)\">"
            + parts.enumerated().map { relationship("rId\($0.offset + 1)", officeRel + $0.element.0,
                                                    $0.element.1) }.joined()
            + images.map { relationship($0.id, $0.type, $0.target) }.joined()
            + "</Relationships>"
    }

    /// CT_Settings' order: `defaultTabStop`, `characterSpacingControl`,
    /// `footnotePr`, `compat`. The footnote separators are `footnotes.xml`'s
    /// -1 and 0. No `w:updateFields`: every field carries its result, and
    /// asking Word to update them on open is a prompt.
    static let settings = declaration + "<w:settings \(w)>"
        + "<w:defaultTabStop w:val=\"720\"/>"
        + "<w:characterSpacingControl w:val=\"doNotCompress\"/>"
        + "<w:footnotePr><w:footnote w:id=\"-1\"/><w:footnote w:id=\"0\"/></w:footnotePr>"
        + "<w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat>"
        + "</w:settings>"

    /// W3CDTF: seconds, UTC, no fraction.
    static func w3cdtf(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func core(_ metadata: Metadata) -> String {
        let stamp = w3cdtf(metadata.created)
        return declaration
            + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\""
            + " xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\""
            + " xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + "<dc:title>\(OOXMLEscape.text(metadata.title))</dc:title>"
            + "<dc:creator>\(OOXMLEscape.text(metadata.author))</dc:creator>"
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created>"
            + "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:modified>"
            + "</cp:coreProperties>"
    }

    static let app = declaration
        + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\""
        + " xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
        + "<Application>\(OOXMLEscape.text(BuildVariant.current.displayName))</Application>"
        + "</Properties>"

    /// The user-defined properties' format id is fixed by OLE; `pid`s start at 2.
    static func custom(_ properties: [CustomProperty]) -> String {
        declaration
            + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/custom-properties\""
            + " xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
            + properties.enumerated().map { i, p in
                "<property fmtid=\"{D5CDD505-2E9C-101B-9397-08002B2CF9AE}\" pid=\"\(i + 2)\""
                    + " name=\"\(OOXMLEscape.attribute(p.name))\">"
                    + (p.isInteger ? "<vt:i4>\(p.value)</vt:i4>"
                                   : "<vt:lpwstr>\(OOXMLEscape.text(p.value))</vt:lpwstr>")
                    + "</property>"
            }.joined()
            + "</Properties>"
    }
}

// MARK: - styles

extension DOCXPackage {

    /// `word/styles.xml`, and the theme a reference brought with it.
    struct Styles: Equatable {
        let xml: String
        let theme: Data?

        /// The writer's style source, beside the PDF's style files in
        /// `.maugham/publish/`.
        static let referenceFilename = "reference.docx"

        /// Restrained: Word's own defaults (Calibri 11 pt, 8 pt after, 1.08
        /// lines) with sensible spacing around headings, captions, quotes and
        /// code. Every style the emitter names is here, and the headings carry
        /// `w:outlineLvl`, so Word's navigation pane and its table of contents
        /// find them. `language` is the text's proofing language.
        static func builtIn(language: String) -> Styles {
            Styles(xml: declaration + "<w:styles \(w)>" + docDefaults(language: language)
                       + builtInStyles.joined() + "</w:styles>",
                   theme: nil)
        }

        static func docDefaults(language: String) -> String {
            "<w:docDefaults><w:rPrDefault><w:rPr>"
                + "<w:rFonts w:ascii=\"Calibri\" w:eastAsia=\"Calibri\" w:hAnsi=\"Calibri\" w:cs=\"Calibri\"/>"
                + "<w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/>"
                + (language.isEmpty ? "" : "<w:lang w:val=\"\(OOXMLEscape.attribute(proofingTag(language)))\"/>")
                + "</w:rPr></w:rPrDefault>"
                + "<w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"259\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault>"
                + "</w:docDefaults>"
        }

        /// The book's tag as Word's `w:lang` spells it: BCP 47, `-` not `_`.
        static func proofingTag(_ language: String) -> String {
            language.replacingOccurrences(of: "_", with: "-")
        }

        /// One `w:style`, its children in CT_Style's order (name, basedOn,
        /// next, uiPriority, semiHidden, unhideWhenUsed, qFormat, pPr, rPr,
        /// tblPr).
        private static func style(_ type: String, _ id: String, name: String, isDefault: Bool = false,
                                  basedOn: String? = nil, next: String? = nil, priority: Int? = nil,
                                  hidden: Bool = false, quick: Bool = false,
                                  pPr: String = "", rPr: String = "", tblPr: String = "") -> String {
            "<w:style w:type=\"\(type)\"" + (isDefault ? " w:default=\"1\"" : "") + " w:styleId=\"\(id)\">"
                + "<w:name w:val=\"\(name)\"/>"
                + (basedOn.map { "<w:basedOn w:val=\"\($0)\"/>" } ?? "")
                + (next.map { "<w:next w:val=\"\($0)\"/>" } ?? "")
                + (priority.map { "<w:uiPriority w:val=\"\($0)\"/>" } ?? "")
                + (hidden ? "<w:semiHidden/><w:unhideWhenUsed/>" : "")
                + (quick ? "<w:qFormat/>" : "")
                + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>")
                + (rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>")
                + (tblPr.isEmpty ? "" : "<w:tblPr>\(tblPr)</w:tblPr>")
                + "</w:style>"
        }

        private static func fonts(_ face: String) -> String {
            "<w:rFonts w:ascii=\"\(face)\" w:hAnsi=\"\(face)\" w:cs=\"\(face)\"/>"
        }

        /// `name` is Word's own lower-case built-in name, so Word treats it as
        /// its Heading style; `w:outlineLvl` is 0-based.
        private static func heading(_ level: Int, size: Int, before: Int, colour: String) -> String {
            style("paragraph", "Heading\(level)", name: "heading \(level)", basedOn: "Normal", next: "Normal",
                  priority: 9, quick: true,
                  pPr: "<w:keepNext/><w:keepLines/><w:spacing w:before=\"\(before)\" w:after=\"80\"/>"
                    + "<w:outlineLvl w:val=\"\(level - 1)\"/>",
                  rPr: fonts("Calibri Light") + "<w:color w:val=\"\(colour)\"/>"
                    + "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>")
        }

        private static let cellMargins = "<w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/>"
            + "<w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/>"
            + "<w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar>"

        private static let gridBorders = "<w:tblBorders>"
            + ["top", "left", "bottom", "right", "insideH", "insideV"].map {
                "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
            }.joined() + "</w:tblBorders>"

        static let builtInStyles: [String] = [
            style("paragraph", "Normal", name: "Normal", isDefault: true, quick: true),
            style("character", "DefaultParagraphFont", name: "Default Paragraph Font", isDefault: true,
                  priority: 1, hidden: true),
            style("table", "TableNormal", name: "Normal Table", isDefault: true, priority: 99, hidden: true,
                  tblPr: "<w:tblInd w:w=\"0\" w:type=\"dxa\"/>" + cellMargins),
            style("numbering", "NoList", name: "No List", isDefault: true, priority: 99, hidden: true),
            heading(1, size: 32, before: 360, colour: "1F3864"),
            heading(2, size: 26, before: 240, colour: "1F3864"),
            heading(3, size: 24, before: 200, colour: "404040"),
            style("paragraph", "Caption", name: "caption", basedOn: "Normal", next: "Normal", priority: 35,
                  hidden: true, quick: true,
                  pPr: "<w:spacing w:before=\"60\" w:after=\"200\" w:line=\"240\" w:lineRule=\"auto\"/>",
                  rPr: "<w:i/><w:iCs/><w:color w:val=\"404040\"/><w:sz w:val=\"18\"/><w:szCs w:val=\"18\"/>"),
            style("paragraph", "Quote", name: "Quote", basedOn: "Normal", next: "Normal", priority: 29, quick: true,
                  pPr: "<w:spacing w:before=\"120\" w:after=\"160\"/><w:ind w:left=\"720\" w:right=\"720\"/>",
                  rPr: "<w:i/><w:iCs/><w:color w:val=\"404040\"/>"),
            style("paragraph", "Code", name: "Code", basedOn: "Normal", quick: true,
                  pPr: "<w:spacing w:before=\"120\" w:after=\"160\" w:line=\"240\" w:lineRule=\"auto\"/>"
                    + "<w:ind w:left=\"360\"/>",
                  rPr: fonts("Courier New") + "<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/>"),
            style("character", "CodeChar", name: "Code Char", basedOn: "DefaultParagraphFont",
                  rPr: fonts("Courier New") + "<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/>"),
            style("paragraph", "Bibliography", name: "Bibliography", basedOn: "Normal", next: "Normal",
                  priority: 37, hidden: true,
                  pPr: "<w:ind w:left=\"720\" w:hanging=\"720\"/>"),
            style("paragraph", "FootnoteText", name: "footnote text", basedOn: "Normal", priority: 99, hidden: true,
                  pPr: "<w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>",
                  rPr: "<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/>"),
            style("character", "FootnoteReference", name: "footnote reference", basedOn: "DefaultParagraphFont",
                  priority: 99, hidden: true, rPr: "<w:vertAlign w:val=\"superscript\"/>"),
            style("table", "TableGrid", name: "Table Grid", basedOn: "TableNormal", priority: 39,
                  pPr: "<w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>",
                  tblPr: gridBorders),
        ]

        /// Why a reference can't be used, in the warning's words.
        struct ReferenceUnusable: Error, Equatable {
            let reason: String
        }

        /// A `reference.docx`'s styles merged over the built-ins: the
        /// reference wins for every style id it defines, its other styles
        /// (the `…Char` links a Word-made file carries) come with it, and the
        /// built-ins it lacks are kept, so `Caption` and the rest always
        /// exist. Its `docDefaults` win when it has them, and its theme comes
        /// along so its theme fonts resolve. A built-in kept beside a
        /// reference default of the same type gives up its `w:default`, so
        /// each type has one default. The reference's root element is kept,
        /// with every namespace it declares, so its own extensions stay
        /// well-formed.
        static func merged(reference url: URL, language: String) throws -> Styles {
            let archive: [String: Data]
            do { archive = try ZipArchive.read(url) } // adr-0018-ok: the writer's reference.docx, a style source
            catch { throw ReferenceUnusable(reason: "it isn't a readable .docx") }
            guard let data = archive["word/styles.xml"] else {
                throw ReferenceUnusable(reason: "it has no word/styles.xml")
            }
            guard let document = try? XMLDocument(data: data, options: []) else {
                throw ReferenceUnusable(reason: "its word/styles.xml isn't well-formed XML")
            }
            guard let root = document.rootElement(), root.name == "w:styles" else {
                throw ReferenceUnusable(reason: "its word/styles.xml has no w:styles")
            }
            guard let builtRoot = (try? XMLDocument(xmlString: builtIn(language: language).xml,
                                                    options: []))?.rootElement() else {
                throw ReferenceUnusable(reason: "the built-in styles didn't parse")
            }
            func children(_ e: XMLElement, _ name: String) -> [XMLElement] {
                (e.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == name }
            }
            func value(_ e: XMLElement, _ name: String) -> String? { e.attribute(forName: name)?.stringValue }

            let referenceStyles = children(root, "w:style")
            // A localised Word spells the id in its own language
            // (`berschrift1`) and keeps Word's built-in name (`heading 1`):
            // a reference style named as a built-in of the same type IS that
            // built-in, so it takes the built-in's id, and every
            // basedOn/link/next that named its old id follows.
            let builtStyles = children(builtRoot, "w:style")
            func nameKey(_ e: XMLElement) -> String? {
                guard let type = value(e, "w:type"),
                      let name = children(e, "w:name").first.flatMap({ value($0, "w:val") }) else { return nil }
                return type + "\u{0}" + name.lowercased()
            }
            var builtIDByName: [String: String] = [:]
            for e in builtStyles {
                if let key = nameKey(e), let id = value(e, "w:styleId") { builtIDByName[key] = id }
            }
            let referenceIDs = Set(referenceStyles.compactMap { value($0, "w:styleId") })
            var renamed: [String: String] = [:]
            for e in referenceStyles {
                guard let id = value(e, "w:styleId"), let key = nameKey(e),
                      let builtID = builtIDByName[key], builtID != id,
                      !referenceIDs.contains(builtID), !renamed.values.contains(builtID) else { continue }
                renamed[id] = builtID
                e.attribute(forName: "w:styleId")?.stringValue = builtID
            }
            if !renamed.isEmpty {
                for e in referenceStyles {
                    for pointer in ["w:basedOn", "w:link", "w:next"] {
                        for p in children(e, pointer) {
                            if let old = value(p, "w:val"), let new = renamed[old] {
                                p.attribute(forName: "w:val")?.stringValue = new
                            }
                        }
                    }
                }
            }
            let ids = Set(referenceStyles.compactMap { value($0, "w:styleId") })
            let defaultTypes = Set(referenceStyles.filter { value($0, "w:default") == "1" }
                .compactMap { value($0, "w:type") })
            if let kept = children(root, "w:docDefaults").first {
                if !language.isEmpty { setLanguage(proofingTag(language), in: kept) }
            } else if let defaults = children(builtRoot, "w:docDefaults").first?.copy() as? XMLElement {
                root.insertChild(defaults, at: 0)
            }
            for builtStyle in builtStyles {
                guard let id = value(builtStyle, "w:styleId"), !ids.contains(id),
                      let copy = builtStyle.copy() as? XMLElement else { continue }
                if let type = value(copy, "w:type"), defaultTypes.contains(type) {
                    copy.removeAttribute(forName: "w:default")
                }
                root.addChild(copy)
            }
            let theme = archive["word/theme/theme1.xml"].flatMap { candidate in
                (try? XMLDocument(data: candidate, options: [])) == nil ? nil : candidate
            }
            return Styles(xml: String(decoding: document.xmlData(options: [.nodeCompactEmptyElement]),
                                      as: UTF8.self),
                          theme: theme)
        }

        /// Gives a reference's `docDefaults` the book's own proofing language:
        /// its run defaults' `w:lang` takes the book's `w:val` (its `eastAsia`
        /// and `bidi` stay), or one is added in CT_RPr's place (before
        /// `eastAsianLayout`, `specVanish` and `oMath`, the only elements after
        /// it).
        private static func setLanguage(_ tag: String, in docDefaults: XMLElement) {
            func child(_ e: XMLElement, _ name: String, at index: Int? = nil) -> XMLElement {
                if let found = (e.children ?? []).compactMap({ $0 as? XMLElement }).first(where: { $0.name == name }) {
                    return found
                }
                let made = XMLElement(name: name)
                if let index { e.insertChild(made, at: index) } else { e.addChild(made) }
                return made
            }
            let rPrDefault = child(docDefaults, "w:rPrDefault", at: 0)
            let rPr = child(rPrDefault, "w:rPr")
            if let existing = (rPr.children ?? []).compactMap({ $0 as? XMLElement })
                .first(where: { $0.name == "w:lang" }) {
                existing.removeAttribute(forName: "w:val")
                existing.addAttribute(XMLNode.attribute(withName: "w:val", stringValue: tag) as! XMLNode)
                return
            }
            let lang = XMLElement(name: "w:lang")
            lang.addAttribute(XMLNode.attribute(withName: "w:val", stringValue: tag) as! XMLNode)
            let after: Set<String> = ["w:eastAsianLayout", "w:specVanish", "w:oMath"]
            if let next = (rPr.children ?? []).firstIndex(where: { after.contains(($0 as? XMLElement)?.name ?? "") }) {
                rPr.insertChild(lang, at: next)
            } else {
                rPr.addChild(lang)
            }
        }

        /// The styles a compile uses: a `reference.docx` in `publishDir`
        /// merged over the built-ins, else the built-ins. A reference that
        /// can't be used is a warning, and the built-ins stand.
        static func forCompile(publishDir: URL, language: String)
            -> (styles: Styles, warning: TectonicLogParser.Diagnostic?) {
            let reference = publishDir.appendingPathComponent(referenceFilename) // local-path: a fixed constant
            guard FileManager.default.fileExists(atPath: reference.path) else {
                return (builtIn(language: language), nil)
            }
            do {
                return (try merged(reference: reference, language: language), nil)
            } catch {
                let reason = (error as? ReferenceUnusable)?.reason ?? error.localizedDescription
                return (builtIn(language: language), TectonicLogParser.Diagnostic(
                    level: .warning, file: ".maugham/publish/" + referenceFilename, line: nil,
                    message: "\(referenceFilename) couldn't be used for the Word styles (\(reason)), "
                        + "so the built-in styles were used.",
                    contextLines: []))
            }
        }
    }
}
