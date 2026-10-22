import Foundation
import MaughamCore

/// One of the four project switches (report plan 4, R-4-7), named so a caller
/// sets ONE switch and never read-modify-writes the whole set: two toggles
/// pressed in one turn would otherwise each save the set they read before the
/// other landed (`setPassState`'s reason).
public enum ProjectSwitchKey: CaseIterable, Hashable, Sendable {
    case numberSections
    case listOfFigures
    case listOfTables
    case webAccess

    fileprivate var keyPath: WritableKeyPath<ProjectSwitches, Bool?> {
        switch self {
        case .numberSections: return \.numberSections
        case .listOfFigures: return \.listOfFigures
        case .listOfTables: return \.listOfTables
        case .webAccess: return \.webAccess
        }
    }
}

extension ProjectSwitches {
    /// The stored value of one switch; nil is "the profile's default".
    public subscript(key: ProjectSwitchKey) -> Bool? {
        get { self[keyPath: key.keyPath] }
        set { self[keyPath: key.keyPath] = newValue }
    }
}

extension ProjectManifest {
    /// One switch's effective value: Core's `effectiveSwitches` (stored, else
    /// the profile's default, else false), asked by key.
    public func effectiveSwitch(_ key: ProjectSwitchKey) -> Bool {
        let effective = effectiveSwitches
        switch key {
        case .numberSections: return effective.numberSections
        case .listOfFigures: return effective.listOfFigures
        case .listOfTables: return effective.listOfTables
        case .webAccess: return effective.webAccess
        }
    }
}

// MARK: - The one door (R-4-7)

extension ProjectStore {

    /// **Set the project's profile, or clear it** — Project Settings' Report
    /// toggle. Writes through `saveManifest`, the manifest door, so
    /// `encodeForDisk`'s content floor raises the book to schema 10.
    ///
    /// - A profile the project's kind cannot carry (a screenplay, a
    ///   collection, a profile this build does not know) is refused with the
    ///   factory's own `ProjectFactoryError.profileNotOffered`, before anything
    ///   is written: one rule for creating a Report and for turning one on.
    /// - Clearing the profile KEEPS the stored switches: they are the writer's
    ///   choices, and turning the Report back on finds them where they were.
    /// - A profile a newer Maugham wrote (`.unknown`) is never overwritten:
    ///   any change is refused with `ProjectStoreError.profileFromNewerBuild`.
    /// - Setting what is already there writes nothing, so a book that never
    ///   changes it is never raised (review focus 3).
    ///
    /// Turning the profile on does not re-install the publish starter: the
    /// starter is chosen when the project is created.
    ///
    /// Turning a Report's profile OFF writes the project's title into the
    /// publish config once, when that config's title is still the starter's
    /// "Untitled" (M6): a Report is titled by its project only while it is a
    /// Report (`PublishContext.reportTitled`), so without this its next PDF
    /// would be "Untitled". Gated on the profile being turned off, never on
    /// the title alone, so a book that never had the profile keeps its bytes —
    /// an old book whose config says "Untitled" still prints "Untitled".
    public func setProfile(_ profile: ProjectProfile?) async throws {
        guard manifest.profile != profile else { return }
        if case .unknown(let raw) = manifest.profile {
            throw ProjectStoreError.profileFromNewerBuild(raw)
        }
        try ProjectFactory.refuseUnofferedProfile(profile, on: manifest.type)
        if case .report? = manifest.profile, profile != .report {
            try await keepTheReportsTitle()
        }
        manifest.profile = profile
        manifest.modified = Date()
        try await saveManifest()
    }

    /// **Set one switch, or hand it back to the profile's default** (nil).
    /// An emptied set is stored as absent, never `{}`. Setting what is already
    /// stored writes nothing.
    ///
    /// Not refused on any kind, a screenplay included: only the profile has a
    /// kind rule (`refuseUnofferedProfile`). Project Settings hides the whole
    /// section for a screenplay, so no surface offers the switches there.
    public func setSwitch(_ key: ProjectSwitchKey, _ value: Bool?) async throws {
        var switches = manifest.switches ?? ProjectSwitches()
        guard switches[key] != value else { return }
        switches[key] = value
        manifest.switches = switches == ProjectSwitches() ? nil : switches
        manifest.modified = Date()
        try await saveManifest()
    }

    /// M6: the Report's title fallback, made the config's own before the
    /// profile that applied it goes. Writes nothing when there is no config
    /// or the writer already named the book.
    private func keepTheReportsTitle() async throws {
        let configStore = PublishConfigStore(projectURL: url)
        guard let config = try await configStore.load() else { return }
        let titled = PublishContext.titledByProject(config, projectTitle: manifest.title)
        guard titled.metadata.title != config.metadata.title else { return }
        try await configStore.save(titled)
    }
}
