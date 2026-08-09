import Foundation
import Observation

/// The list of posts, and what can be done to it.
///
/// Kept apart from the view so the paging and the merge rules can be read
/// without wading through layout, and so a saved post can be folded back into
/// the list without a round trip to the server for the whole page.
@MainActor
@Observable
final class LibraryModel {
    private(set) var all: [Post] = []
    private(set) var isLoading = false
    private(set) var cursor: String?
    private(set) var hasLoadedOnce = false

    var failure: String?

    /// Whether there is another page. Absent cursor means the sequence ended,
    /// which is how the server signals the last page.
    var hasMore: Bool { hasLoadedOnce && cursor != nil }

    var posts: [Post] { all }

    func posts(in state: Post.State) -> [Post] {
        let now = Date()
        return all.filter { $0.state(now: now) == state }
    }

    func loadIfNeeded(using client: BroadsideClient?) async {
        guard !hasLoadedOnce else { return }
        await reload(using: client)
    }

    func reload(using client: BroadsideClient?) async {
        guard let client else {
            failure = APIError.notSignedIn.errorDescription
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await client.posts(limit: 30)
            all = page.posts
            cursor = page.next
            hasLoadedOnce = true
        } catch {
            failure = describe(error)
        }
    }

    func loadNextPage(using client: BroadsideClient?) async {
        guard let client, let cursor, !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await client.posts(after: cursor, limit: 30)

            // Merging by slug rather than appending. A post published between
            // the two requests shifts the window, and appending blindly is what
            // puts the same post in the list twice.
            var seen = Set(all.map(\.slug))
            for post in page.posts where !seen.contains(post.slug) {
                all.append(post)
                seen.insert(post.slug)
            }
            self.cursor = page.next
        } catch {
            // A failed page is not worth an alert over: the list still holds
            // everything already fetched, and the next pull to refresh retries.
            self.cursor = nil
        }
    }

    /// The post with its body, fetched if the copy in the list is only a
    /// summary.
    func fullPost(for post: Post, using client: BroadsideClient?) async -> Post? {
        guard let client else {
            failure = APIError.notSignedIn.errorDescription
            return nil
        }

        do {
            return try await client.post(slug: post.slug)
        } catch {
            failure = describe(error)
            return nil
        }
    }

    /// Folds a post the editor just saved back into the list.
    func absorb(_ post: Post) {
        if let index = all.firstIndex(where: { $0.slug == post.slug }) {
            all[index] = post
        } else {
            all.insert(post, at: 0)
        }
    }

    func delete(_ post: Post, using client: BroadsideClient?) async {
        guard let client else {
            failure = APIError.notSignedIn.errorDescription
            return
        }

        do {
            try await client.delete(slug: post.slug)
            all.removeAll { $0.slug == post.slug }
        } catch {
            failure = describe(error)
        }
    }

    private func describe(_ error: any Error) -> String {
        guard let api = error as? APIError else { return error.localizedDescription }
        if let suggestion = api.recoverySuggestion {
            return (api.errorDescription ?? "") + "\n\n" + suggestion
        }
        return api.errorDescription ?? error.localizedDescription
    }
}
