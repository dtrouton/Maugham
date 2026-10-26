import XCTest
@testable import MaughamCore

/// `TableHTML` (report plan 7d Task 1, ruling R7d-3): the first table of what
/// Excel, Google Sheets, Numbers and a web page put on the pasteboard as
/// `public.html`, read by a hand-written scanner; and the table Maugham writes
/// for other apps, read back as written.
final class TableHTMLTests: XCTestCase {

    // MARK: - Fixtures, shaped as each app writes them

    /// Excel for Mac (16.x): an Office HTML document — namespaces, a `<style>`
    /// whose body hides inside `<!-- -->`, a conditional `<!--[if …]>` XML
    /// island, `<!--StartFragment-->`, unquoted attributes, `<col>`, white
    /// space between cells, `x:num`, rich text in `<font>`, a merged cell as
    /// `colspan`, `<br>` then an indented continuation line, entities.
    static let excelMac = """
    <html xmlns:v="urn:schemas-microsoft-com:vml"
    xmlns:o="urn:schemas-microsoft-com:office:office"
    xmlns:x="urn:schemas-microsoft-com:office:excel"
    xmlns="http://www.w3.org/TR/REC-html40">

    <head>
    <meta http-equiv=Content-Type content="text/html; charset=utf-8">
    <meta name=ProgId content=Excel.Sheet>
    <meta name=Generator content="Microsoft Excel 15">
    <link id=Main-File rel=Main-File
    href="file:////Users/denver/Library/Group%20Containers/UBF8T346G9.Office/TemporaryItems/msohtmlclip/clip.htm">
    <style>
    <!--table
    \t{mso-displayed-decimal-separator:"\\.";
    \tmso-displayed-thousand-separator:"\\,";}
    td
    \t{padding-top:1px;
    \tcolor:black;
    \tfont-family:Calibri, sans-serif;}
    .xl65
    \t{mso-number-format:"\\#\\,\\#\\#0\\.00";}
    .font5 {color:black; font-weight:700;}
    -->
    </style>
    <!--[if gte mso 9]><xml>
     <x:ExcelWorkbook><x:ExcelWorksheets><x:ExcelWorksheet>
      <x:Name>Sheet1</x:Name>
     </x:ExcelWorksheet></x:ExcelWorksheets></x:ExcelWorkbook>
    </xml><![endif]-->
    </head>

    <body link="#0563C1" vlink="#954F72">

    <table border=0 cellpadding=0 cellspacing=0 width=261 style='border-collapse:
     collapse;width:196pt'>
    <!--StartFragment-->
     <col width=87 span=3 style='width:65pt'>
     <tr height=21 style='height:16.0pt'>
      <td height=21 width=87 style='height:16.0pt;width:65pt'>Region</td>
      <td width=87 style='width:65pt'>Q1</td>
      <td width=87 style='width:65pt'>Notes</td>
     </tr>
     <tr height=21 style='height:16.0pt'>
      <td height=21 style='height:16.0pt'>North &amp; East</td>
      <td class=xl65 align=right x:num="1234.5">1,234.50</td>
      <td>R&amp;D &lt;draft&gt; <font class="font5">bold</font><font
      class="font6"> tail</font></td>
     </tr>
     <tr height=42 style='height:32.0pt'>
      <td height=42 class=xl66 width=87 style='height:32.0pt;width:65pt'>South<br>
        West</td>
      <td class=xl65 align=right x:num="-12">-12.00</td>
      <td></td>
     </tr>
     <tr height=21 style='height:16.0pt'>
      <td colspan=2 height=21 class=xl67 style='height:16.0pt'>Merged&nbsp;&nbsp;total</td>
      <td align=right x:num>3</td>
     </tr>
    <!--EndFragment-->
    </table>

    </body>

    </html>
    """

