import Foundation

/// Activity for one hour of a day (0…23).
struct HourlyValue: Identifiable, Hashable, Sendable {
    let hour: Double
    /// 0…1 relative activity.
    let intensity: Double

    var id: Double { hour }
    var level: ActivityLevel { ActivityLevel(intensity: intensity) }
}

/// One past day for an area.
struct DayHistory: Identifiable, Hashable, Sendable {
    let date: Date
    let hourly: [HourlyValue]

    var id: Date { date }

    /// Average across daytime hours (8 AM – 10 PM), when most people are on campus.
    var daytimeAverage: Double {
        let daytime = hourly.filter { $0.hour >= 8 && $0.hour <= 22 }
        guard !daytime.isEmpty else { return 0 }
        return daytime.reduce(0) { $0 + $1.intensity } / Double(daytime.count)
    }

    var peak: HourlyValue? { hourly.max { $0.intensity < $1.intensity } }
}

/// How the live reading compares to what's normal for this hour and weekday.
enum UsualComparison: Sendable {
    case busier, usual, quieter

    /// Compares by activity level so it never contradicts the "Usual now" level shown beside it.
    init(live: Double, typical: Double) {
        let liveLevel = ActivityLevel(intensity: live)
        let typicalLevel = ActivityLevel(intensity: typical)
        if liveLevel > typicalLevel { self = .busier } else if liveLevel < typicalLevel { self = .quieter } else { self = .usual }
    }

    var title: String {
        switch self {
        case .busier: "Busier than usual"
        case .usual: "About as busy as usual"
        case .quieter: "Quieter than usual"
        }
    }

    var symbol: String {
        switch self {
        case .busier: "arrow.up.right"
        case .usual: "equal"
        case .quieter: "arrow.down.right"
        }
    }
}

/// Historical and typical activity for one area, used by the area detail screen.
struct AreaInsights: Sendable {
    let area: CampusArea
    let generatedAt: Date
    /// Typical hourly activity keyed by `Calendar` weekday (1 = Sunday … 7 = Saturday).
    let typicalByWeekday: [Int: [HourlyValue]]
    /// The previous seven days, oldest → newest.
    let pastDays: [DayHistory]
    /// Today from midnight up to now; the last point is the live reading.
    let today: [HourlyValue]

    var todayWeekday: Int { Calendar.current.component(.weekday, from: generatedAt) }

    func typical(weekday: Int) -> [HourlyValue] {
        typicalByWeekday[weekday] ?? []
    }

    var typicalNow: Double {
        let hour = Int(generatedAt.fractionalHour)
        return typical(weekday: todayWeekday).first { Int($0.hour) == hour }?.intensity ?? 0
    }

    /// Same weekday last week, at this hour.
    var lastWeekNow: Double? {
        guard let lastWeek = pastDays.first else { return nil }
        let hour = Int(generatedAt.fractionalHour)
        return lastWeek.hourly.first { Int($0.hour) == hour }?.intensity
    }

    /// Hour with the highest typical activity on a weekday.
    func usualPeak(weekday: Int) -> HourlyValue? {
        typical(weekday: weekday).max { $0.intensity < $1.intensity }
    }

    /// Quietest daytime hour still ahead today, if any.
    var quietestLaterToday: HourlyValue? {
        let now = generatedAt.fractionalHour
        return typical(weekday: todayWeekday)
            .filter { $0.hour > now && $0.hour >= 7 && $0.hour <= 22 }
            .min { $0.intensity < $1.intensity }
    }
}
