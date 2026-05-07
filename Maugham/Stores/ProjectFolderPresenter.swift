import Foundation
import AppKit

/// Receives NSFilePresenter callbacks from NSFileCoordinator and routes them
/// to a `ProjectFolderPresenterDelegate`. The delegate is a weak ref to the
/// owning DocumentStore — we don't want the presenter to retain the store.
@MainActor
public protocol ProjectFolderPresenterDelegate: AnyObject {
    func presenterDidChangeSubitem(at url: URL)
    func presenterDidObserveDirectoryChange()
}

public final class ProjectFolderPresenter: NSObject, NSFilePresenter {

    private let projectURL: URL
    private weak var delegate: ProjectFolderPresenterDelegate?
    private let queue: OperationQueue

    public init(
        projectURL: URL,
        delegate: ProjectFolderPresenterDelegate
    ) {
        self.projectURL = projectURL
        self.delegate = delegate
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        q.name = "com.maugham.ProjectFolderPresenter"
        self.queue = q
    }

    // MARK: - NSFilePresenter

    public var presentedItemURL: URL? { projectURL }
    public var presentedItemOperationQueue: OperationQueue { queue }

    public func presentedItemDidChange() {
        let d = delegate
        Task { @MainActor in d?.presenterDidObserveDirectoryChange() }
    }

    public func presentedSubitemDidChange(at url: URL) {
        let d = delegate
        Task { @MainActor in d?.presenterDidChangeSubitem(at: url) }
    }

    public func presentedSubitemDidAppear(at url: URL) {
        let d = delegate
        Task { @MainActor in d?.presenterDidChangeSubitem(at: url) }
    }
}