    /// Google Sheets: one line, a `<google-sheets-html-origin>` wrapper, a
    /// `<style>` holding an HTML comment, `<colgroup>`/`<tbody>`, `data-sheets-*`
    /// attributes with entities and a `>` inside a quoted value, a merge as
    /// `rowspan`/`colspan`, a `<br>` in a cell, a `<span>` and a `<a>` link.
    static let googleSheets = #"<meta charset="utf-8"><google-sheets-html-origin><style type="text/css"><!--td {border: 1px solid #cccccc;}br {mso-data-placement:same-cell;}--></style><table xmlns="http://www.w3.org/1999/xhtml" cellspacing="0" cellpadding="0" dir="ltr" border="1" style="table-layout:fixed;font-size:10pt;font-family:Arial;width:0px;border-collapse:collapse;border:none" data-sheets-root="1"><colgroup><col width="100"/><col width="100"/><col width="100"/></colgroup><tbody><tr style="height:21px;"><td style="overflow:hidden;padding:2px 3px 2px 3px;vertical-align:bottom;">Item</td><td style="overflow:hidden;padding:2px 3px 2px 3px;vertical-align:bottom;">Cost</td><td style="overflow:hidden;padding:2px 3px 2px 3px;vertical-align:bottom;">Big?</td></tr><tr style="height:21px;"><td style="overflow:hidden;padding:2px 3px 2px 3px;vertical-align:bottom;" data-sheets-value="{&quot;1&quot;:2,&quot;2&quot;:&quot;Café &amp; bar&quot;}">Café &amp; bar</td><td style="overflow:hidden;padding:2px 3px 2px 3px;vertical-align:bottom;text-align:right;" data-sheets-value="{&quot;1&quot;:3,&quot;3&quot;:1500}" data-sheets-numberformat="{&quot;1&quot;:4,&quot;2&quot;:&quot;&quot;$&quot;#,##0.00&quot;,&quot;3&quot;:1}">$1,500.00</td><td style="overflow:hidden;padding:2px 3px 2px 3px;vertical-align:bottom;" data-sheets-value="{&quot;1&quot;:4,&quot;4&quot;:1}" data-sheets-formula="=IF(R[0]C[-1]>1000,TRUE,FALSE)">TRUE</td></tr><tr style="height:21px;"><td style="overflow:hidden;padding:2px 3px 2px 3px;vertical-align:bottom;" rowspan="2" colspan="2" data-sheets-value="{&quot;1&quot;:2,&quot;2&quot;:&quot;Spanning\ntwo rows&quot;}">Spanning<br>two rows</td><td style="overflow:hidden;padding:2px 3px 2px 3px;vertical-align:bottom;"><span style="font-weight:bold;">7</span></td></tr><tr style="height:21px;"><td style="overflow:hidden;padding:2px 3px 2px 3px;vertical-align:bottom;"><a class="in-cell-link" href="https://example.com/?a=1&amp;b=2" target="_blank">link</a></td></tr></tbody></table>"#

    /// Numbers (Cocoa HTML Writer): a DOCTYPE, a `<title>`, a `<style>`, each
    /// cell's text in `<p>` — two paragraphs are two lines, an empty cell is
    /// `<p><br></p>` — markup on its own lines, a no-break space as `&nbsp;`.
    static let numbers = """
    <!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta http-equiv="Content-Style-Type" content="text/css">
    <title></title>
    <meta name="Generator" content="Cocoa HTML Writer">
    <meta name="CocoaVersion" content="2487.7">
    <style type="text/css">
    p.p1 {margin: 0.0px 0.0px 0.0px 0.0px; font: 10.0px 'Helvetica Neue'}
    table.t1 {border-collapse: collapse}
    td.td1 {border-style: solid; border-width: 1.0px; padding: 4.0px 4.0px 4.0px 4.0px}
    </style>
    </head>
    <body>
    <table cellspacing="0" cellpadding="0" class="t1">
    <tbody>
    <tr>
    <td valign="top" class="td1">
    <p class="p1"><b>Name</b></p>
    </td>
    <td valign="top" class="td1">
    <p class="p1"><b>Total</b></p>
    </td>
    </tr>
    <tr>
    <td valign="middle" class="td2">
    <p class="p2">Line one</p>
    <p class="p2">Line two</p>
    </td>
    <td valign="middle" class="td2">
    <p class="p3">€1&nbsp;234,56</p>
    </td>
    </tr>
    <tr>
    <td valign="middle" class="td2">
    <p class="p4"><br></p>
    </td>
    <td valign="middle" class="td2">
    <p class="p3">0</p>
    </td>
    </tr>
    </tbody>
    </table>
    </body>
    </html>
    """

    /// A web page's table, copied from Safari: page text and a `<script>`
    /// before it, `<thead>` with `<th>`, a `<caption>`, an unclosed `<td>` and
    /// `<tr>` (HTML lets them close themselves), numeric entities, upper-case
    /// tags, a `<sup>` footnote mark, and a second table that is not read.
    static let webPage = """
    <meta charset='utf-8'><p>Some article text with a < sign &amp; more.</p>
    <script type="text/javascript">var x = "<table><tr><td>not this</td></tr></table>";</script>
    <TABLE class="wikitable sortable">
    <CAPTION>Planets</CAPTION>
    <thead><tr><th scope="col">Planet</th><th scope="col">Mass&#160;(kg)</th><th>Moons</th></tr></thead>
    <tbody>
    <TR><TD>Mercury<TD>3.30&#x00D7;10<sup>23</sup><TD>0
    <TR><TD><a href="/wiki/Earth" title="Earth">Earth</a><sup class="reference"><a href="#cite-1">[1]</a></sup><TD>5.97&times;10<sup>24</sup><TD>1
    </tbody>
    </TABLE>
    <table><tr><td>second table</td></tr></table>
    """

