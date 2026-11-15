import Foundation

/// Gets a building's story from the analytics server, or makes one up while the app runs on
/// fake data (`AppConfig.usesServerBuildingStories`). Screens don't need to know which.
struct BuildingStoryProvider: Sendable {
    var api = BuildingStoryAPI()

    /// - Parameter live: The building's live reading; fake stories end on its count, so the
    ///   story agrees with the rest of the screen.
    func story(for area: CampusArea, campus: Campus, live: AreaActivity?, at moment: Date = .now) async throws -> BuildingStory {
        if AppConfig.usesServerBuildingStories {
            return try await api.story(building: area.name, at: moment, weeks: AppConfig.buildingStoryWeeks)
        }
        let capacity = max(10, area.popularity * AppConfig.simulatedPeakHeadcount)
        let current = live.map { Int(($0.intensity * capacity).rounded()) }
        return SampleActivityData.story(for: area, campus: campus, at: moment, currentDevices: current)
    }
}
