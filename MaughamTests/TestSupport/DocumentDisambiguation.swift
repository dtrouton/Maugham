@testable import Maugham

/// `Document`, in this test module, is Maugham's.
///
/// The macOS 27 SDK's SwiftUI declares `public protocol Document`, so a test
/// file that imports SwiftUI beside `@testable import Maugham` sees two and the
/// bare name is ambiguous (`'Document' is ambiguous for type lookup`, first
/// seen 2026-09-17 under Xcode 27.0). The app target never notices — a module's
/// own declaration shadows an imported one — and that is the rule used here: a
/// declaration in the TEST module shadows both imports, so no test file has to
/// qualify the name.
typealias Document = Maugham.Document
