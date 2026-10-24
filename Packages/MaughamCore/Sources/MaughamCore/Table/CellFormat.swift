import Foundation

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
    public var number: NumberFormat = .general
    public var negatives: NegativeStyle = .minus
    public var zeroAsDash = false

    public init(number: NumberFormat = .general, negatives: NegativeStyle = .minus, zeroAsDash: Bool = false) {
        self.number = number
        self.negatives = negatives
        self.zeroAsDash = zeroAsDash
    }
}

public enum CellAlignment: String, Codable, Sendable { case automatic, left, center, right }
