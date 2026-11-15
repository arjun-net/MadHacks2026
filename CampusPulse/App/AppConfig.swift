import Foundation

/// Values shown in UI copy and used to shape the sample data.
enum AppConfig {
    /// Location API. Temporary Cloudflare tunnel: it changes whenever the server or tunnel restarts.
    /// Docs at the same host under /docs.
    static let apiBaseURL = URL(string: "https://rings-bob-persistent-lowest.trycloudflare.com/api/v1")!

    /// Location readings are sent on every even minute (10:38, 10:40, 10:42…).
    static let updateInterval: TimeInterval = 120

    /// How often the sample heatmap changes, so the UI visibly animates during demos.
    static let sampleRefreshInterval: TimeInterval = 20

    /// Minimum students per spot before it appears on the map (privacy copy + sample data cutoff).
    static let privacyThreshold = 5

    /// Grid size mentioned in the privacy copy.
    static let aggregationCellMeters = 35.0

    /// Area counts below this are shown as "Fewer than 10" instead of a number.
    static let minimumDisplayedCount = 10
}
