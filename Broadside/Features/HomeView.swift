import SwiftUI

/// The signed-in app: read the blog, or work on it.
///
/// Two tabs rather than four. The admin on the web has Content, Media, Site
/// Settings and API because it is where a site is configured; a phone is where
/// posts are written, and the rest of that belongs on a desktop where it is
/// already good.
/// Built with `.tabItem` rather than the `Tab` type introduced in iOS 18,
/// because the deployment target is 17.6 and `Tab` would not compile against
/// it. The two produce the same tab bar here; `Tab` only starts to earn its
/// keep with programmatic selection, a sidebar adaptation, or a search tab,
/// none of which this uses. Worth raising the floor to 18 and switching if any
/// of those ever arrive.
struct HomeView: View {
    var body: some View {
        TabView {
            TimelineView()
                .tabItem {
                    Label("Timeline", systemImage: "book")
                }

            LibraryView()
                .tabItem {
                    Label("Posts", systemImage: "square.and.pencil")
                }
        }
    }
}
