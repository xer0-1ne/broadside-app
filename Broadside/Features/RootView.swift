import SwiftUI

/// The whole app is one of two things: connected to a server, or not yet.
struct RootView: View {
    @Environment(AccountStore.self) private var account

    var body: some View {
        if account.isSignedIn {
            HomeView()
        } else {
            ConnectView()
        }
    }
}
