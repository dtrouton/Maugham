import XCTest
import MaughamCore
@testable import Maugham

/// **The window's Lock** (shell p1 Task 5): what replaced the Review
/// persona's read-only research, palette and figure surfaces.
///
/// The decisions are pure functions (tripwire 33: no control is pressed and
/// waited on): `WindowLock.refusesEdits`, `FigureActions.windowRefusesWrites`
/// and `BinderTreeSectionsState.offersNewTable`. What each mounted surface
/// draws while locked is `LockedResearchSurfaceTests`', `FigureCentreGridTests`'
/// and `ResearchTableGridTests`' to pin; that the window threads one Lock to
/// every site is this file's census.
@MainActor
final class LockTests: XCTestCase {

    // MARK: - Per window, off, never stored

    /// Every window opens unlocked, and nothing on disk remembers a Lock: the
    /// window's state is initialised from `atOpen`, and `UIState` carries no
    /// key for it.
    func test_lockOffByDefaultAndNotStored() throws {
        XCTAssertFalse(WindowLock.atOpen, "a window opens unlocked")
        XCTAssertFalse(WindowLock.refusesEdits(isLocked: WindowLock.atOpen),
                       "and an unlocked window refuses nothing of its own")

        let window = try SourceTree.read("Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains("@State private var isLocked = WindowLock.atOpen"),
                      "the Lock is the window's own transient state, off at open")

        let stored = String(decoding: try JSONEncoder().encode(UIState()), as: UTF8.self)
        XCTAssertFalse(stored.lowercased().contains("lock"),
                       "UIState must carry no Lock: it is per window and never stored — \(stored)")
        let uiState = try SourceTree.read("Maugham/Stores/UIState.swift")
        XCTAssertFalse(uiState.contains("isLocked"), "UIState names no Lock")
    }

    // MARK: - What Lock refuses

    /// A research note (and a palette card, and a Research table) in a locked
    /// window reads and never edits: the centre and the beside inspector hand
    /// `ResearchSubjectCentre`/`ResearchSubjectInspector` this as `readOnly`.
    func test_lockRefusesAResearchNoteEdit() {
        XCTAssertTrue(WindowLock.refusesEdits(isLocked: true))
        XCTAssertFalse(WindowLock.refusesEdits(isLocked: false), "control: unlocked edits")
    }

    /// **A palette card open beside the centre reads while locked** (carried
    /// from shell plan 1, closed in plan 2 Task 4): the beside preview asks the
    /// same `readOnly` the centre's card asks, through one route, and mounts
    /// the read view — hidden, not disabled. Before, the beside arm mounted
    /// `PaletteCardEditor` whatever the Lock said.
    func test_lockRefusesAPaletteCardEditBeside() throws {
        XCTAssertEqual(PaletteCardSurface.of(readOnly: WindowLock.refusesEdits(isLocked: true)), .read)
        XCTAssertEqual(PaletteCardSurface.of(readOnly: WindowLock.refusesEdits(isLocked: false)), .edit,
                       "control: unlocked, the card edits")

        let code = try SourceTree.read("Maugham/Views/ResearchSubjectColumns.swift")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let asks = code.filter { $0.contains("PaletteCardSurface.of(readOnly: readOnly)") }
        let editors = code.filter { $0.contains("PaletteCardEditor(") }
        XCTAssertEqual(asks.count, 2, "the centre's card and the beside card both ask the one route")
        XCTAssertEqual(editors.count, 2, "and each mounts the editor only on its `.edit` arm")
    }

    /// A figure write — the inspector's actions, the tree row's menu, the
    /// centre grid — is refused by the window while locked.
    func test_lockRefusesAFigureWrite() {
        let control = EditorControl()
        XCTAssertTrue(FigureActions.windowRefusesWrites(control: control, isLocked: true))
        XCTAssertFalse(FigureActions.windowRefusesWrites(control: control, isLocked: false),
                       "control: an unlocked, writable window refuses nothing of its own")
    }

