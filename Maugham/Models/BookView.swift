import Foundation

/// How the Book (the project subject) is shown in the centre.
public enum BookView: String, Codable, Sendable, CaseIterable {
    case cards, outline, status
}
