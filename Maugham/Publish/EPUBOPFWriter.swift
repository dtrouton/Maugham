import Foundation

public enum EPUBOPFWriter {

    public static func opfXML(for pkg: EPUBPackage) -> String {
        let m = pkg.metadata
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\" prefix=\"maugham: https://maugham.app/ns/\">")

        // metadata
        lines.append("  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">")
        lines.append("    <dc:identifier id=\"book-id\">\(XHTMLEscape.escape(m.identifier))</dc:identifier>")
        lines.append("    <dc:title>\(XHTMLEscape.escape(m.title))</dc:title>")
        lines.append("    <dc:creator>\(XHTMLEscape.escape(m.author))</dc:creator>")
        if let s = m.subject {
            lines.append("    <dc:subject>\(XHTMLEscape.escape(s))</dc:subject>")
        }
        lines.append("    <dc:language>\(XHTMLEscape.escape(m.language))</dc:language>")
        if let p = m.publisher {
            lines.append("    <dc:publisher>\(XHTMLEscape.escape(p))</dc:publisher>")
        }
        for k in m.keywords {
            lines.append("    <dc:subject>\(XHTMLEscape.escape(k))</dc:subject>")
        }
        if let year = m.publishedYear {
            lines.append("    <dc:date>\(year)</dc:date>")
        }

        lines.append("    <meta property=\"dcterms:modified\">\(XHTMLEscape.escape(m.compiledAtISO8601))</meta>")
        lines.append("    <meta property=\"maugham:version\">\(XHTMLEscape.escape(m.version))</meta>")
        if let label = m.label {
            lines.append("    <meta property=\"maugham:label\">\(XHTMLEscape.escape(label))</meta>")
        }
        lines.append("    <meta property=\"maugham:checkpoint_id\">\(XHTMLEscape.escape(m.checkpointID))</meta>")
        lines.append("    <meta property=\"maugham:compiled_at\">\(XHTMLEscape.escape(m.compiledAtISO8601))</meta>")

        if pkg.cover != nil {
            lines.append("    <meta name=\"cover\" content=\"cover-image\"/>")
        }
        lines.append("  </metadata>")

        // manifest
        lines.append("  <manifest>")
        lines.append("    <item id=\"styles\" href=\"styles.css\" media-type=\"text/css\"/>")
        lines.append("    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        for s in pkg.sections {
            lines.append("    <item id=\"\(XHTMLEscape.attribute(s.id))\" href=\"\(XHTMLEscape.attribute(s.filename))\" media-type=\"application/xhtml+xml\"/>")
        }
        if let cover = pkg.cover {
            lines.append("    <item id=\"cover-image\" href=\"\(XHTMLEscape.attribute(cover.filename))\" media-type=\"\(XHTMLEscape.attribute(cover.mediaType))\" properties=\"cover-image\"/>")
        }
        lines.append("  </manifest>")

        // spine
        lines.append("  <spine>")
        lines.append("    <itemref idref=\"nav\"/>")
        for s in pkg.sections {
            lines.append("    <itemref idref=\"\(XHTMLEscape.attribute(s.id))\"/>")
        }
        lines.append("  </spine>")

        lines.append("</package>")
        return lines.joined(separator: "\n")
    }

    /// XHTML nav document with a table of contents derived from section titles.
    public static func navXHTML(for pkg: EPUBPackage) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<!DOCTYPE html>")
        lines.append("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">")
        lines.append("<head><meta charset=\"utf-8\"/><title>\(XHTMLEscape.escape(pkg.metadata.title))</title></head>")
        lines.append("<body>")
        lines.append("<nav epub:type=\"toc\" id=\"toc\">")
        lines.append("  <h1>Contents</h1>")
        lines.append("  <ol>")
        for s in pkg.sections {
            lines.append("    <li><a href=\"\(XHTMLEscape.attribute(s.filename))\">\(XHTMLEscape.escape(s.title))</a></li>")
        }
        lines.append("  </ol>")
        lines.append("</nav>")
        lines.append("</body></html>")
        return lines.joined(separator: "\n")
    }

    /// Wraps a section's body XHTML in a full XHTML 5 document.
    public static func sectionXHTML(for section: EPUBPackage.Section) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <meta charset="utf-8"/>
          <title>\(XHTMLEscape.escape(section.title))</title>
          <link rel="stylesheet" type="text/css" href="styles.css"/>
        </head>
        <body>
        \(section.xhtmlBody)
        </body>
        </html>
        """
    }
}