    /// Research's New Table is not offered while locked: the table it would
    /// make could not be edited.
    func test_lockRefusesNewTable() {
        XCTAssertFalse(BinderTreeSectionsState.offersNewTable(shareIsReadOnly: false, isLocked: true))
        XCTAssertTrue(BinderTreeSectionsState.offersNewTable(shareIsReadOnly: false, isLocked: false),
                      "control: unlocked offers it")
    }

    // MARK: - Lock only adds

    /// **A posture that refuses still refuses with Lock off** — a yield to
    /// the piece's own writer and a posture still settling each refuse a
    /// figure write through `FigureActions.mayEdit`'s posture door with the
    /// window's own refusal (the Lock included) off; the writer's own hand
    /// is the control. And a view-only share and ⌘⌥⇧R still refuse with Lock
    /// off. (Another author's piece, through a real store:
    /// `FigureInspectorTests.test_theWritingActionsAreHiddenWhenThePostureOrTheShareForbids`.)
    func test_postureRefusalHoldsWithLockOff() {
        let unlocked = FigureActions.windowRefusesWrites(control: EditorControl(), isLocked: false)
        XCTAssertFalse(unlocked, "premise: the window refuses nothing of its own")
        let yielding = Posture(.unrestricted, yieldingTo: "Sam")
        XCTAssertFalse(yielding.allows(.editFigure), "premise: a yield refuses a figure write")
        XCTAssertFalse(FigureActions.mayEdit(windowRefusesWrites: unlocked, posture: yielding),
                       "a yielding posture refuses with Lock off")
        XCTAssertFalse(FigureActions.mayEdit(windowRefusesWrites: unlocked, posture: .settling),
                       "a posture still settling refuses with Lock off")
        XCTAssertFalse(FigureActions.mayEdit(windowRefusesWrites: unlocked, posture: nil),
                       "no posture at all (no session) refuses")
        XCTAssertTrue(FigureActions.mayEdit(windowRefusesWrites: unlocked, posture: .author),
                      "control: the writer's own hand with Lock off edits")

        let share = EditorControl()
        share.shareIsReadOnly = true
        XCTAssertTrue(FigureActions.windowRefusesWrites(control: share, isLocked: false),
                      "a view-only share refuses with Lock off")
        XCTAssertFalse(BinderTreeSectionsState.offersNewTable(shareIsReadOnly: true, isLocked: false),
                       "…and offers no New Table")
        let reviewing = EditorControl()
        reviewing.isManualReviewMode = true
        XCTAssertTrue(FigureActions.windowRefusesWrites(control: reviewing, isLocked: false),
                      "⌘⌥⇧R refuses with Lock off")
    }

    /// **Lock never permits what the window otherwise refuses**: over every
    /// combination of the share and ⌘⌥⇧R, locking can only turn a permit into
    /// a refusal, never the reverse.
    func test_lockNeverPermitsWhatPostureRefuses() {
        // The posture's door: over a refusing and a permitting posture,
        // locking never turns a refusal into a permit.
        for posture in [Posture.author, .settling, Posture(.unrestricted, yieldingTo: "Sam")] {
            let off = FigureActions.mayEdit(
                windowRefusesWrites: FigureActions.windowRefusesWrites(control: EditorControl(), isLocked: false),
                posture: posture)
            let on = FigureActions.mayEdit(
                windowRefusesWrites: FigureActions.windowRefusesWrites(control: EditorControl(), isLocked: true),
                posture: posture)
            XCTAssertFalse(on, "locked never edits a figure (\(posture))")
            XCTAssertFalse(on && !off, "Lock permitted what the posture refused (\(posture))")
        }
        for share in [false, true] {
            for manualReview in [false, true] {
                let control = EditorControl()
                control.shareIsReadOnly = share
                control.isManualReviewMode = manualReview
                let unlocked = FigureActions.windowRefusesWrites(control: control, isLocked: false)
                let locked = FigureActions.windowRefusesWrites(control: control, isLocked: true)
                XCTAssertTrue(locked, "locked refuses (share \(share), ⌘⌥⇧R \(manualReview))")
                if unlocked {
                    XCTAssertTrue(locked, "Lock unlocked a refusal (share \(share), ⌘⌥⇧R \(manualReview))")
                }
            }
            let offeredUnlocked = BinderTreeSectionsState.offersNewTable(shareIsReadOnly: share, isLocked: false)
            let offeredLocked = BinderTreeSectionsState.offersNewTable(shareIsReadOnly: share, isLocked: true)
            XCTAssertFalse(offeredLocked && !offeredUnlocked, "Lock offered New Table the share refused")
            XCTAssertFalse(offeredLocked, "locked offers no New Table (share \(share))")
        }
    }

