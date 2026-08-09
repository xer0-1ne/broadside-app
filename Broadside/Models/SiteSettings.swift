import Foundation

/// The site's settings, as `/api/settings` sends them.
///
/// This mirrors `config.Config` in `internal/config/config.go`. It is
/// deliberately the whole document rather than the handful of fields this app
/// puts on screen: an update is a partial one, decoded onto what the server
/// already has, and round tripping the parts the app does not understand means
/// a phone that predates a new setting cannot wipe it.
struct SiteSettings: Codable, Sendable, Equatable {
    var title: String = ""
    var slogan: String = ""
    var displayName: String = ""
    var baseURL: String = ""
    var image: String = ""
    var favicon: String = ""
    var footerText: String = ""
    var dateFormat: String = ""
    var timezone: String = ""
    var language: String = ""
    var postsPerPage: Int = 0
    var maxUploadMB: Int = 0
    var minPasswordLength: Int = 0
    var social: [SocialLink] = []
    var theme: Theme = Theme()

    /// Present on the wire and never sent back. The server pins it regardless,
    /// because turning it off would put the site back on its first-run page
    /// where anyone who reached it could create an account.
    var setupComplete: Bool = true

    enum CodingKeys: String, CodingKey {
        case title, slogan, image, favicon, timezone, language, social, theme
        case displayName = "display_name"
        case baseURL = "base_url"
        case footerText = "footer_text"
        case dateFormat = "date_format"
        case postsPerPage = "posts_per_page"
        case maxUploadMB = "max_upload_mb"
        case minPasswordLength = "min_password_length"
        case setupComplete = "setup_complete"
    }

    init() {}

    /// Every field is optional on the way in, and a missing one takes its
    /// default.
    ///
    /// Two reasons, and both of them bit. Go writes `null` rather than `[]` for
    /// an empty slice, so `social` arrives as null on a site with no social
    /// links and a non-optional array refuses it — which failed the entire
    /// settings screen on a perfectly ordinary site. And this app talks to
    /// servers its owner updates on their own schedule, so a field this version
    /// expects may simply not be there yet. Neither should be a decode error
    /// that blanks the whole screen.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        slogan = try c.decodeIfPresent(String.self, forKey: .slogan) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        favicon = try c.decodeIfPresent(String.self, forKey: .favicon) ?? ""
        footerText = try c.decodeIfPresent(String.self, forKey: .footerText) ?? ""
        dateFormat = try c.decodeIfPresent(String.self, forKey: .dateFormat) ?? ""
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        postsPerPage = try c.decodeIfPresent(Int.self, forKey: .postsPerPage) ?? 20
        maxUploadMB = try c.decodeIfPresent(Int.self, forKey: .maxUploadMB) ?? 256
        minPasswordLength = try c.decodeIfPresent(Int.self, forKey: .minPasswordLength) ?? 8
        social = try c.decodeIfPresent([SocialLink].self, forKey: .social) ?? []
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? Theme()
        setupComplete = try c.decodeIfPresent(Bool.self, forKey: .setupComplete) ?? true
    }

    struct SocialLink: Codable, Sendable, Equatable, Identifiable, Hashable {
        var platform: String = ""
        var url: String = ""
        var label: String = ""
        var icon: String = ""

        /// Only one entry per platform makes sense on a site, so the platform
        /// is a workable identity and survives the list being re-fetched.
        var id: String { platform }

        enum CodingKeys: String, CodingKey {
            case platform, url, label, icon
        }

        init(platform: String = "", url: String = "", label: String = "", icon: String = "") {
            self.platform = platform
            self.url = url
            self.label = label
            self.icon = icon
        }

        /// `label` and `icon` are omitempty on the wire, so their absence is
        /// ordinary rather than malformed.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        }
    }

    struct Theme: Codable, Sendable, Equatable {
        var background: String = ""
        var surface: String = ""
        var text: String = ""
        var muted: String = ""
        var accent: String = ""
        var border: String = ""
        var siteTitleFont: String = ""
        var postTitleFont: String = ""
        var contentFont: String = ""

        enum CodingKeys: String, CodingKey {
            case background, surface, text, muted, accent, border
            case siteTitleFont = "site_title_font"
            case postTitleFont = "post_title_font"
            case contentFont = "content_font"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            background = try c.decodeIfPresent(String.self, forKey: .background) ?? ""
            surface = try c.decodeIfPresent(String.self, forKey: .surface) ?? ""
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            muted = try c.decodeIfPresent(String.self, forKey: .muted) ?? ""
            accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? ""
            border = try c.decodeIfPresent(String.self, forKey: .border) ?? ""
            siteTitleFont = try c.decodeIfPresent(String.self, forKey: .siteTitleFont) ?? ""
            postTitleFont = try c.decodeIfPresent(String.self, forKey: .postTitleFont) ?? ""
            contentFont = try c.decodeIfPresent(String.self, forKey: .contentFont) ?? ""
        }
    }
}

extension SiteSettings {
    /// The limits the server enforces, repeated here so a value it would refuse
    /// can be refused on the phone instead of after a round trip.
    ///
    /// These match the constants in `internal/config/config.go`. They are a
    /// courtesy rather than the enforcement: the server clamps on the way to
    /// disk and sends back what it actually stored.
    enum Limits {
        static let uploadCeilingMB = 4096
        static let uploadFloorMB = 1
        static let passwordFloor = 6
        static let passwordCeiling = 128
        static let postsPerPageRange = 1...100
    }
}
