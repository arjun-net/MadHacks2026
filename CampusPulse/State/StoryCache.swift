import Foundation

/// Past-day building stories, kept on disk by building and moment. A past day's count at a
/// given time doesn't change, and the server takes seconds to work out each one, so reopening a
/// building (even after a relaunch) shows its past days at once. Entries expire after a few
/// hours in case the server's data is reloaded.
actor StoryCache {
    static let shared = StoryCache()

    private struct Entry: Codable {
        let story: BuildingStory
        let savedAt: Date
    }

    private static let lifetime: TimeInterval = 6 * 60 * 60
    private let url: URL
    private var entries: [String: Entry]?

    init(url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("past-day-stories.json")) {
        self.url = url
    }

    func story(building: String, at moment: Date) -> BuildingStory? {
        guard let entry = load()[Self.key(building, moment)],
              Date.now.timeIntervalSince(entry.savedAt) < Self.lifetime else { return nil }
        return entry.story
    }

    func store(_ story: BuildingStory, building: String, at moment: Date) {
        let now = Date.now
        var all = load().filter { now.timeIntervalSince($0.value.savedAt) < Self.lifetime }
        all[Self.key(building, moment)] = Entry(story: story, savedAt: now)
        entries = all
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    private func load() -> [String: Entry] {
        if let entries { return entries }
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = loaded
        return loaded
    }

    private static func key(_ building: String, _ moment: Date) -> String {
        "\(building)@\(Int(moment.timeIntervalSince1970))"
    }
}
