import Foundation

/// Searches with Spotlight: a folder and everything under it, or files with a tag.
@MainActor
final class SpotlightSearch {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    /// Finds items whose name contains `text` anywhere under `folder`.
    func names(containing text: String, under folder: URL, done: @escaping @MainActor ([URL]) -> Void) {
        run(NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text), scopes: [folder], done: done)
    }

    /// Finds items with a Finder tag, anywhere you can see.
    func tagged(_ tag: String, done: @escaping @MainActor ([URL]) -> Void) {
        run(NSPredicate(format: "%K == %@", "kMDItemUserTags", tag),
            scopes: [NSMetadataQueryUserHomeScope, NSMetadataQueryLocalComputerScope], done: done)
    }

    func cancel() {
        query?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        query = nil
        observer = nil
    }

    private func run(_ predicate: NSPredicate, scopes: [Any], done: @escaping @MainActor ([URL]) -> Void) {
        cancel()
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scopes
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let query = self.query else { return }
                query.disableUpdates()
                let urls = (0..<min(query.resultCount, 500)).compactMap {
                    (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
                }.map { URL(fileURLWithPath: $0) }
                self.cancel()
                done(urls)
            }
        }
        self.query = query
        query.start()
    }
}
