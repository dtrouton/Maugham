import XCTest
import MaughamCore
@testable import Maugham

/// **A piece read in a language** (shell p4 Task 8): which language the faces
/// are read in, what the switch keeps across a change of piece (Denver's
/// answer 2), where the switch shows, the three routes that choose a
/// language, the remembered source-under setting, and the census that
/// translation review's names are gone. Pure, and source censuses.
@MainActor
final class ReadingLanguageTests: XCTestCase {

    private let structure = SubjectSamples.structure
    private let piece = SubjectSamples.pieceID

    // MARK: - What the faces are read in

    func test_anEditionOpenIsReadInItsLanguage() {
        let subject = SubjectSamples.opened(.edition(language: "sr"))
        XCTAssertEqual(ReadingLanguage.of(subject: subject, switched: nil, sourceLanguage: "en"), "sr")
        XCTAssertEqual(ReadingLanguage.of(subject: subject, switched: "es", sourceLanguage: "en"), "sr",
                       "the edition in the centre wins over a switch left on another language")
    }

    func test_theSourceEditionIsReadInNoLanguage() {
        let subject = SubjectSamples.opened(.edition(language: "EN"))
        XCTAssertNil(ReadingLanguage.of(subject: subject, switched: "sr", sourceLanguage: "en"),
                     "the source language, in any case, is no translation")
    }

    func test_aPieceOpenAndFacedIsReadInTheSwitchedLanguage() {
        let faced = SubjectSamples.opened(.item(piece))
        XCTAssertEqual(ReadingLanguage.of(subject: faced, switched: "sr", sourceLanguage: "en"), "sr")
        XCTAssertNil(ReadingLanguage.of(subject: faced, switched: nil, sourceLanguage: "en"))
        let facesElsewhere = WindowSubject(open: .item(piece), faces: .edition(language: "es"))
        XCTAssertNil(ReadingLanguage.of(subject: facesElsewhere, switched: "sr", sourceLanguage: "en"))
        for open in [BinderSubject.project, .canvas, .inbox, .palette, .research("r-1")] {
            XCTAssertNil(ReadingLanguage.of(subject: SubjectSamples.opened(open), switched: "sr",
                                            sourceLanguage: "en"), "\(open)")
        }
    }

    // MARK: - What the switch keeps (answer 2)

    func test_theLanguageCarriesToAPieceThatHasIt() {
        XCTAssertEqual(ReadingLanguage.carried("sr", toPieceWith: ["es", "sr"]), "sr")
        XCTAssertEqual(ReadingLanguage.carried("SR", toPieceWith: ["sr"]), "sr",
                       "the piece's own spelling of the tag is kept")
        XCTAssertNil(ReadingLanguage.carried("sr", toPieceWith: ["es"]),
                     "a chapter without the translation is read in Source")
        XCTAssertNil(ReadingLanguage.carried("sr", toPieceWith: []))
        XCTAssertNil(ReadingLanguage.carried(nil, toPieceWith: ["sr"]),
                     "Source stays Source")
    }

    /// The change of piece applies `carried` — today's unconditional reset is
    /// gone — and a pending reveal still lands after it.
    func test_aChangeOfPieceCarriesTheLanguageInsteadOfResettingIt() throws {
        let lines = SourceScan.codeLines(
            of: try SourceTree.sourceOfType("ReadingLanguageModifier", under: ["Maugham"]))
        let start = try XCTUnwrap(lines.firstIndex { $0.contains(".onChange(of: openDocId)") })
        let body = lines[start..<min(start + 20, lines.endIndex)]
        XCTAssertTrue(body.contains { $0.contains("ReadingLanguage.carried(") })
        XCTAssertFalse(body.contains { $0.contains("editorControl.translationLanguage = nil") },
                       "no unconditional reset to Source on a change of piece")
        XCTAssertTrue(body.contains { $0.contains("startReveal(reveal, waitingForDocument: true)") })
    }

