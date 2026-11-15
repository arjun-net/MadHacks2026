import Foundation

/// Client for `GET /buildings/{building}/story?date=YYYY-MM-DD&time=HH:MM&weeks=N`: one
/// building's count at a time of day, against the same weekday on past weeks and the other days
/// of this week. Backed by the analytics database.
struct BuildingStoryAPI: Sendable {
    /// Read per request, so a server change in Settings > Developer applies right away.
    var baseURL: URL { AppConfig.apiBaseURL }
    var session: URLSession = .shared

    /// - Parameters:
    ///   - building: The building's slug (`CampusArea.id`, e.g. `ebling_library`). The server
    ///     knows buildings only by slug; a display name returns no data.
    ///   - moment: The date and time of day to ask about, read in `timeZone`.
    ///   - weeks: How many past same weekdays to compare with.
    func story(building: String, at moment: Date, weeks: Int = 8, timeZone: TimeZone = AppConfig.campusTimeZone) async throws -> BuildingStory {
        // `appending(component:)` escapes any "/" in a name, so it stays one path segment.
        let url = baseURL.appending(path: "buildings").appending(component: building).appending(path: "story")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "date", value: Self.dayString(moment, in: timeZone)),
            URLQueryItem(name: "time", value: Self.timeString(moment, in: timeZone)),
            URLQueryItem(name: "weeks", value: String(weeks)),
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // e.g. 502 {"detail":"Databricks activity query failed; check server logs"}
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
            throw HeatmapAPI.Failure(message: detail ?? "The server returned HTTP \(status).")
        }
        return try Self.decode(data)
    }

    /// Parses a story response. Days the server marks `no_data` (or sends without a count) have
    /// no count.
    static func decode(_ data: Data) throws -> BuildingStory {
        let body = try JSONDecoder().decode(Body.self, from: data)
        let timeZone = TimeZone(identifier: body.timezone) ?? AppConfig.campusTimeZone
        func day(_ entry: Body.Day) throws -> BuildingStory.Day {
            guard let date = parseDay(entry.date, in: timeZone) else {
                throw HeatmapAPI.Failure(message: "Unreadable date \(entry.date) in building story.")
            }
            let hasData = entry.status == nil || entry.status == "available"
            return BuildingStory.Day(date: date, devices: hasData ? entry.observations ?? entry.reportingDevices : nil)
        }
        guard let minute = parseTime(body.timeLocal) else {
            throw HeatmapAPI.Failure(message: "Unreadable time \(body.timeLocal) in building story.")
        }
        return BuildingStory(
            building: body.building,
            timeZone: timeZone,
            minuteOfDay: minute,
            windowMinutes: body.windowMinutes,
            current: try day(body.current),
            sameWeekday: try body.historicalSameWeekday.map(day),
            thisWeek: try (body.thisWeek ?? []).map(day).sorted { $0.date < $1.date },
            serverWeekdayAverage: body.weekdayAverage,
            otherDaysAverage: body.otherDaysThisWeekAverage
        )
    }

    // MARK: Formats

    /// "2026-11-14" for the day `date` falls on in `timeZone`.
    static func dayString(_ date: Date, in timeZone: TimeZone) -> String {
        formatter("yyyy-MM-dd", timeZone).string(from: date)
    }

    /// "14:30" for the time of day `date` falls on in `timeZone`.
    static func timeString(_ date: Date, in timeZone: TimeZone) -> String {
        formatter("HH:mm", timeZone).string(from: date)
    }

    /// Midnight of "2026-11-14" in `timeZone`.
    static func parseDay(_ text: String, in timeZone: TimeZone) -> Date? {
        formatter("yyyy-MM-dd", timeZone).date(from: text)
    }

    /// "14:30" → 870 minutes after midnight.
    static func parseTime(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    // MARK: Wire format

    private struct Body: Decodable {
        struct Day: Decodable {
            let date: String
            /// Location rows in the window.
            let observations: Int?
            /// Older servers' name for `observations`.
            let reportingDevices: Int?
            /// "available", "suppressed" (too few rows), "no_data" or "future".
            let status: String?

            enum CodingKeys: String, CodingKey {
                case date, status, observations
                case reportingDevices = "reporting_devices"
            }
        }

        let building: String
        let timeLocal: String
        let timezone: String
        let windowMinutes: Int
        let current: Day
        let historicalSameWeekday: [Day]
        let thisWeek: [Day]?
        let weekdayAverage: Double?
        let otherDaysThisWeekAverage: Double?

        enum CodingKeys: String, CodingKey {
            case building, timezone, current
            case weekdayAverage = "weekday_average"
            case otherDaysThisWeekAverage = "other_days_this_week_average"
            case timeLocal = "time_local"
            case windowMinutes = "window_minutes"
            case historicalSameWeekday = "historical_same_weekday"
            case thisWeek = "this_week"
        }
    }

    private struct ErrorBody: Decodable { let detail: String }
}
