import Foundation

/// How busy one building is at one time of day, and how that compares with the same time on
/// past weeks' same weekday and on the other days this week. From the analytics endpoint
/// `GET /buildings/{building}/story` (or generated, while the app runs on fake data).
///
/// Counts are location reports (rows, `observations`) from the building in a window around the
/// time: not distinct people. Phones report every 2 minutes, so one person in the building for the
/// whole window adds several. Good for comparing days with each other, not as a headcount.
struct BuildingStory: Sendable, Equatable {
    /// One day's count at the story's time of day.
    struct Day: Sendable, Equatable, Identifiable {
        /// Midnight of the day, in `BuildingStory.timeZone`.
        let date: Date
        /// Location reports in the window. Nil when the server has no data for that day (none,
        /// too few to show, or not reached yet).
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
    /// The server's average of past same weekdays (`weekday_average`; nil under 2 days with data).
    var serverWeekdayAverage: Double? = nil
    /// The server's average of this week's other days (`other_days_this_week_average`).
    var otherDaysAverage: Double? = nil

    /// What's usual for this weekday at this time: the server's average, else the past same
    /// weekdays that have data; nil when none do.
    var usualDevices: Double? {
        if let serverWeekdayAverage { return serverWeekdayAverage }
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

/// A count against what's usual for that weekday and time.
enum BusyComparison: Sendable, Equatable {
    /// At least a quarter more than usual.
    case busier
    /// Under 80% of usual.
    case quieter
    case usual
    /// A count, but no past same weekdays to compare it with.
    case noHistory
    /// No count for the day.
    case noData

    init(devices: Int?, usual: Double?) {
        guard let devices else { self = .noData; return }
        guard let usual else { self = .noHistory; return }
        guard usual > 0 else { self = devices > 0 ? .busier : .usual; return }
        let ratio = Double(devices) / usual
        self = ratio >= 1.25 ? .busier : ratio < 0.8 ? .quieter : .usual
    }
}

extension BuildingStory {
    /// What a count is compared with.
    enum UsualBasis: Sendable, Equatable {
        /// Past weeks' same weekday.
        case sameWeekday
        /// The other days of the same week, until there are past weeks to go on.
        case thisWeek
    }

    /// The usual count to compare `current` with, and what it's based on.
    var baseline: (value: Double, basis: UsualBasis)? {
        if let usual = usualDevices { return (usual, .sameWeekday) }
        if let otherDaysAverage { return (otherDaysAverage, .thisWeek) }
        return nil
    }

    /// The story's day (`current`) against its baseline.
    var comparison: BusyComparison { BusyComparison(devices: current.devices, usual: baseline?.value) }

    /// A calendar in the story's time zone, for formatting its dates.
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
