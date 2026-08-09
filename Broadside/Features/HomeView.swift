import SwiftUI

/// The signed-in app: read the blog, or work on it.
///
/// Two tabs rather than four. The admin on the web has Content, Media, Site
/// Settings and API because it is where a site is configured; a phone is where
/// posts are written, and the rest of that belongs on a desktop where it is
/// already good.
struct HomeView: View {
    var body: some View {
        TabView {
            Tab("Timeline", systemImage: "book") {
                TimelineView()
            }

            Tab("Posts", systemImage: "square.and.pencil") {
                LibraryView()
            }
        }
    }
}