    // MARK: - Each app

    func test_excelMac() throws {
        let rows = try XCTUnwrap(TableHTML.rows(fromHTML: Self.excelMac))
        XCTAssertEqual(rows, [
            ["Region", "Q1", "Notes"],
            ["North & East", "1,234.50", "R&D <draft> bold tail"],
            ["South\nWest", "-12.00", ""],
            ["Merged  total", "", "3"],
        ], "the style, the XML island and the fragment comments read as nothing; the merge keeps column C in place")
    }

    func test_googleSheets() throws {
        let rows = try XCTUnwrap(TableHTML.rows(fromHTML: Self.googleSheets))
        XCTAssertEqual(rows, [
            ["Item", "Cost", "Big?"],
            ["Café & bar", "$1,500.00", "TRUE"],
            ["Spanning\ntwo rows", "", "7"],
            ["", "", "link"],
        ], "a `>` in a quoted attribute does not close the tag; the 2×2 merge leaves its covered cells empty")
    }

    func test_numbers() throws {
        let rows = try XCTUnwrap(TableHTML.rows(fromHTML: Self.numbers))
        XCTAssertEqual(rows, [
            ["Name", "Total"],
            ["Line one\nLine two", "€1 234,56"],
            ["", "0"],
        ], "two <p> are two lines, <p><br></p> is an empty cell, the title is not text")
    }

    func test_aWebPageTable() throws {
        let rows = try XCTUnwrap(TableHTML.rows(fromHTML: Self.webPage))
        XCTAssertEqual(rows, [
            ["Planet", "Mass\u{A0}(kg)", "Moons"],
            ["Mercury", "3.30×1023", "0"],
            ["Earth[1]", "5.97×1024", "1"],
        ], "the script's table and the caption are not read; unclosed cells and rows close themselves")
    }

    // MARK: - Rules

    func test_noTable_orNoCell_isNil() {
        XCTAssertNil(TableHTML.rows(fromHTML: "<p>Just text</p>"))
        XCTAssertNil(TableHTML.rows(fromHTML: ""))
        XCTAssertNil(TableHTML.rows(fromHTML: "<table><caption>x</caption></table>"))
        XCTAssertNil(TableHTML.rows(fromHTML: "<!-- <table><tr><td>a</td></tr></table> -->"),
                     "a table inside a comment is not a table")
    }

    func test_whiteSpaceCollapsesAndTrims_butNbspAndEntitiesStay() throws {
        let rows = try XCTUnwrap(TableHTML.rows(fromHTML:
            "<table><tr><td>\n   a \t\n  b   </td><td>&nbsp;&nbsp;lead</td><td>x&#9;y</td></tr></table>"))
        XCTAssertEqual(rows, [["a b", "  lead", "x\ty"]])
    }

    func test_entities() throws {
        let rows = try XCTUnwrap(TableHTML.rows(fromHTML:
            "<table><tr><td>&lt;&gt;&amp;&quot;&apos;</td><td>&#8364;&#x20AC;&euro;</td>"
            + "<td>&bogus; &amp &#xZZ; a&b</td><td>so&shy;ft</td><td>&#0;</td></tr></table>"))
        XCTAssertEqual(rows, [["<>&\"'", "€€€", "&bogus; &amp &#xZZ; a&b", "soft", "\u{FFFD}"]],
                       "an unknown or unterminated entity is kept as written")
    }

    func test_lineBreaks() throws {
        let rows = try XCTUnwrap(TableHTML.rows(fromHTML:
            "<table><tr><td>a <br> b</td><td><br>x</td><td>a<br><br>b</td><td>a<br></td>"
            + "<td><div>one</div><div>two</div></td><td>a<br><br></td></tr></table>"))
        XCTAssertEqual(rows, [["a\nb", "\nx", "a\n\nb", "a", "one\ntwo", "a\n"]],
                       "a cell's last <br> shows nothing, as in a browser")
        XCTAssertEqual(TableHTML.rows(fromHTML: "<table><tr><td><p>A<br></p><p>B</p></td><td><p>A<br><br></p><p>B</p></td><td><p>A<br><br></p></td></tr></table>"),
                       [["A\nB", "A\n\nB", "A\n"]], "nor does a block's last <br>, once")
    }

