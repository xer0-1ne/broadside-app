import SwiftUI

/// Every post, grouped by what it is doing.
///
/// Drafts first, then scheduled, then published, which is the order of how
/// likely somebody is to want to touch them. The web admin's Content tab uses
/// the same grouping, so moving between the two does not mean relearning where
/// anything is.
struct LibraryView: View {
    @Environment(AccountStore.self) private var account

    @State private var model = LibraryModel()
    @State private var composing: Post?
    @State private var pendingDeletion: Post?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if model.posts.isEmpty, model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.posts.isEmpty {
                    ContentUnavailableView(
                        "Nothing written yet",
                        systemImage: "square.and.pencil",
                        description: Text("Anything you write here lands in your posts folder as a markdown file.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Posts")
            /*
              Inline rather than large. The button below is pinned under the
              navigation bar, and a large title lives in the scroll content, so
              the two occupy the same place and the title ends up behind the
              button at the top of the list.
            */
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) { newPostButton }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Site settings", systemImage: "gearshape") {
                            showingSettings = true
                        }

                        Section {
                            if let host = account.serverURL?.host() {
                                Text(host)
                            }
                            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                account.signOut()
                            }
                        }
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .refreshable { await model.reload(using: account.client) }
            .task { await model.loadIfNeeded(using: account.client) }
            .sheet(item: $composing) { post in
                EditorView(post: post) { saved in
                    model.absorb(saved)
                }
            }
            .alert(item: $pendingDeletion) { post in
                Alert(
                    title: Text("Delete “\(post.title)”?"),
                    message: Text("The file is removed from your posts folder. This cannot be undone from the app."),
                    primaryButton: .destructive(Text("Delete")) {
                        Task { await model.delete(post, using: account.client) }
                    },
                    secondaryButton: .cancel()
                )
            }
            .alert(
                "That did not work",
                isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
                presenting: model.failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure)
            }
        }
    }

    /// Writing is what somebody opened this app to do, so it is a labelled
    /// button across the top rather than an icon competing for attention with
    /// the account menu in the corner. It sits in a safe area inset so the list
    /// scrolls underneath it and it is still reachable at the bottom of a long
    /// list of posts.
    private var newPostButton: some View {
        Button {
            composing = Post(published: Date(), draft: true)
        } label: {
            Label("New post", systemImage: "square.and.pencil")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var list: some View {
        List {
            ForEach(Post.State.allCases, id: \.self) { state in
                let posts = model.posts(in: state)
                if !posts.isEmpty {
                    Section(state.label) {
                        ForEach(posts) { post in
                            Button {
                                open(post)
                            } label: {
                                PostRow(post: post)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDeletion = post
                                }
                            }
                        }
                    }
                }
            }

            if model.hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .task { await model.loadNextPage(using: account.client) }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func open(_ post: Post) {
        Task {
            // The list endpoint leaves bodies out, so the post in hand is a
            // summary. Opening the editor on it would show an empty post and
            // then save that emptiness over the real one.
            if let full = await model.fullPost(for: post, using: account.client) {
                composing = full
            }
        }
    }
}

private struct PostRow: View {
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(post.title.isEmpty ? "Untitled" : post.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(post.published, format: .dateTime.day().month(.abbreviated).year())

                if !post.tags.isEmpty {
                    Text("·")
                    Text(post.tags.joined(separator: ", "))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

extension Post.State: CaseIterable {
    public static var allCases: [Post.State] { [.draft, .scheduled, .published] }
}