    /// A reveal arriving at a chapter it opened waits for that chapter's
    /// surface even when the carried language already matches.
    func test_aRevealArrivingAtAPieceWaitsForItsSurfaceEvenInTheSameLanguage() {
        let reveal = TranslationReveal(docId: "d", language: "sr", paragraphId: "p")
        XCTAssertFalse(TranslationReveal.waitsForTranslatedSurface(reveal, showing: "sr"))
        XCTAssertTrue(TranslationReveal.waitsForTranslatedSurface(reveal, showing: "sr",
                                                                  arrivingAtPiece: true))
        let source = TranslationReveal(docId: "d", language: nil, paragraphId: "p")
        XCTAssertFalse(TranslationReveal.waitsForTranslatedSurface(source, showing: "sr",
                                                                   arrivingAtPiece: true))
    }

    func test_readInNextLanguageCyclesThroughSource() {
        let langs = ["es", "sr"]
        XCTAssertEqual(ReadingLanguage.next(after: nil, in: langs), "es")
        XCTAssertEqual(ReadingLanguage.next(after: "es", in: langs), "sr")
        XCTAssertNil(ReadingLanguage.next(after: "sr", in: langs))
        XCTAssertEqual(ReadingLanguage.next(after: "de", in: langs), "es")
        XCTAssertNil(ReadingLanguage.next(after: nil, in: []))
    }

    // MARK: - Where the switch shows

    func test_theSwitchShowsOnAPieceWithATranslationOnly() {
        func offer(_ open: BinderSubject, _ languages: [String], current: String? = nil) -> LanguageSwitch.Offer? {
            LanguageSwitch.offer(subject: SubjectSamples.opened(open), structure: structure,
                                 languages: languages, current: current, showsSourceUnder: true)
        }
        XCTAssertEqual(offer(.item(piece), ["es", "sr"])?.languages, ["es", "sr"])
        XCTAssertNil(offer(.item(piece), []), "a piece with no translation has no switch")
        XCTAssertNil(offer(.item(SubjectSamples.partID), ["sr"]), "a Part is not a piece")
        for open in [BinderSubject.project, .edition(language: "sr"), .canvas, .research("r-1")] {
            XCTAssertNil(offer(open, ["sr"]), "\(open)")
        }
        XCTAssertEqual(offer(.item(piece), [], current: "sr")?.languages, ["sr"],
                       "read in a language, the way back to Source never hides")
        XCTAssertEqual(LanguageSwitch.title(of: nil), "Source")
        XCTAssertEqual(LanguageSwitch.title(of: "sr"), LanguageName.title("sr"))
    }

    // MARK: - The three routes

