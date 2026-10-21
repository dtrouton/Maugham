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
    /// - Setting what is already there writes nothing, so a book that never
    ///   changes it is never raised (review focus 3).
    ///
    /// Turning the profile on does not re-install the publish starter: the
    /// starter is chosen when the project is created.
    public func setProfile(_ profile: ProjectProfile?) async throws {
        try ProjectFactory.refuseUnofferedProfile(profile, on: manifest.type)
        guard manifest.profile != profile else { return }
        manifest.profile = profile
        manifest.modified = Date()
        try await saveManifest()
    }

    /// **Set one switch, or hand it back to the profile's default** (nil).
    /// An emptied set is stored as absent, never `{}`. Setting what is already
    /// stored writes nothing.
    public func setSwitch(_ key: ProjectSwitchKey, _ value: Bool?) async throws {
        var switches = manifest.switches ?? ProjectSwitches()
        guard switches[key] != value else { return }
        switches[key] = value
        manifest.switches = switches == ProjectSwitches() ? nil : switches
        manifest.modified = Date()
        try await saveManifest()
    }
}
