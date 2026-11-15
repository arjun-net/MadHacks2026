import Foundation

/// One cell of the heatmap: a spot on campus and how many students are there.
struct DensityCell: Hashable, Sendable {
    let coordinate: Coordinate
    let weight: Int
}

struct AreaActivity: Identifiable, Hashable, Sendable {
    let area: CampusArea
    /// 0…1 relative activity.
    let intensity: Double
    /// Rounded estimate. `nil` when too few students are present to show a number.
    let estimatedCount: Int?
    /// Oldest → newest, one sample per update interval.
    let history: [Double]

    var id: String { area.id }
    var level: ActivityLevel { ActivityLevel(intensity: intensity) }
    var trend: ActivityTrend { ActivityTrend(history: history) }

    var countLabel: String {
        guard let estimatedCount else { return "Fewer than \(AppConfig.minimumDisplayedCount)" }
        return "~\(Formatting.number(estimatedCount)) here"
    }
}

struct CampusSnapshot: Hashable, Sendable {
    let campusID: String
    let generatedAt: Date
    /// Campus-wide participants, rounded to the nearest 10.
    let participantCount: Int
    let overallIntensity: Double
    let cells: [DensityCell]
    var areas: [AreaActivity]
    /// Campus-wide intensity, oldest → newest.
    let history: [Double]
    let privacyThreshold: Int

    var level: ActivityLevel { ActivityLevel(intensity: overallIntensity) }
    var trend: ActivityTrend { ActivityTrend(history: history) }

    /// Not enough aggregate data to render a meaningful (and private) heatmap.
    var isEmpty: Bool { cells.isEmpty || participantCount < 30 }

    /// Busiest first; equally busy places (say, all packed) by headcount.
    var areasByActivity: [AreaActivity] {
        areas.sorted {
            $0.intensity != $1.intensity ? $0.intensity > $1.intensity : ($0.estimatedCount ?? 0) > ($1.estimatedCount ?? 0)
        }
    }

    func busiest(_ count: Int) -> [AreaActivity] {
        Array(areasByActivity.prefix(count))
    }

    func quietest(_ count: Int) -> [AreaActivity] {
        Array(areas.sorted { $0.intensity < $1.intensity }.prefix(count))
    }

    var activeAreaCount: Int {
        areas.filter { $0.level >= .moderate }.count
    }

    func activity(for areaID: String) -> AreaActivity? {
        areas.first { $0.id == areaID }
    }
}

enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
}
