import Foundation

/// Values shown in UI copy and used to shape the sample data.
enum AppConfig {
    /// Location API. Temporary Cloudflare tunnel: it changes whenever the server or tunnel restarts.
    /// Docs at the same host under /docs.
    static let defaultAPIBaseURL = URL(string: "https://instrumentation-variables-instructional-shine.trycloudflare.com/api/v1")!

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

    /// Mix fake readings, generated on the device, into the live map so it has a crowd to show.
    /// They're never uploaded. Set to false to show only what real phones send.
    static let simulatesLiveData = true

    /// Fill the Activity tab with fake data too: it shows the same reading as the map, and each
    /// place gets a generated week of history (usual busy times per weekday, the past seven
    /// days and today so far) instead of the server's one stored day. Needs `simulatesLiveData`.
    static let simulatesActivityData = simulatesLiveData

    /// Simulated headcount of a packed building (scaled by its popularity).
    static let simulatedPeakHeadcount = 120.0

    /// Heat weight per person in a ~35 m cell. The renderer treats ~60 as packed, and a busy
    /// cell holds roughly 15 people, so this keeps busy buildings visibly hot.
    static let heatWeightPerPerson = 4.0

    /// A slot counts as live if it's no older than this.
    static let liveFreshness: TimeInterval = 4 * 60

    /// The stored day of readings the trends replay (the server's simulated dataset, 2026-01-01).
    /// Its timestamps are campus wall-clock times. Point this at real days once they accumulate.
    static let defaultHistoryDay = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    /// The stored day in use. Override from Settings > Developer or with `-history.day 2026-01-02`.
    static var historyDay: Date {
        UserDefaults.standard.string(forKey: Overrides.historyDay).flatMap(parseDay) ?? defaultHistoryDay
    }

    /// "2026-01-01" → midnight UTC that day.
    static func parseDay(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    /// UserDefaults keys for the developer overrides.
    enum Overrides {
        static let apiBaseURL = "api.baseURL"
        static let historyDay = "history.day"
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
