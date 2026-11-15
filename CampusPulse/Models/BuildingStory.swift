import Foundation

/// How busy one building is at one time of day, and how that compares with the same time on
/// past weeks' same weekday and on the other days this week. From the analytics endpoint
/// `GET /buildings/{building}/story` (or generated, while the app runs on fake data).
///
/// Counts are distinct devices that reported from the building in a window around the time.
struct BuildingStory: Sendable, Equatable {
    /// One day's count at the story's time of day.
    struct Day: Sendable, Equatable, Identifiable {
        /// Midnight of the day, in `BuildingStory.timeZone`.
        let date: Date
        /// Nil when the server has no data for that day.
        let devices: Int?

        var id: Date { date }
        var hasData: Bool { devices != nil }
    }

    /// The server's building name (what `CampusArea.name` holds).
    let building: String
    let timeZone: TimeZone
    /// Time of day the story is about, as minutes after midnight (14:30 → 870).
    let minuteOfDay: Int
    /// Minutes around `minuteOfDay` that are counted.
    let windowMinutes: Int
    let current: Day
    /// The same weekday on past weeks, newest first (as the server sends them).
    let sameWeekday: [Day]
    /// The other days of this week so far, oldest first.
    let thisWeek: [Day]

    /// Average of past same-weekday counts that have data; nil when none do.
    var usualDevices: Double? {
        let values = sameWeekday.compactMap(\.devices)
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    /// Past same-weekday counts, oldest first, for charts that read left to right.
    var sameWeekdayOldestFirst: [Day] { sameWeekday.sorted { $0.date < $1.date } }

    /// `current` versus usual, as a ratio (1.5 = half again as busy); nil without both.
    var ratioToUsual: Double? {
        guard let now = current.devices, let usual = usualDevices, usual > 0 else { return nil }
        return Double(now) / usual
    }

    /// The story's moment (its date at `minuteOfDay`).
    var moment: Date { current.date.addingTimeInterval(Double(minuteOfDay) * 60) }
}

extension BuildingStory {
    /// A calendar in the story's time zone, for formatting its dates.
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
