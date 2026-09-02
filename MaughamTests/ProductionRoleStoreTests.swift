import XCTest
@testable import Maugham
import MaughamCore

/// The production-role store seam (publish department, Task 4): a translator is
/// minted **lazily**, on the first caller that asks for their language, and the
/// designer is simply always there — read without a write of any kind.
@MainActor
final class ProductionRoleStoreTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// A loaded novel project with its async load work settled, so a test that
    /// asserts "nothing was written" isn't racing `load`'s own tail.
    private func loadedNovel(named name: String) async throws -> (URL, ProjectStore) {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return (url, store)
    }

    /// The manifest's bytes AND its modification date.
    ///
    /// **Bytes alone are not enough to prove nothing was written** —
    /// `StatementStoreTests`' finding, and it applies verbatim here.
    /// `ProjectManifest.modified` round-trips through whole-second ISO8601, so a
    /// verb that stamps and re-saves within the same second as the load produces
    /// a byte-identical file: a real write that a byte comparison calls
    /// unchanged. The mtime sees it.
    private struct ManifestState: Equatable {
        var bytes: Data
        var modified: Date?
    }

    private func manifestState(of projectURL: URL) throws -> ManifestState {
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        let values = try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey])
        return ManifestState(
            bytes: try Data(contentsOf: manifestURL),
            modified: values?.contentModificationDate)
    }

    private func storedDesigner(_ store: ProjectStore) -> ProductionRole? {
        store.manifest.productionRoles.first {
            if case .designer = $0.role { return true }
            return false
        }
    }

    // MARK: - The translator mints once

    func test_mintingATranslatorTwiceReturnsTheSameRole() async throws {
        let (url, store) = try await loadedNovel(named: "TwiceMinted")

        let first = try await store.translatorRole(for: "es")
        XCTAssertEqual(store.manifest.productionRoles.count, 1)

        let afterMint = try manifestState(of: url)
        // A whole second, so a second save is visible in `modified` as well as
        // in the mtime — the same discipline the adoption tests use.
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let second = try await store.translatorRole(for: "es")
        XCTAssertEqual(second.id, first.id, "find-or-create must find before it creates")
        XCTAssertEqual(store.manifest.productionRoles.count, 1,
                       "a second ask must not mint a second translator")
        XCTAssertEqual(try manifestState(of: url), afterMint,
                       "finding an existing translator must cost nothing on disk")
    }

    func test_aListedLanguageMintsWithItsPresetNameAndSurvivesAReload() async throws {
        let (url, store) = try await loadedNovel(named: "PresetName")

        let role = try await store.translatorRole(for: "es")
        XCTAssertEqual(role.role, ProductionRole.Role.translator(language: "es"))
        XCTAssertEqual(role.name, "Cortázar",
                       "a listed language mints WITH its preset name")
        XCTAssertEqual(role.effectiveName, "Cortázar")

        // Identity is what a later annotation byline is signed with, so it has
        // to survive the round trip through disk.
        let reloaded = try await ProjectStore.load(from: url)
        await reloaded.wordCountPopulationTask?.value
        XCTAssertEqual(reloaded.manifest.productionRoles.map(\.id), [role.id])
        XCTAssertEqual(reloaded.manifest.productionRoles.first?.role,
                       ProductionRole.Role.translator(language: "es"))
        XCTAssertEqual(reloaded.manifest.productionRoles.first?.effectiveName, "Cortázar")
    }

    func test_anUnlistedLanguageMintsUnnamedAndStillHasSomethingToShow() async throws {
        let (_, store) = try await loadedNovel(named: "UnlistedLanguage")

        let role = try await store.translatorRole(for: "sv")
        XCTAssertNil(role.name,
                     "no preset for this language — the writer names them, we don't guess")
        XCTAssertFalse(role.effectiveName.isEmpty,
                       "a desk row needs something to print; a blank reads as a bug")
        XCTAssertEqual(role.effectiveName, "SV")
    }

    /// One person per language, whatever case the edition's tag arrived in. A
    /// publish config carrying `ES` and a preview carrying `es` must not mint
    /// two translators of the same book.
    func test_theTagsCaseDoesNotMintASecondTranslator() async throws {
        let (_, store) = try await loadedNovel(named: "TagCase")

        let lower = try await store.translatorRole(for: "es")
        let upper = try await store.translatorRole(for: "ES")
        XCTAssertEqual(upper.id, lower.id)
        XCTAssertEqual(store.manifest.productionRoles.count, 1)
    }

    /// A regional tag is a language of its own — `defaultTranslatorName`'s table
    /// is deliberately exact, and so is this lookup.
    func test_aRegionalTagIsItsOwnTranslator() async throws {
        let (_, store) = try await loadedNovel(named: "RegionalTag")

        let plain = try await store.translatorRole(for: "es")
        let regional = try await store.translatorRole(for: "es-MX")
        XCTAssertNotEqual(regional.id, plain.id)
        XCTAssertNil(regional.name)
        XCTAssertEqual(store.manifest.productionRoles.count, 2)
    }

    /// **An empty tag would mint an identity that does not survive its own
    /// round trip.** `ProductionRole.Role.translator(language: "")` encodes as
    /// `"translator:"`, which Task 3's decoder deliberately reads back as
    /// `.unknown("translator:")` — so the row would stop matching any language
    /// on the next load and the *next* ask would mint another one, for ever.
    func test_anEmptyLanguageIsRefusedAndMintsNothing() async throws {
        let (url, store) = try await loadedNovel(named: "EmptyLanguage")
        let before = try manifestState(of: url)

        for tag in ["", "   ", "\n"] {
            do {
                _ = try await store.translatorRole(for: tag)
                XCTFail("expected a refusal for \(tag.debugDescription)")
            } catch let error as ProjectStoreError {
                XCTAssertEqual(error, .productionRoleLanguageEmpty)
            }
        }

        XCTAssertTrue(store.manifest.productionRoles.isEmpty)
        XCTAssertEqual(try manifestState(of: url), before,
                       "a refusal must leave nothing behind")
    }

    /// **A tag that is still not a language tag once lowercased is refused at
    /// the store rather than by each caller** (issue #43, F-F). Every shipped
    /// caller lowercases and validates upstream today — `DepartmentPaneHost`
    /// `.addLanguage` and `DepartmentCastSheet` both do — so this guard is
    /// unreachable through the surfaces as they stand. That is the reason it
    /// belongs here and not there: the tag flows on into `editions/<lang>.md`,
    /// where a path character would escape the folder, and the next caller to
    /// arrive inherits the refusal instead of having to remember the rule.
    ///
    /// **Case is NOT what this gate is about.** The tag is lowercased before it
    /// is tested and stored verbatim afterwards, so `ES` and `es-MX` mint
    /// exactly as they always have — `test_theTagsCaseDoesNotMintASecondTranslator`
    /// and `test_aRegionalTagIsItsOwnTranslator` pin that and are untouched.
    /// This refuses only what no amount of lowercasing makes into a tag. A tag
    /// that is empty *once trimmed* keeps its own older, more specific refusal
    /// (`test_anEmptyLanguageIsRefusedAndMintsNothing`, above): that guard runs
    /// first and this one never sees a blank.
    func test_aTagThatIsNotALanguageTagIsRefusedAndMintsNothing() async throws {
        let (url, store) = try await loadedNovel(named: "InvalidLanguageTag")
        let before = try manifestState(of: url)

        for tag in ["../evil", "en/../../x", "a b", "e", "toolongprimary"] {
            do {
                _ = try await store.translatorRole(for: tag)
                XCTFail("expected a refusal for \(tag.debugDescription)")
            } catch let error as ProjectStoreError {
                XCTAssertEqual(error, .languageTagInvalid(tag),
                               "the refusal must name the tag as it arrived")
            }
        }

        XCTAssertTrue(store.manifest.productionRoles.isEmpty,
                      "a refused tag must mint nobody")
        XCTAssertEqual(try manifestState(of: url), before,
                       "a refusal must leave nothing behind")
    }

    /// **A role already stored under a never-valid tag is still returned — and
    /// therefore still RENAMEABLE** (issue #43, whole-branch review). The gate
    /// runs after the find, matching `createStatement`'s policy.
    ///
    /// The project this protects is the one that needs it most: a manifest
    /// hand-edited, or written by a build without the guard, carrying a tag no
    /// lowercasing rescues. The desk's Rename reaches this verb
    /// (`DepartmentPaneHost` → `nameTranslator` → `translatorRole`), so gating
    /// before the find would refuse to hand the row back and leave the writer
    /// no way to repair it from inside the app — a validation that turns a
    /// recoverable state into a permanent one.
    func test_aStoredRoleUnderAnInvalidTagIsStillFoundSoItCanBeRenamed() async throws {
        let (_, store) = try await loadedNovel(named: "LegacyBadTag")
        let legacy = ProductionRole(
            id: "role-legacy", role: .translator(language: "a b"), name: "Ana")
        store.manifest.productionRoles = [legacy]

        let found = try await store.translatorRole(for: "a b")

        XCTAssertEqual(found.id, legacy.id, "the stored row must come back, not a refusal")
        XCTAssertEqual(store.manifest.productionRoles.count, 1, "and nothing new is minted")

        // …and the writer can now actually repair it.
        try await store.renameProductionRole(id: found.id, to: "Beatriz")
        XCTAssertEqual(store.manifest.productionRoles.first?.name, "Beatriz")
    }

    /// The control for the test above: the SAME never-valid tag with nothing
    /// stored under it still throws. The find is what rescues a legacy row —
    /// the gate is otherwise exactly as strict as it was.
    func test_anInvalidTagWithNoStoredRoleStillThrows() async throws {
        let (_, store) = try await loadedNovel(named: "NoLegacyRow")

        do {
            _ = try await store.translatorRole(for: "a b")
            XCTFail("expected a refusal with nothing stored")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .languageTagInvalid("a b"))
        }
        XCTAssertTrue(store.manifest.productionRoles.isEmpty)
    }

    /// The control: a well-formed tag still mints, so the gate above is refusing
    /// its offenders rather than everything.
    func test_aWellFormedTagStillMints() async throws {
        let (_, store) = try await loadedNovel(named: "ValidTagStillMints")

        let role = try await store.translatorRole(for: "fr")
        XCTAssertEqual(role.role, ProductionRole.Role.translator(language: "fr"))
        XCTAssertEqual(role.name, "Baudelaire")
        XCTAssertEqual(store.manifest.productionRoles.count, 1)
    }

    // MARK: - The designer is already there

    /// **The disable-experiment target.** `designerRole()` is a READ: it answers
    /// with the preset and writes nothing back (`effectiveReviewPasses`'
    /// posture, tripwire 11 — no migrations). Make it persist the preset and
    /// this goes red.
    func test_theDesignerAnswersWithoutTouchingTheManifest() async throws {
        let (url, store) = try await loadedNovel(named: "DesignerRead")
        let before = try manifestState(of: url)

        let designer = store.designerRole()
        XCTAssertEqual(designer.id, ProductionRole.designerPresetID)
        XCTAssertEqual(designer.role, ProductionRole.Role.designer)
        XCTAssertEqual(designer.effectiveName, "Tschichold")
        XCTAssertNotNil(designer.effectiveBrief)
        XCTAssertTrue(store.manifest.productionRoles.isEmpty,
                      "the preset is merged for reading, never stored")

        // Give a fire-and-forget save Task time to land, so a read that
        // secretly writes is caught rather than merely outrun.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(try manifestState(of: url), before,
                       "reading the designer must cost nothing on disk")
    }

    func test_theStoredDesignerWinsOverThePreset() async throws {
        let (_, store) = try await loadedNovel(named: "StoredDesigner")

        try await store.renameProductionRole(
            id: ProductionRole.designerPresetID, to: "Bringhurst")

        let designer = store.designerRole()
        XCTAssertEqual(designer.id, ProductionRole.designerPresetID,
                       "a rename changes the name, never the identity")
        XCTAssertEqual(designer.effectiveName, "Bringhurst")
        XCTAssertEqual(storedDesigner(store)?.name, "Bringhurst")
        XCTAssertEqual(store.manifest.productionRoles.count, 1,
                       "renaming the designer materializes exactly one row")
    }

    /// The preset's DOCTRINE is not frozen into the project by a rename. Only
    /// the name the writer typed is stored; `effectiveBrief` keeps resolving.
    func test_renamingTheDesignerDoesNotFreezeTheirBrief() async throws {
        let (_, store) = try await loadedNovel(named: "DesignerBrief")

        try await store.renameProductionRole(
            id: ProductionRole.designerPresetID, to: "Bringhurst")

        XCTAssertNil(storedDesigner(store)?.brief,
                     "the preset brief must not be copied onto disk")
        XCTAssertEqual(store.designerRole().effectiveBrief,
                       ProductionRole.presetDesigner.effectiveBrief)
    }

    // MARK: - The writer's rename

    func test_aRenameRoundTripsThroughDisk() async throws {
        let (url, store) = try await loadedNovel(named: "RenameRoundTrip")
        let role = try await store.translatorRole(for: "es")

        try await store.renameProductionRole(id: role.id, to: "Borges")
        XCTAssertEqual(store.manifest.productionRoles.first?.name, "Borges")

        let reloaded = try await ProjectStore.load(from: url)
        await reloaded.wordCountPopulationTask?.value
        XCTAssertEqual(reloaded.manifest.productionRoles.first?.id, role.id)
        XCTAssertEqual(reloaded.manifest.productionRoles.first?.effectiveName, "Borges")
    }

    func test_aRenameIsTrimmed() async throws {
        let (_, store) = try await loadedNovel(named: "RenameTrimmed")
        let role = try await store.translatorRole(for: "fr")

        try await store.renameProductionRole(id: role.id, to: "  Baudelaire \n")
        XCTAssertEqual(store.manifest.productionRoles.first?.name, "Baudelaire")
    }

    func test_anEmptyRenameIsRefusedAndChangesNothing() async throws {
        let (url, store) = try await loadedNovel(named: "EmptyRename")
        let role = try await store.translatorRole(for: "es")
        let before = try manifestState(of: url)

        for attempt in ["", "   ", "\t\n"] {
            do {
                try await store.renameProductionRole(id: role.id, to: attempt)
                XCTFail("expected a refusal for \(attempt.debugDescription)")
            } catch let error as ProjectStoreError {
                XCTAssertEqual(error, .productionRoleNameEmpty)
            }
        }

        XCTAssertEqual(store.manifest.productionRoles.first?.name, "Cortázar",
                       "a refused rename must leave the standing name alone")
        XCTAssertEqual(try manifestState(of: url), before)
    }

    func test_renamingARoleTheProjectDoesNotHaveThrows() async throws {
        let (_, store) = try await loadedNovel(named: "UnknownRole")

        do {
            try await store.renameProductionRole(id: "role-nobody", to: "Nabokov")
            XCTFail("expected a refusal for an unknown id")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .productionRoleMissing(id: "role-nobody"))
        }
        XCTAssertTrue(store.manifest.productionRoles.isEmpty)
    }

    // MARK: - A refused write leaves nothing standing

    /// **The rollback in `commitProductionRoles`, held by its consequence.**
    ///
    /// This is where the seam departs from `setReviewPasses`, which mutates and
    /// lets a failed save propagate. That verb writes the whole list from an
    /// explicit Save; a throw reaches an alert and the writer presses it again.
    /// `translatorRole(for:)` is find-or-create, so nobody presses anything a
    /// second time — the next call FINDS the in-memory role and returns it. Drop
    /// the rollback and the second ask below hands back a translator whose id
    /// signs annotations and which no reload will ever produce.
    ///
    /// The save is made to fail for real — the project directory is made
    /// unwritable, so `saveManifest`'s tmp file cannot be created — rather than
    /// through an injected seam: this store has none, and the failure under test
    /// is the disk's own.
    func test_aFailedSaveLeavesNoPhantomTranslatorBehind() async throws {
        let (url, store) = try await loadedNovel(named: "FailedSave")
        let fm = FileManager.default
        let original = try XCTUnwrap(
            fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        let modifiedBefore = store.manifest.modified

        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: url.path) }

        do {
            _ = try await store.translatorRole(for: "es")
            XCTFail("expected the manifest write to be refused")
        } catch let error as ProjectStoreError {
            guard case .manifestUnwritable = error else {
                return XCTFail("expected .manifestUnwritable, got \(error)")
            }
        }

        XCTAssertTrue(store.manifest.productionRoles.isEmpty,
                      "a role that never reached disk must not stand in memory")
        // Compared as intervals, not as `Date`s: two `Date`s differing only
        // sub-second print identically, so a failure here would read as
        // "X is not equal to X".
        XCTAssertEqual(store.manifest.modified.timeIntervalSince1970,
                       modifiedBefore.timeIntervalSince1970,
                       "the stamp goes back with the row it was made for")

        // The consequence: with the disk writable again the next ask MINTS,
        // rather than finding the phantom and returning it with no save at all.
        try fm.setAttributes([.posixPermissions: original], ofItemAtPath: url.path)
        let minted = try await store.translatorRole(for: "es")

        let reloaded = try await ProjectStore.load(from: url)
        await reloaded.wordCountPopulationTask?.value
        XCTAssertEqual(reloaded.manifest.productionRoles.map(\.id), [minted.id],
                       "the role the caller was handed must be the one on disk")
    }

    /// The rename arm of the same rollback: a refused write leaves the standing
    /// name alone, so the surface and the disk cannot disagree about who this is.
    func test_aFailedSaveLeavesTheStandingNameAlone() async throws {
        let (url, store) = try await loadedNovel(named: "FailedRename")
        let role = try await store.translatorRole(for: "es")
        let fm = FileManager.default
        let original = try XCTUnwrap(
            fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)

        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: url.path) }

        do {
            try await store.renameProductionRole(id: role.id, to: "Borges")
            XCTFail("expected the manifest write to be refused")
        } catch let error as ProjectStoreError {
            guard case .manifestUnwritable = error else {
                return XCTFail("expected .manifestUnwritable, got \(error)")
            }
        }

        XCTAssertEqual(store.manifest.productionRoles.first?.name, "Cortázar",
                       "a refused rename must not show a name the disk does not have")
    }

    /// The preset designer's id is reachable by rename exactly ONCE as a
    /// materialization: once a row exists, the ordinary stored path takes it.
    func test_renamingTheDesignerTwiceKeepsOneRow() async throws {
        let (_, store) = try await loadedNovel(named: "DesignerTwice")

        try await store.renameProductionRole(
            id: ProductionRole.designerPresetID, to: "Bringhurst")
        try await store.renameProductionRole(
            id: ProductionRole.designerPresetID, to: "Morison")

        XCTAssertEqual(store.manifest.productionRoles.count, 1)
        XCTAssertEqual(store.designerRole().effectiveName, "Morison")
    }

    // MARK: - Reader and collator (translation pipeline P1)

    func test_mintingAReaderTwiceReturnsTheSameRole() async throws {
        let (_, store) = try await loadedNovel(named: "Reader")
        let first = try await store.readerRole(for: "es")
        let second = try await store.readerRole(for: "ES")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.role, .reader(language: "es"))
        XCTAssertEqual(first.effectiveName, "Ocampo")
        XCTAssertEqual(store.manifest.productionRoles.filter { $0.role == .reader(language: "es") }.count, 1)
    }

    func test_aReaderAndACollatorAreDistinctPeopleForOneLanguage() async throws {
        let (_, store) = try await loadedNovel(named: "Cast")
        let translator = try await store.translatorRole(for: "fr")
        let reader = try await store.readerRole(for: "fr")
        let collator = try await store.collatorRole(for: "fr")
        XCTAssertEqual(Set([translator.id, reader.id, collator.id]).count, 3)
        XCTAssertEqual([translator, reader, collator].map(\.effectiveName), ["Baudelaire", "Colette", "Yourcenar"])
    }

    func test_anInvalidTagRefusesToMintAReaderOrACollator() async throws {
        let (url, store) = try await loadedNovel(named: "BadTag")
        let before = try manifestState(of: url)
        await XCTAssertThrowsErrorAsync(try await store.readerRole(for: "not a tag"))
        await XCTAssertThrowsErrorAsync(try await store.collatorRole(for: "not a tag"))
        XCTAssertEqual(try manifestState(of: url), before, "a refused mint writes nothing")
    }

    func test_theReadOnlyNamesNeverMint() async throws {
        let (url, store) = try await loadedNovel(named: "ReadOnly")
        let before = try manifestState(of: url)
        XCTAssertEqual(EditionStatus.readerName(for: "es", in: store.manifest), "Ocampo")
        XCTAssertEqual(EditionStatus.collatorName(for: "ja", in: store.manifest), "Futabatei")
        XCTAssertNil(EditionStatus.readerName(for: "is", in: store.manifest))
        XCTAssertEqual(try manifestState(of: url), before)
    }
}
