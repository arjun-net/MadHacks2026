import Foundation

/// App settings, and values shown in UI copy.
enum AppConfig {
    /// Location API. Temporary Cloudflare tunnel: it changes whenever the server or tunnel restarts.
    /// Docs at the same host under /docs.
    static let defaultAPIBaseURL = URL(string: "https://courage-ever-likely-atomic.trycloudflare.com/api/v1")!

    /// The server in use. Override without rebuilding from Settings > Developer (debug builds),
    /// or with the launch argument `-api.baseURL https://…/api/v1`.
    static var apiBaseURL: URL {
        if let value = UserDefaults.standard.string(forKey: Overrides.apiBaseURL),
           let url = URL(string: value), url.scheme == "https" || url.scheme == "http", url.host() != nil {
            return url
        }
        return defaultAPIBaseURL
    }

    /// Location readings are sent on every even minute (10:38, 10:40, 10:42…).
    static let updateInterval: TimeInterval = 120

    /// How often the live map re-queries the server.
    static let liveRefreshInterval: TimeInterval = 30

    /// How often the people-per-building counts are pulled (`/buildings/counts`) while the app is open.
    static let buildingCountsInterval: TimeInterval = 15

    /// Building counts older than this are ignored (the server counts over a 2-minute window).
    static let buildingCountsFreshness: TimeInterval = 60

    /// Heat weight per person in a ~35 m cell. The renderer treats ~60 as packed, and a busy
    /// cell holds roughly 15 people, so this keeps busy buildings visibly hot.
    static let heatWeightPerPerson = 4.0

    /// A slot counts as live if it's no older than this.
    static let liveFreshness: TimeInterval = 4 * 60

    /// How often the last 24 hours (usual busy times, building sizes) is fetched again.
    static let historyRefreshInterval: TimeInterval = 10 * 60

    /// UserDefaults keys for the developer overrides.
    enum Overrides {
        static let apiBaseURL = "api.baseURL"
    }

    /// Headcount per unit of area popularity treated as "packed" before history has loaded.
    static let fallbackAreaCapacity = 60.0

    /// Minimum students per spot before it appears on the map (and the privacy copy).
    static let privacyThreshold = 5

    /// Grid size mentioned in the privacy copy.
    static let aggregationCellMeters = 35.0

    /// Area counts below this are shown as "Fewer than 10" instead of a number.
    static let minimumDisplayedCount = 10
}
