import SwiftUI

/// Pointing the app at a server.
///
/// There is no account to create here and no password to type. Broadside issues
/// tokens from the API tab of a site somebody already administers, and this
/// screen's whole job is to take an address and one of those tokens and check
/// that they work together before keeping them.
struct ConnectView: View {
    @Environment(AccountStore.self) private var account

    @State private var address = ""
    @State private var token = ""
    @State private var isChecking = false
    @State private var failure: String?

    @FocusState private var focus: Field?

    private enum Field { case address, token }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("blog.example.com", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .token }
                } header: {
                    Text("Your site")
                } footer: {
                    Text("The address you visit to read your own blog. A server on this network can be an address and port, like 192.168.1.50:5555.")
                }

                Section {
                    /*
                      Deliberately no .textContentType(.password). It is what
                      makes iOS offer to save this in Passwords afterwards, and
                      an API token is not a website password: there is no site
                      to fill it into, AutoFill has nothing useful to suggest,
                      and the prompt only teaches people to dismiss prompts.
                      SecureField still masks it.
                    */
                    SecureField("Paste your token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .token)
                        .submitLabel(.go)
                        .onSubmit { connect() }
                } header: {
                    Text("API token")
                } footer: {
                    Text("Sign in to your site, open Site Settings, then the API tab, and create a token. It is shown once.")
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Button(action: connect) {
                        if isChecking {
                            HStack {
                                ProgressView()
                                Text("Checking…")
                            }
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(isChecking || address.isEmpty || token.isEmpty)
                }
            }
            .navigationTitle("Broadside")
            .onAppear { focus = .address }
        }
    }

    private func connect() {
        guard !isChecking, !address.isEmpty, !token.isEmpty else { return }

        isChecking = true
        failure = nil

        Task {
            do {
                try await account.signIn(serverURL: address, token: token)
            } catch {
                // The token stays in the field on failure. Somebody who has
                // just pasted a forty-character secret should not have to go
                // and find it again because the address had a typo in it.
                failure = message(for: error)
            }
            isChecking = false
        }
    }

    private func message(for error: any Error) -> String {
        guard let api = error as? APIError else { return error.localizedDescription }
        if let suggestion = api.recoverySuggestion {
            return (api.errorDescription ?? "") + " " + suggestion
        }
        return api.errorDescription ?? "That did not work."
    }
}
