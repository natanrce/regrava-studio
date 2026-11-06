import Combine
import Darwin
import Foundation
import RegravaCore

/// One "On your Mac" search: every Spotlight-indexed project folder whose name contains the
/// term, added to `results` as Spotlight finds them. It does not keep watching once Spotlight
/// has gathered its matches.
@MainActor
final class MacProjectSearchSession: ObservableObject {
    enum Status { case searching, done }

    let term: String
    @Published private(set) var status: Status = .searching
    @Published private(set) var results: [RecentProject] = []
    @Published private(set) var errorMessage: String?

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var sentCount = 0

    init(term: String) {
        self.term = term
        start()
    }

    /// Stops the query; nothing is added after this.
    func cancel() {
        guard query != nil else { return }
        stopQuery()
    }

    private func start() {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, MacProjectSearch.namePattern(term: term))
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        self.query = query
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering] {
            // Delivered on the main thread, which runs the query.
            observers.append(center.addObserver(forName: name, object: query, queue: nil) { [weak self] note in
                let finished = note.name == .NSMetadataQueryDidFinishGathering
                MainActor.assumeIsolated { self?.collect(finished: finished) }
            })
        }
        if !query.start() {
            stopQuery()
            errorMessage = "Spotlight could not start the search (is indexing turned off?)"
            status = .done
        }
    }

    /// Reads the matches Spotlight added since the last call, up to `MacProjectSearch.limit`.
    private func collect(finished: Bool) {
        guard let query else { return }
        query.disableUpdates()
        while sentCount < query.resultCount, sentCount < MacProjectSearch.limit {
            let item = query.result(at: sentCount) as? NSMetadataItem
            sentCount += 1
            if let path = item?.value(forAttribute: NSMetadataItemPathKey) as? String { add(path: path) }
        }
        query.enableUpdates()
        if finished || sentCount >= MacProjectSearch.limit {
            stopQuery()
            status = .done
        }
    }

    /// Folders only; a match that is a plain file, or that is gone, is left out.
    private func add(path: String) {
        var info = stat()
        guard fstatat(AT_FDCWD, path, &info, 0) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        let url = URL(fileURLWithPath: path)
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        let preview = ProjectPreview.url(bundle: url)
        let previewValues = try? preview.resourceValues(forKeys: [.contentModificationDateKey])
        results.append(RecentProject(
            url: url,
            name: MacProjectSearch.projectName(path: path),
            lastOpened: nil,
            modified: modified,
            previewURL: previewValues != nil ? preview : nil,
            previewModified: previewValues?.contentModificationDate
        ))
    }

    private func stopQuery() {
        query?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        query = nil
    }

    /// Lists Documents, Desktop and Downloads in turn, so macOS asks for access to each
    /// before their projects are opened.
    nonisolated static func requestFolderAccess() {
        Task.detached(priority: .userInitiated) {
            for directory in [FileManager.SearchPathDirectory.documentDirectory, .desktopDirectory, .downloadsDirectory] {
                guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { continue }
                _ = try? FileManager.default.contentsOfDirectory(atPath: url.path)
            }
        }
    }
}