    func test_spans_padAndKeepColumns() throws {
        let html = """
        <table>
        <tr><td rowspan=3>A</td><td colspan="2">B</td></tr>
        <tr><td>c</td><td>d</td></tr>
        <tr><td>e</td></tr>
        <tr><td>f</td><td>g</td><td>h</td><td>i</td></tr>
        </table>
        """
        XCTAssertEqual(TableHTML.rows(fromHTML: html), [
            ["A", "B", "", ""],
            ["", "c", "d", ""],
            ["", "e", "", ""],
            ["f", "g", "h", "i"],
        ], "a rowspan holds its column in the rows below; every row is padded to the widest")
        XCTAssertEqual(TableHTML.rows(fromHTML: "<table><tr><td colspan=0>a</td><td colspan=x>b</td></tr></table>"),
                       [["a", "b"]], "a nonsense span is one")
        XCTAssertEqual(TableHTML.rows(fromHTML: "<table><tr><td>a</td><td rowspan=2>b</td></tr><tr></tr></table>"),
                       [["a", "b"], ["", ""]], "a rowspan past a row's last cell still holds its column")
    }

    func test_aNestedTableGivesItsTextToItsCell() throws {
        let rows = try XCTUnwrap(TableHTML.rows(fromHTML:
            "<table><tr><td>out<table><tr><td>in1</td><td>in2</td></tr><tr><td>in3</td></tr></table></td><td>z</td></tr></table>"))
        XCTAssertEqual(rows, [["out\nin1 in2\nin3", "z"]])
    }

    func test_anUnclosedTableRunsToTheEnd_andALoneLessThanIsText() throws {
        XCTAssertEqual(TableHTML.rows(fromHTML: "<table><tr><td>1 < 2<td>3 <= 4"), [["1 < 2", "3 <= 4"]])
    }

    // MARK: - Hostile input

    func test_emptyComments_CDATA_andAnUnclosedQuotedAttribute() {
        XCTAssertEqual(TableHTML.rows(fromHTML: "<table><tr><td>a<!-->b<!--->c</td></tr></table>"), [["abc"]],
                       "<!--> and <!---> are empty comments, as browsers read them")
        XCTAssertEqual(TableHTML.rows(fromHTML: "<table><tr><td>a<![CDATA[x]]>b</td></tr></table>"), [["ab"]],
                       "CDATA outside foreign content is a bogus comment ending at the first >")
        XCTAssertEqual(TableHTML.rows(fromHTML: "<table><tr><td>a</td><td title=\"never closed>b</td></tr></table>"),
                       [["a"]], "an unclosed quote runs the tag to the end, and a tag never closed is dropped, as browsers do")
        XCTAssertNil(TableHTML.rows(fromHTML: "<table><tr><td"), "a tag cut off opens nothing")
    }

    /// A hostile `colspan` run stops at the paste limit instead of
    /// materialising tens of millions of cells — and what comes back is over
    /// the limit, so a paste refuses it.
    func test_aHugeSpannedTableStopsAtTheLimit() {
        let html = "<table>" + String(repeating: "<tr><td colspan=1000 rowspan=65534>x</td>", count: 50_000) + "</table>"
        let started = Date()
        let rows = TableHTML.rows(fromHTML: html)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "linear, and stopped early")
        let cells = rows?.reduce(0) { $0 + $1.count } ?? 0
        XCTAssertGreaterThan(cells, TableCSV.figureCellLimit)
        XCTAssertLessThan(cells, TableCSV.figureCellLimit + 70_000, "stopped within a row or two of the limit")
        let block = FigurePaste.Block(cells: (rows ?? []).map { $0.map { _ in Cell?.none } })
        let state = FigureState(kind: .table, table: FigureTable(rows: 1, columns: 1))
        let outcome = FigurePaste.changes(
            state: state, anchor: CellKey(row: state.table.rows[0], column: state.table.columns[0]), block: block)
        if case .tooLarge = outcome {} else { XCTFail("the paste should refuse it, got \(outcome)") }
    }

    // MARK: - Writing

    func test_html_readsBackAsWritten() throws {
        let rows = [
            ["plain", "a & b <c> \"q\"", ""],
            ["  two leading", "trailing ", "in  between"],
            ["line\nbreak", "ends with break\n", "\n"],
            ["tab\there", "no\u{A0}break", "€ ünïcödé 🎉"],
            [" ", "a\r\nb", "x"],
        ]
        let html = TableHTML.html(rows: rows)
        XCTAssertTrue(html.contains("<table>") && html.contains("&amp;") && html.contains("<br>"), html)
        XCTAssertEqual(TableHTML.rows(fromHTML: html), [
            rows[0], rows[1], rows[2], rows[3],
            [" ", "a\nb", "x"],   // every line break reads back as \n
        ])
    }
}
