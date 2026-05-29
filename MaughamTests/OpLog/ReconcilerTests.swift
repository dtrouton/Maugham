// MaughamTests/OpLog/ReconcilerTests.swift
import XCTest
import MaughamCore
@testable import Maugham

final class ReconcilerTests: XCTestCase {
    func test_classifyExternalEdit_diskEqualsDerived_isEcho() {
        let derivedMd = "<!-- ¶a3f9 -->\n\nHello.\n"
        let diskMd = "<!-- ¶a3f9 -->\n\nHello.\n"
        let cls = Reconciler.classify(diskMd: diskMd, derivedMd: derivedMd)
        XCTAssertEqual(cls, .echo)
    }

    func test_classifyExternalEdit_idsIntact_isSilentIngest() {
        let derivedMd = "<!-- ¶a3f9 -->\n\nHello.\n\n<!-- ¶b21c -->\n\nWorld.\n"
        let diskMd = "<!-- ¶a3f9 -->\n\nHello, edited.\n\n<!-- ¶b21c -->\n\nWorld.\n"
        let cls = Reconciler.classify(diskMd: diskMd, derivedMd: derivedMd)
        if case .silentIngest(let changes) = cls {
            XCTAssertEqual(changes.count, 1)
            XCTAssertEqual(changes[0].paragraphId, "a3f9")
            XCTAssertEqual(changes[0].next, "Hello, edited.")
        } else {
            XCTFail("expected .silentIngest; got \(cls)")
        }
    }

    func test_classifyExternalEdit_idsMissing_needsSheet() {
        let derivedMd = "<!-- ¶a3f9 -->\n\nHello.\n"
        let diskMd = "Hello, but the comment got stripped.\n"
        let cls = Reconciler.classify(diskMd: diskMd, derivedMd: derivedMd)
        if case .needsSheet = cls {
            // expected
        } else {
            XCTFail("expected .needsSheet; got \(cls)")
        }
    }
}
