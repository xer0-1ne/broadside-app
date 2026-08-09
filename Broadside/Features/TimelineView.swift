import SwiftUI

/// The blog as a reader sees it.
///
/// Posts in full rather than as headlines with a tap to open, which is what the
/// site itself does. Broadside's whole premise is that there is nothing to
/// click through before you are reading, and a phone app that turned the
/// timeline into a table of contents would be arguing with the product.
struct TimelineView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.openURL) private var openURL

    @State private var posts: [Post] = []
    @State private var cursor: String?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if posts.isEmpty, isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if posts.isEmpty, let failure {
                    ContentUnavailableView {
                        Label("Cannot reach your site", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try again") { Task { await reload() } }
                    }
                } else if posts.isEmpty {
                    ContentUnavailableView(
                        "Nothing published yet",
                        systemImage: "book",
                        description: Text("Posts appear here once they are live.")
                    )
                } else {
                    timeline
                }
            }
            .navigationTitle("Timeline")
            .refreshable { await reload() }
            .task {
                guard !hasLoaded else { return }
                await reload()
            }
        }
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(posts) { post in
                    PostSummaryView(post: post) {
                        if let url = account.client?.absoluteURL(for: post.url) {
                            openURL(url)
                        }
                    }
                    Divider()
                }

                if cursor != nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await loadNextPage() }
                }
            }
            .padding()
        }
    }

    private func reload() async {
        guard let client = account.client else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            // Drafts excluded, because this is the reading view. They are one
            // tab away in Posts, where they belong.
            let page = try await client.posts(limit: 15, includeDrafts: false)
            posts = page.posts
            cursor = page.next
            failure = nil
            hasLoaded = true
        } catch {
            failure = (error as? APIError)?.errorDescription ?? error.localizedDescription
            hasLoaded = true
        }
    }

    private func loadNextPage() async {
        guard let client = account.client, let cursor, !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await client.posts(after: cursor, limit: 15, includeDrafts: false)
            var seen = Set(posts.map(\.slug))
            for post in page.posts where !seen.contains(post.slug) {
                posts.append(post)
                seen.insert(post.slug)
            }
            self.cursor = page.next
        } catch {
            // Stop paging rather than showing an error over content that is
            // already on screen and readable.
            self.cursor = nil
        }
    }
}

private struct PostSummaryView: View {
    let post: Post
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(post.title)
                .font(.title2.weight(.semibold))

            Text(post.published, format: .dateTime.day().month(.wide).year())
                .font(.caption)
                .foregroundStyle(.secondary)

            if !post.summary.isEmpty {
                Text(post.summary)
                    .font(.body)
                    .foregroundStyle(.primary)
            }

            if !post.tags.isEmpty {
                Text(post.tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button("Read on your site", systemImage: "arrow.up.right.square", action: onOpen)
                .font(.callout)
                .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
