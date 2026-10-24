import Foundation

/// The book's language as a table cell shows it: separators, currency, day/month order,
/// and the financial year's first month. Pure value; built from a language tag.
public struct TableLocale: Equatable, Sendable {
    /// `languageTag` as stored on a body ("en-GB", "es", "en_us", nil = the source). Region: the tag's, else `fallbackRegion`
    /// (the paper-size rule R-S5). `financialYearStartMonth` 1...12.
    public init(languageTag: String?, fallbackRegion: String? = Locale.current.region?.identifier, financialYearStartMonth: Int = 1) {
        let subtags = (languageTag ?? "").split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        let language = subtags.first.flatMap { $0.count >= 2 && $0.allSatisfy(\.isLetter) ? $0.lowercased() : nil } ?? "en"
        let tagged = subtags.dropFirst().first { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        let region = (tagged ?? fallbackRegion).flatMap { $0.count == 2 ? $0.uppercased() : nil }
        let resolved = Locale(identifier: region.map { "\(language)_\($0)" } ?? language)
        locale = resolved
        let probe = NumberFormatter()
        probe.locale = resolved
        probe.numberStyle = .decimal
        decimalSeparator = probe.decimalSeparator ?? "."
        groupingSeparator = probe.groupingSeparator ?? ","
        currencySymbol = resolved.currencySymbol ?? ""
        let template = DateFormatter.dateFormat(fromTemplate: "dMy", options: 0, locale: resolved) ?? "d/M/y"
        let d = template.firstIndex(of: "d"), m = template.firstIndex(of: "M")
        dayFirst = (d != nil && m != nil) ? d! < m! : true
        self.financialYearStartMonth = (1...12).contains(financialYearStartMonth) ? financialYearStartMonth : 1
    }

    public let locale: Locale            // language + resolved region
    public let decimalSeparator: String
    public let groupingSeparator: String
    public let currencySymbol: String
    public let dayFirst: Bool            // from the locale's "dMy" template: d before M
    public let financialYearStartMonth: Int
}
