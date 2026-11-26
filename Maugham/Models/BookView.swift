import Foundation

/// How the Book (the project subject) is shown in the centre.
public enum BookView: String, Codable, Sendable, CaseIterable {
    case cards, outline, status
}

/// How an edition is shown in the centre (shell p4 Task 4): its typeset
/// book, or its Status. Remembered once for the window, as `BookView` is.
public enum EditionView: String, Codable, Sendable, CaseIterable {
    case book, status
}
