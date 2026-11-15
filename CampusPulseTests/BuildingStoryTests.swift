import Foundation
import Testing
@testable import CampusPulse

/// The analytics story endpoint's wire format, and the fake stories used until it has data.
struct BuildingStoryTests {
    /// Trimmed from a real `/buildings/__DEMO__ Story Lab/story` response.
    private static let sample = #"""
    {
      "building": "__DEMO__ Story Lab",
      "date": "2026-11-14",
      "weekday": "Saturday",
      "time_local": "14:30",
      "timezone": "America/Chicago",
      "window_minutes": 15,
      "metric": "distinct_reporting_devices",
      "current": {"date": "2026-11-14", "weekday": "Saturday", "reporting_devices": 42, "status": "available"},
      "historical_same_weekday": [
        {"date": "2026-11-07", "weekday": "Saturday", "reporting_devices": 12, "status": "available"},
        {"date": "2026-10-31", "weekday": "Saturday", "reporting_devices": 16, "status": "available"},
        {"date": "2026-10-24", "weekday": "Saturday", "reporting_devices": 14, "status": "available"},
        {"date": "2026-10-17", "weekday": "Saturday", "reporting_devices": 14, "status": "available"},
        {"date": "2026-10-10", "weekday": "Saturday", "reporting_devices": null, "status": "no_data"}
      ],
      "this_week": [
        {"date": "2026-11-10", "weekday": "Tuesday", "reporting_devices": 20, "status": "available"},
        {"date": "2026-11-09", "weekday": "Monday", "reporting_devices": 18, "status": "available"}
      ]
    }
    """#

    @Test func decodesTheServerResponse() throws {
        let story = try BuildingStoryAPI.decode(Data(Self.sample.utf8))
        #expect(story.building == "__DEMO__ Story Lab")
        #expect(story.timeZone.identifier == "America/Chicago")
        #expect(story.minuteOfDay == 14 * 60 + 30)
        #expect(story.windowMinutes == 15)
        #expect(story.current.devices == 42)
        #expect(story.sameWeekday.count == 5)
        #expect(story.sameWeekday.last?.devices == nil)
        // Oldest first, whatever order the server sends.
        #expect(story.thisWeek.map(\.devices) == [18, 20])
        #expect(BuildingStoryAPI.dayString(story.current.date, in: story.timeZone) == "2026-11-14")
    }

    @Test func comparesWithTheUsualSameWeekday() throws {
        let story = try BuildingStoryAPI.decode(Data(Self.sample.utf8))
        // (12 + 16 + 14 + 14) / 4; the day without data is left out.
        #expect(story.usualDevices == 14)
        #expect(story.ratioToUsual == 3)
    }

    @Test func requestFormatsUseCampusTime() {
        let chicago = TimeZone(identifier: "America/Chicago")!
        let moment = ISO8601DateFormatter().date(from: "2026-11-14T20:30:00Z")!
        #expect(BuildingStoryAPI.dayString(moment, in: chicago) == "2026-11-14")
        #expect(BuildingStoryAPI.timeString(moment, in: chicago) == "14:30")
        #expect(BuildingStoryAPI.parseTime("9:05") == 545)
        #expect(BuildingStoryAPI.parseTime("25:00") == nil)
    }

    @Test func fakeStoryHasTheServersShape() throws {
        let campus = try #require(CampusCatalog.all.first { $0.isAvailable })
        let area = try #require(campus.areas.first)
        let monday = ISO8601DateFormatter().date(from: "2026-11-16T20:30:00Z")!
        let thursday = ISO8601DateFormatter().date(from: "2026-11-19T20:30:00Z")!

        let story = SampleActivityData.story(for: area, campus: campus, at: thursday, currentDevices: 33, weeks: 8)
        #expect(story.building == area.name)
        #expect(story.current.devices == 33)
        #expect(story.sameWeekday.count == 8)
        #expect(story.sameWeekday.filter { !$0.hasData }.count == 2)
        // Monday through Wednesday.
        #expect(story.thisWeek.count == 3)
        #expect(SampleActivityData.story(for: area, campus: campus, at: monday).thisWeek.isEmpty)
        // Repeatable, so it doesn't change between refreshes.
        #expect(story == SampleActivityData.story(for: area, campus: campus, at: thursday, currentDevices: 33, weeks: 8))
    }
}

/// Busier or quieter than usual, shared by the "this time" and "past days" sections.
struct BusyComparisonTests {
    @Test(arguments: [
        (13, 10.0, BusyComparison.busier),
        (12, 10.0, .usual),
        (8, 10.0, .usual),
        (7, 10.0, .quieter),
        (3, 0.0, .busier),
        (0, 0.0, .usual),
    ] as [(Int, Double, BusyComparison)])
    func comparesWithUsual(devices: Int, usual: Double, expected: BusyComparison) {
        #expect(BusyComparison(devices: devices, usual: usual) == expected)
    }

    @Test func missingDataOrHistory() {
        #expect(BusyComparison(devices: nil, usual: 10) == .noData)
        #expect(BusyComparison(devices: 5, usual: nil) == .noHistory)
    }

    @Test func fakePastDayComparesWithItsOwnWeekday() throws {
        let campus = try #require(CampusCatalog.all.first { $0.isAvailable })
        let area = try #require(campus.areas.first)
        let saturday = ISO8601DateFormatter().date(from: "2026-11-14T20:30:00Z")!
        let story = SampleActivityData.story(for: area, campus: campus, at: saturday)
        #expect(story.current.hasData)
        #expect(story.usualDevices != nil)
        #expect(story.comparison != .noData)
    }
}
