import Foundation

/// App settings, and values shown in UI copy.
enum AppConfig {
    /// Location API. Temporary Cloudflare tunnel: it changes whenever the server or tunnel restarts.
    /// Docs at the same host under /docs.
    static let defaultAPIBaseURL = URL(string: "https://transparent-hitachi-marion-marie.trycloudflare.com/api/v1")!

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

    /// How often the live map re-queries the server while the app is open.
    static let liveRefreshInterval: TimeInterval = 15

    /// How often the last 24 hours (usual busy times, building sizes) is fetched again.
    static let historyRefreshInterval: TimeInterval = 10 * 60

    /// How often the people-per-building counts are pulled (`/buildings/counts`) while the app is open.
    static let buildingCountsInterval: TimeInterval = 15

    /// Building counts older than this are ignored (the server counts over a 2-minute window).
    static let buildingCountsFreshness: TimeInterval = 60

    // Everything shown comes from the backend. The switches below bring back fake data,
    // generated on the device and never uploaded, for demos without a server.

    /// Mix fake readings into the live map so it has a crowd to show. Off: only what real
    /// phones send.
    static let simulatesLiveData = false

    /// Fill each place's history with a generated week (usual busy times per weekday, past
    /// days, today so far). Off: usual busy times come from the last 24 hours of real readings.
    /// Needs `simulatesLiveData`.
    static let simulatesActivityData = simulatesLiveData

    /// Where each building's "this time vs. past weeks" story comes from: the analytics
    /// endpoint `GET /buildings/{name}/story` when true, generated on the device when false.
    static let usesServerBuildingStories = true

    /// How many past same weekdays a building story compares with.
    static let buildingStoryWeeks = 8

    /// Campus wall-clock time: the analytics server reads dates and times in this zone.
    static let campusTimeZone = TimeZone(identifier: "America/Chicago") ?? .current

    /// Simulated headcount of a packed building (scaled by its popularity).
    static let simulatedPeakHeadcount = 120.0

    /// Heat weight per person in a ~35 m cell. The renderer treats ~60 as packed, and a busy
    /// cell holds roughly 15 people, so this keeps busy buildings visibly hot.
    static let heatWeightPerPerson = 4.0

    /// A slot counts as live if it's no older than this.
    static let liveFreshness: TimeInterval = 4 * 60

    /// UserDefaults keys for the developer overrides.
    enum Overrides {
        static let apiBaseURL = "api.baseURL"
    }

    /// Headcount per unit of area popularity treated as "packed" before history has loaded.
    static let fallbackAreaCapacity = 60.0

    /// Minimum students per spot before it appears on the map (privacy copy + sample data cutoff).
    static let privacyThreshold = 5

    /// Grid size mentioned in the privacy copy.
    static let aggregationCellMeters = 35.0

    /// Area counts below this are shown as "Fewer than 10" instead of a number.
    static let minimumDisplayedCount = 10
}
