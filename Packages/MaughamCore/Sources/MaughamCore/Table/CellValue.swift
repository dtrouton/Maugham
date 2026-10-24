import Foundation

public enum FormulaError: String, Codable, Sendable, CaseIterable {
    case divideByZero = "#DIV/0!", ref = "#REF!", name = "#NAME?", value = "#VALUE!", num = "#NUM!", circular = "#CIRC!"
}

public enum CellValue: Equatable, Codable, Sendable {
    case empty
    case number(Double)
    case date(Int)   // Excel serial day, 1900 system
    case text(String)
    case bool(Bool)
    case error(FormulaError)
}

public enum CellContent: Equatable, Codable, Sendable {
    case value(CellValue)
    case formula(Formula)
}

public struct Cell: Equatable, Codable, Sendable {
    public var content: CellContent
    public var format: CellFormat
    public var alignment: CellAlignment

    public init(content: CellContent, format: CellFormat = .init(), alignment: CellAlignment = .automatic) {
        self.content = content
        self.format = format
        self.alignment = alignment
    }
}
