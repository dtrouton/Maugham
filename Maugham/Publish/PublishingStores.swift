import Foundation

/// Per-project singleton bundle for the publishing pipeline's stores.
/// Shared so a `compile` followed by `compile_status` can find the same
/// `CompileJobManager` (which is in-memory only — `CompileJob` state does
/// not survive an app relaunch).
///
/// The dictionary leaks across tests unless cleared between cases. Use
/// `_resetForTesting()` from `setUp`/`tearDown` in MCP tool tests.
@MainActor
public final class PublishingStores {

    public let projectURL: URL
    public let configStore: PublishConfigStore
    public let publicationStore: PublicationStore
    public let snapshotStore: PublicationSnapshotStore
    public let jobManager: CompileJobManager
    /// P2 (issue #25): the per-project mint gate. Shared for the same reason
    /// `jobManager` is — every compile of this project must contend on ONE
    /// gate, or two in-flight compiles of an edition never see each other.
    public let mintGate: PublishMintGate

    public init(projectURL: URL) {
        self.projectURL = projectURL
        self.configStore = PublishConfigStore(projectURL: projectURL)
        self.publicationStore = PublicationStore(projectURL: projectURL)
        self.snapshotStore = PublicationSnapshotStore(projectURL: projectURL)
        self.jobManager = CompileJobManager()
        self.mintGate = PublishMintGate()
    }

    private static var byProjectID: [String: PublishingStores] = [:]

    /// Returns the singleton for this project, creating on first access.
    public static func sharedFor(projectID: String, projectURL: URL) -> PublishingStores {
        if let existing = byProjectID[projectID] { return existing }
        let new = PublishingStores(projectURL: projectURL)
        byProjectID[projectID] = new
        return new
    }

    /// Test-only: drop the per-project cache so subsequent tests get a
    /// fresh CompileJobManager / stores. Without this, tests reuse state
    /// from prior runs by project URL — non-flaky on first run, flaky on
    /// rerun.
    public static func _resetForTesting() {
        byProjectID.removeAll()
    }
}
