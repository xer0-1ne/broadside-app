import Foundation
import Observation

@MainActor
@Observable
final class SettingsModel {
    var settings = SiteSettings()

    /// What the server last confirmed it had stored. The Save button compares
    /// against this rather than against a dirty flag, so undoing an edit by
    /// hand disables it again.
    private var saved = SiteSettings()

    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var hasLoaded = false

    var failure: String?

    var hasChanges: Bool { settings != saved }

    func loadIfNeeded(using client: BroadsideClient?) async {
        guard !hasLoaded else { return }
        await load(using: client)
    }

    func load(using client: BroadsideClient?) async {
        guard let client else {
            failure = APIError.notSignedIn.errorDescription
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await client.settings()
            settings = fetched
            saved = fetched
            hasLoaded = true
            failure = nil
        } catch {
            failure = describe(error)
        }
    }

    func save(using client: BroadsideClient?) async {
        guard let client else {
            failure = APIError.notSignedIn.errorDescription
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            // Adopt what came back rather than what was sent. The upload limit
            // and the password length are clamped on the way to disk, so the
            // response is the only account of what the site is actually using,
            // and keeping the sent copy would show a number that is not real.
            let stored = try await client.updateSettings(settings)
            settings = stored
            saved = stored
            failure = nil
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
