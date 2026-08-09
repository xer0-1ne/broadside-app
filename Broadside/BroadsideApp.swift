import SwiftUI

@main
struct BroadsideApp: App {
    /// The one piece of state the whole app hangs off: which server this copy
    /// is signed in to. Everything else is fetched, and can be thrown away and
    /// fetched again.
    @State private var account = AccountStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(account)
        }
        /*
          Without this the system has nowhere to deliver the news that a
          background upload finished while the app was not running. It relaunches
          the app, waits here for the session's delegate callbacks to be
          processed, and then lets it suspend again. Touching MediaUploader.shared
          is what recreates the session under the identifier the system is
          holding events for.
        */
        .backgroundTask(.urlSession(MediaUploader.sessionIdentifier)) {
            await MainActor.run { _ = MediaUploader.shared }
        }
    }
}
