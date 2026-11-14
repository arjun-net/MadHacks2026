import Foundation

/// Values shown in UI copy and used to shape the sample data.
enum AppConfig {
    /// The "~2 minutes" update cadence described in the sharing UI.
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
