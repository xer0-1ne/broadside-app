import SwiftUI

/// The site's settings, as far as they make sense on a phone.
///
/// Not everything on the web Site Settings tab is here. Typefaces, uploaded
/// fonts, and custom social icons all involve picking from a list the server
/// builds out of files on disk, and doing that well on a phone is a bigger job
/// than it is worth for something changed twice in a site's life. The footer
/// says so rather than leaving somebody hunting for a control that is not here.
struct SettingsView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss

    @State private var model = SettingsModel()

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading, !model.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !model.hasLoaded, let failure = model.failure {
                    ContentUnavailableView {
                        Label("Cannot read your settings", systemImage: "gearshape.badge.xmark")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try again") { Task { await model.load(using: account.client) } }
                    }
                } else {
                    form
                }
            }
            .navigationTitle("Site settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await model.save(using: account.client) }
                        }
                        .disabled(!model.hasChanges)
                    }
                }
            }
            .task { await model.loadIfNeeded(using: account.client) }
            .alert(
                "That did not work",
                isPresented: Binding(get: { model.hasLoaded && model.failure != nil }, set: { if !$0 { model.failure = nil } }),
                presenting: model.failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure)
            }
        }
    }

    @ViewBuilder
    private var form: some View {
        @Bindable var model = model

        Form {
            Section("Site") {
                LabeledField("Title", text: $model.settings.title)
                LabeledField("Slogan", text: $model.settings.slogan)
                LabeledField("Your name", text: $model.settings.displayName)
            }

            Section {
                LabeledField("Address", text: $model.settings.baseURL, isURL: true)
            } header: {
                Text("Public address")
            } footer: {
                Text("Used to build absolute links in the feed and the sitemap. Leave it empty and Broadside works it out from the request.")
            }

            Section {
                LabeledField("Footer text", text: $model.settings.footerText)
            } header: {
                Text("Footer")
            }

            Section {
                Stepper(
                    "Posts per page: \(model.settings.postsPerPage)",
                    value: $model.settings.postsPerPage,
                    in: SiteSettings.Limits.postsPerPageRange
                )

                LabeledField("Date format", text: $model.settings.dateFormat, monospaced: true)
            } header: {
                Text("Reading")
            } footer: {
                Text("Date format uses M and m for the month, D and d for the day, Y and y for the year. The lower case form is the short one, so \"m d, Y\" gives \"Aug 9, 2026\". An unrecognised format is ignored rather than stored.")
            }

            Section {
                Stepper(
                    "Upload limit: \(model.settings.maxUploadMB) MB",
                    value: $model.settings.maxUploadMB,
                    in: SiteSettings.Limits.uploadFloorMB...SiteSettings.Limits.uploadCeilingMB,
                    step: uploadStep
                )

                Stepper(
                    "Shortest password: \(model.settings.minPasswordLength)",
                    value: $model.settings.minPasswordLength,
                    in: SiteSettings.Limits.passwordFloor...SiteSettings.Limits.passwordCeiling
                )
            } header: {
                Text("Limits")
            } footer: {
                Text("If a reverse proxy sits in front of Broadside, its own body size limit applies as well and this cannot raise it.")
            }

            Section {
                ColorRow("Background", hex: $model.settings.theme.background)
                ColorRow("Surface", hex: $model.settings.theme.surface)
                ColorRow("Text", hex: $model.settings.theme.text)
                ColorRow("Muted text", hex: $model.settings.theme.muted)
                ColorRow("Accent", hex: $model.settings.theme.accent)
                ColorRow("Borders", hex: $model.settings.theme.border)
            } header: {
                Text("Colours")
            } footer: {
                Text("Typefaces, uploaded fonts, and social links are on the Site Settings tab of your site, where the lists they choose from are built from files on the server.")
            }

            if !model.settings.social.isEmpty {
                Section("Social links") {
                    ForEach(model.settings.social) { link in
                        LabeledContent(link.platform.capitalized, value: link.url)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// Steps of one megabyte are unusable at the top of a four gigabyte range,
    /// and steps of a hundred are useless at the bottom.
    private var uploadStep: Int {
        model.settings.maxUploadMB >= 512 ? 128 : 16
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    var isURL = false
    var monospaced = false

    init(_ label: String, text: Binding<String>, isURL: Bool = false, monospaced: Bool = false) {
        self.label = label
        _text = text
        self.isURL = isURL
        self.monospaced = monospaced
    }

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(isURL || monospaced ? .never : .sentences)
                .autocorrectionDisabled(isURL || monospaced)
                .keyboardType(isURL ? .URL : .default)
                .fontDesign(monospaced ? .monospaced : nil)
        }
    }
}

/// A colour picker bound to the hex string the config file stores.
///
/// The config keeps colours as text because that is what a person editing
/// config.json by hand writes, and what the stylesheet route validates before
/// emitting. Converting in both directions here keeps that format intact rather
/// than rewriting every colour into whatever SwiftUI would produce.
private struct ColorRow: View {
    let label: String
    @Binding var hex: String

    init(_ label: String, hex: Binding<String>) {
        self.label = label
        _hex = hex
    }

    var body: some View {
        ColorPicker(
            label,
            selection: Binding(
                get: { Color(hex: hex) ?? .gray },
                set: { hex = $0.hexString ?? hex }
            ),
            supportsOpacity: false
        )
    }
}

extension Color {
    /// Reads "#rrggbb" and the three digit short form.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }

        if text.count == 3 {
            // "#abc" means "#aabbcc", which is a form people do write by hand.
            text = text.map { String(repeating: $0, count: 2) }.joined()
        }

        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }

        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    /// Back to "#rrggbb".
    ///
    /// Through the sRGB space explicitly, because a colour that came out of the
    /// system picker can be in a wider one, and the components of a P3 colour
    /// read directly would be outside zero to one and produce nonsense.
    var hexString: String? {
        guard let components = UIColor(self).cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!,
            intent: .defaultIntent,
            options: nil
        )?.components, components.count >= 3 else {
            return nil
        }

        let clamp = { (value: CGFloat) in Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", clamp(components[0]), clamp(components[1]), clamp(components[2]))
    }
}