    // MARK: - The sites

    /// The files that ask `WindowLock.refusesEdits`, and how many times each:
    /// every site that read the Review persona's `editsResearchInTheCentre`
    /// or `editsFigures`, now asking the Lock in the same position.
    static let lockSites: [String: Int] = [
        "Maugham/Views/CentreColumn.swift": 1,          // research centre readOnly
        "Maugham/Views/FigureActions.swift": 1,         // windowRefusesWrites
        "Maugham/Views/BinderTreeSections.swift": 1,    // offersNewTable
        "Maugham/Views/FigureSubjectColumns.swift": 1,  // centre grid isReviewMode
        "Maugham/Views/Palette/PaletteWallView.swift": 1, // the wall's card arm
        // `PulledUp.refusesEdits` — what is pulled up, and the centre's own
        // research details: the right column's one question since its own
        // research arm went (shell p3 Task 9; `PulledUpView` asks it for both).
        "Maugham/Views/LockToggle.swift": 1,
    ]

    /// **Every lock site asks the one answer.** A site that stopped asking
    /// would pass every mounted test that happens not to visit it; this census
    /// names them. (Its "no file asks the old read-only predicates" half
    /// retired with those predicates, shell p1 Task 6 — the compiler holds it.)
    func test_everyLockSiteAsksTheOneAnswer() throws {
        var counts: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let text = try SourceTree.read(file)
            for line in text.components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                if code.contains("WindowLock.refusesEdits(isLocked:") {
                    counts[file, default: 0] += 1
                }
            }
        }
        XCTAssertEqual(counts, Self.lockSites)
    }

    /// The files that ask `PulledUp.refusesEdits(isLocked:)` — Lock's answer
    /// for one pulled-up kind — and how many times each. The right column's
    /// research inspector asked `WindowLock` itself until its arm became
    /// `PulledUpView`'s (shell p3 Task 9); this is where that site is counted
    /// now, beside the pulled-up note's.
    static let pulledUpLockSites: [String: Int] = [
        // `face(of:)` — a pulled-up research item, card or table; and
        // `centreResearchIsReadOnly` — the centre's own research details.
        "Maugham/Views/PulledUpView.swift": 2,
    ]

    func test_everyPulledUpLockSiteAsksTheOneAnswer() throws {
        var counts: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let text = try SourceTree.read(file)
            for line in text.components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("func refusesEdits(") else { continue }
                if code.contains(".refusesEdits(isLocked:"),
                   !code.contains("WindowLock.refusesEdits(isLocked:") {
                    counts[file, default: 0] += 1
                }
            }
        }
        XCTAssertEqual(counts, Self.pulledUpLockSites)
        // The centre-details arm is one of them, by name.
        let view = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/PulledUpView.swift"))
            .joined(separator: "\n")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(view.contains(
            "researchInspector(id, showsPreview: false, readOnly: Self.centreResearchIsReadOnly(id, isLocked: isLocked))"),
            "the centre's research details no longer ask Lock")
    }

    /// **The centre's research details under Lock**: a research item in the
    /// centre with nothing pulled up draws its details (citation, tags,
    /// versions) in the pulled-up position — read-only while the window is
    /// locked, editable otherwise.
    func test_theCentresResearchDetailsAreReadOnlyUnderLock() {
        XCTAssertTrue(PulledUpView.centreResearchIsReadOnly("r1", isLocked: true))
        XCTAssertFalse(PulledUpView.centreResearchIsReadOnly("r1", isLocked: false),
                       "control: unlocked, the details are edited")
        // …and it is the arm the content table names for that subject.
        let inTheCentre = WindowSubject(open: .research("r1"), faces: .research("r1"))
        XCTAssertEqual(RightColumnContent.of(
            position: .pulledUp, subject: inTheCentre, translationLanguage: nil,
            structure: [], projectType: .novel), .centreDetails(.research("r1")))
        // The same answer as the item pulled up.
        XCTAssertEqual(PulledUpView.centreResearchIsReadOnly("r1", isLocked: true),
                       PulledUp.research("r1").refusesEdits(isLocked: true))
    }

    // MARK: - The toggle

    func test_theToggleSaysWhatAPressDoes() {
        XCTAssertEqual(LockToggle.symbol(isLocked: true), "lock")
        XCTAssertEqual(LockToggle.symbol(isLocked: false), "lock.open")
        XCTAssertEqual(LockToggle.help(isLocked: false), "Lock research and figures")
        XCTAssertEqual(LockToggle.help(isLocked: true), "Unlock research and figures")
        // The View menu's item (⌘⌥⇧L) and the padlock's tooltip name what it
        // locks, and the tooltip says what it does not (appraisal, Lock).
        XCTAssertEqual(LockToggle.menuTitle(isLocked: false), "Lock Research and Figures")
        XCTAssertEqual(LockToggle.menuTitle(isLocked: true), "Unlock Research and Figures")
        XCTAssertTrue(LockToggle.tooltip(isLocked: false).contains("manuscript stays editable"))
        for locked in [false, true] {
            XCTAssertTrue(LockToggle.tooltip(isLocked: locked).hasPrefix(LockToggle.help(isLocked: locked)))
            XCTAssertTrue(LockToggle.tooltip(isLocked: locked).contains("\u{2318}\u{2325}\u{21E7}L"))
        }
    }

    /// **⌘⌥⇧L is the padlock's press**: the View menu posts the key window's
    /// toggle, and the window's receiver flips its Lock — the one write the
    /// toolbar's button makes.
    func test_theLockHasAMenuKeyThatFlipsTheWindowsLock() throws {
        let app = SourceScan.codeLines(of: try SourceTree.read("Maugham/MaughamApp.swift"))
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(app.contains(
            "Button(LockToggle.menuTitle(isLocked: chrome?.isLocked ?? false)) { "
            + "MaughamEvent.post(.maughamToggleLock, to: .keyWindow) } "
            + ".keyboardShortcut(\"l\", modifiers: [.command, .option, .shift])"), app)
        let window = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ProjectWindow.swift"))
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(window.contains(
            ".onKeyWindowCommand(.maughamToggleLock, window: window) { _ in isLocked.toggle() }"))
    }
}

/// **The window toolbar — the Lock's — hides under `⌘\`** (re-made from the
/// retired persona bar's visibility tests, shell p1 Task 6): focus mode exists
/// to remove that chrome, and nothing in this codebase hides automatically.
final class WindowToolbarVisibilityTests: XCTestCase {
    func test_theToolbarIsHiddenInNoChromeFocusMode() {
        XCTAssertFalse(ProjectWindow.windowToolbarIsVisible(isNoChromeOn: true))
    }

    func test_theToolbarIsVisibleNormally() {
        XCTAssertTrue(ProjectWindow.windowToolbarIsVisible(isNoChromeOn: false))
    }
}