    /// **Toolbar, menu and key all post the one choice**, which the window
    /// answers by keeping the writer's place; the toolbar draws the switch
    /// only where it is offered.
    func test_theToolbarTheMenuAndTheKeyChooseThroughTheOneEvent() throws {
        XCTAssertEqual(LanguageSwitch.payload(for: "sr")[TranslationReveal.languageKey] as? String, "sr")
        XCTAssertTrue(LanguageSwitch.payload(for: nil).isEmpty, "no language is Source")

        let switchFile = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/LanguageSwitch.swift"))
        let chooses = switchFile.filter { $0.contains("LanguageSwitch.choose(") }
        XCTAssertGreaterThanOrEqual(chooses.count, 4,
            "the toolbar's picker, the menu's Source, the menu's languages and ⌃⌘L each choose")
        XCTAssertTrue(switchFile.contains { $0.contains("MaughamEvent.post(.maughamChooseReadingLanguage") })
        XCTAssertTrue(switchFile.contains {
            $0.contains(".keyboardShortcut(LanguageSwitch.nextKey, modifiers: [.command, .control])")
        }, "⌃⌘L, Read In Next Language")

        let window = try SourceTree.read("Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains("if let readingOffer {"), "hidden, not disabled, where not offered")
        XCTAssertTrue(window.contains("LanguageSwitchControl(offer: readingOffer)"))
        XCTAssertTrue(window.contains(".focusedSceneValue(\\.readingOffer, readingOffer)"),
                      "the menu reads the key window's offer")
        let app = try SourceTree.read("Maugham/MaughamApp.swift")
        XCTAssertTrue(app.contains("FocusedReadingItems()"), "View ▸ Read In is in the menu")

        let modifier = SourceScan.codeLines(
            of: try SourceTree.sourceOfType("ReadingLanguageModifier", under: ["Maugham"]))
        XCTAssertTrue(modifier.contains {
            $0.contains(".onKeyWindowCommand(.maughamChooseReadingLanguage, window: window)")
        }, "the window answers the choice")
        XCTAssertTrue(modifier.contains {
            $0.contains(".onKeyWindowCommand(.maughamToggleSourceUnder, window: window)")
        })
    }

    /// ⌃⌘L is the switch's and nobody else's.
    func test_controlCommandLBelongsToTheSwitchAlone() throws {
        var offenders: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") where !file.hasSuffix("LanguageSwitch.swift") {
            for line in SourceScan.codeLines(of: try SourceTree.read(file))
            where line.contains(".control") && line.contains("keyboardShortcut(\"l\"") {
                offenders.append("\(file): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [])
        XCTAssertTrue(KeyboardShortcuts.all.flatMap(\.items).contains {
            $0.label == LanguageSwitch.nextMenuTitle
        }, "the cheat sheet lists ⌃⌘L")
    }

    // MARK: - The remembered setting

    func test_sourceUnderIsOnByDefaultAndRememberedPerProject() throws {
        XCTAssertTrue(UIState().showsSourceUnderTranslation)
        var stored = UIState()
        stored.showsSourceUnderTranslation = false
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(stored)) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "showsSourceUnderTranslation"), "control: the key is written")
        let legacy = try JSONDecoder().decode(UIState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.showsSourceUnderTranslation, "absent decodes as on")
        var off = UIState()
        off.showsSourceUnderTranslation = false
        let round = try JSONDecoder().decode(UIState.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(round.showsSourceUnderTranslation)
        XCTAssertTrue(EditorControl().showsSourceUnder)
    }

    // MARK: - One spelling of a language's name

    func test_aLanguageHasOneSpelling() {
        XCTAssertEqual(TreeEditionRows.title(forLanguage: "sr"), LanguageName.title("sr"))
        XCTAssertEqual(LanguageName.labelled("sr"), "\(LanguageName.title("sr")) (sr)")
        XCTAssertEqual(LanguageName.labelled("zzzz"), "zzzz")
    }

    // MARK: - Translation review is gone

    /// **No `TranslationReview`/`translationReview` name remains in the app**
    /// but the right column's review pane, which Task 9 deletes (its file, the
    /// content case and the column's arm, and the round report's one call
    /// into the pane's logic). Task 9 empties `inheritedByTask9`.
    func test_noTranslationReviewNamesRemain() throws {
        let inheritedByTask9: [String: Int] = [
            "Maugham/Views/RightColumnContent.swift": 3,
            "Maugham/Views/RightColumn.swift": 2,
            "Maugham/Views/Publish/TranslationRoundReportHost.swift": 1,
        ]
        var found: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham")
        where !file.hasSuffix("Views/TranslationReviewPane.swift") {
            let count = try SourceTree.read(file).components(separatedBy: "\n").filter {
                $0.contains("TranslationReview") || $0.contains("translationReview")
            }.count
            if count > 0 { found[file] = count }
        }
        XCTAssertEqual(found, inheritedByTask9)
        // Control: the census reads real files.
        XCTAssertFalse(try SourceTree.read("Maugham/Views/TranslationReviewPane.swift").isEmpty)
    }
}
