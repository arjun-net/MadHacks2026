import Foundation

/// Values shown in UI copy and used to shape the sample data.
enum AppConfig {
    /// Location API. Temporary Cloudflare tunnel: it changes whenever the server or tunnel restarts.
    /// Docs at the same host under /docs.
    static let apiBaseURL = URL(string: "https://network-durham-attachment-asks.trycloudflare.com/api/v1")!

    /// Location readings are sent on every even minute (10:38, 10:40, 10:42…).
    static let updateInterval: TimeInterval = 120

    /// How often the live map re-queries the server.
    static let liveRefreshInterval: TimeInterval = 30

    /// Mix fake readings, generated on the device, into the live map so it has a crowd to show.
    /// They're never uploaded. Set to false to show only what real phones send.
    static let simulatesLiveData = true

    /// Simulated headcount of a packed building (scaled by its popularity).
    static let simulatedPeakHeadcount = 120.0

    /// Heat weight per person in a ~35 m cell. The renderer treats ~60 as packed, and a busy
    /// cell holds roughly 15 people, so this keeps busy buildings visibly hot.
    static let heatWeightPerPerson = 4.0

    /// A slot counts as live if it's no older than this.
    static let liveFreshness: TimeInterval = 4 * 60

    /// The stored day of readings the trends replay (the server's simulated dataset, 2026-01-01).
    /// Its timestamps are campus wall-clock times. Point this at real days once they accumulate.
    static let historyDay = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    /// Headcount per unit of area popularity treated as "packed" before history has loaded.
    static let fallbackAreaCapacity = 60.0

    /// Minimum students per spot before it appears on the map (privacy copy + sample data cutoff).
    static let privacyThreshold = 5

    /// Grid size mentioned in the privacy copy.
    static let aggregationCellMeters = 35.0

    /// Area counts below this are shown as "Fewer than 10" instead of a number.
    static let minimumDisplayedCount = 10
}
