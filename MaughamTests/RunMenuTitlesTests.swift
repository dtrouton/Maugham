import XCTest
@testable import Maugham

/// **The File menu's four titles over two keys** (two loops P3 Task 1, ADR 0031).
///
/// The pin is the pure function, deliberately: a focused-value round trip needs
/// a key window and a mounted menu, which is the shape tripwire 33 exists to
/// keep out of this suite. What a test CAN own without a window is the whole
/// decision — every persona plus the unfocused case — and a source census that
/// the two events the items post did not move while their wording did.
final class RunMenuTitlesTests: XCTestCase {

    // MARK: - The titles

    func test_authorsKeysAreACheckAndAReread() {
        XCTAssertEqual(RunMenuTitles.check(for: .author), "Check Writing")
        XCTAssertEqual(RunMenuTitles.cold(for: .author), "Reread")
    }

    func test_reviewsKeysAreARoundAndFreshEyes() {
        XCTAssertEqual(RunMenuTitles.check(for: .review), "Run Round")
        XCTAssertEqual(RunMenuTitles.cold(for: .review), "Fresh Eyes")
    }

    /// Plan and Publish centre something other than the manuscript, and neither
    /// runs a round — so they read in Author's words rather than inventing a
    /// third vocabulary for a key the writer will press from the desk.
    func test_planAndPublishReadInAuthorsWords() {
        for persona in [Persona.plan, .publish] {
            XCTAssertEqual(RunMenuTitles.check(for: persona), "Check Writing", "\(persona)")
            XCTAssertEqual(RunMenuTitles.cold(for: persona), "Reread", "\(persona)")
        }
    }

    /// With no project window focused, ⌘R is already a no-op at the receiver —
    /// so the item reads as the persona a window opens in (`Persona.default`)
    /// rather than as a fifth, hedged wording.
    func test_noFocusedWindowReadsAsTheDefaultPersona() {
        XCTAssertEqual(Persona.default, .author, "The nil arm is Author's wording because Author is the default.")
        XCTAssertEqual(RunMenuTitles.check(for: nil), RunMenuTitles.check(for: .author))
        XCTAssertEqual(RunMenuTitles.cold(for: nil), RunMenuTitles.cold(for: .author))
    }

    /// **The table is total.** `RunMenuTitles`' own switches are exhaustive over
    /// `Persona?` with no `default`, so a fifth persona is a compile error there
    /// — this asserts the four this test enumerates ARE the four, so a fifth
    /// arriving with a title cannot arrive without a case here.
    func test_everyPersonaIsCoveredByThisSuite() {
        XCTAssertEqual(Set(Persona.allCases), [.plan, .author, .review, .publish])
        for persona in Persona.allCases {
            XCTAssertFalse(RunMenuTitles.check(for: persona).isEmpty, "\(persona)")
            XCTAssertFalse(RunMenuTitles.cold(for: persona).isEmpty, "\(persona)")
        }
    }

    /// The two keys never collide in one persona — a menu with two items
    /// reading the same words is a menu the writer cannot use.
    func test_theTwoKeysNeverShareATitle() {
        for persona in Persona.allCases {
            XCTAssertNotEqual(RunMenuTitles.check(for: persona),
                              RunMenuTitles.cold(for: persona), "\(persona)")
        }
    }

    // MARK: - What the items post did NOT move

    /// **The wording moved; the wiring did not.** Both items post exactly the
    /// event they always posted, and the receiver mints the `RunKind` from the
    /// persona (ADR 0031) — so a persona reaching the *post* here would be the
    /// same decision made twice, in two places that can disagree.
    func test_eachCompilerEventIsPostedExactlyOnceFromTheMenu() throws {
        let source = try menuSource()
        XCTAssertEqual(source.components(separatedBy: "MaughamEvent.postCompilerRun()").count - 1, 1,
                       "postCompilerRun() must appear exactly once in MaughamApp.swift.")
        XCTAssertEqual(source.components(separatedBy: "MaughamEvent.postCompilerFreshEyes()").count - 1, 1,
                       "postCompilerFreshEyes() must appear exactly once in MaughamApp.swift.")
    }

    /// The titles are read from `RunMenuTitles` rather than written out, and
    /// the keys are still ⌘R and ⌘⇧R.
    func test_theMenuTitlesTheItemsFromTheOneEnumOnTheSameTwoKeys() throws {
        let source = try menuSource()
        XCTAssertTrue(source.contains("Button(RunMenuTitles.check(for: persona))"),
                      "The ⌘R item must take its title from RunMenuTitles.")
        XCTAssertTrue(source.contains("Button(RunMenuTitles.cold(for: persona))"),
                      "The ⌘⇧R item must take its title from RunMenuTitles.")
        XCTAssertTrue(source.contains(".keyboardShortcut(\"r\", modifiers: .command)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"r\", modifiers: [.command, .shift])"))
    }

    /// **No `.disabled` on the focused value.** A run with no project window is
    /// already a no-op at the receiver; greying the item out would make the
    /// writer's own muscle memory look broken while a sheet held focus.
    func test_theRunItemsAreNeverDisabled() throws {
        let source = try menuSource()
        let view = try XCTUnwrap(source.range(of: "private struct FocusedRunButtons: View {"))
        let rest = source[view.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n}\n"))
        let declaration = rest[..<end.lowerBound]
        XCTAssertTrue(declaration.contains("MaughamEvent.postCompilerRun()")
                      && declaration.contains("MaughamEvent.postCompilerFreshEyes()"),
                      "The slice this scans must be the whole view — it holds both items.")
        XCTAssertFalse(declaration.contains(".disabled("),
                       "FocusedRunButtons must not disable either item.")
    }

    /// **The window publishes what the menu reads, from exactly one place.**
    /// Deleting the line leaves every title correct in isolation and every menu
    /// item stuck on Author's words; a SECOND publish is two scene values for
    /// one fact, and which one wins is SwiftUI's business rather than ours.
    ///
    /// The home is `PersonaModifier`, whose whole subject is the persona — it
    /// owns the binding and is the one place the window's mode is written.
    /// (Task 1's fix round moved it off `CanvasPromotionModifier`, which
    /// published to the same scene and coupled the File menu's wording to
    /// canvas plumbing for no reason.)
    func test_theWindowPublishesItsPersonaFromThePersonaModifierAlone() throws {
        let source = try String(contentsOf: repoFile("Maugham/Views/ProjectWindow.swift"), encoding: .utf8)
        let publish = ".focusedSceneValue(\\.persona, persona)"
        XCTAssertEqual(source.components(separatedBy: publish).count - 1, 1,
                       "The persona must be published to the scene exactly once.")
        let modifier = try XCTUnwrap(source.range(of: "struct PersonaModifier: ViewModifier {"))
        let rest = source[modifier.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n}\n"))
        let declaration = rest[..<end.lowerBound]
        XCTAssertTrue(declaration.contains(".onKeyWindowCommand(.maughamSetPersona"),
                      "The slice this scans must be PersonaModifier's own declaration.")
        XCTAssertTrue(declaration.contains(publish),
                      "PersonaModifier — which owns the persona binding — is where the publish belongs.")
    }

    // MARK: - Helpers

    private func menuSource() throws -> String {
        try String(contentsOf: repoFile("Maugham/MaughamApp.swift"), encoding: .utf8)
    }

    private func repoFile(_ relativePath: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // MaughamTests
        url.deleteLastPathComponent() // repo root
        return url.appendingPathComponent(relativePath)
    }
}
