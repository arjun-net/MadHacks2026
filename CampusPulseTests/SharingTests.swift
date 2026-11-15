import Foundation
import Testing
@testable import CampusPulse

/// Upload schedule, the campus check, the offline queue and the wire format.
struct SharingTests {
    @Test(arguments: [
        ("10:37:30", "10:38:00"),
        ("10:38:00", "10:40:00"),
        ("10:39:59", "10:40:00"),
        ("23:59:10", "00:00:00"),
    ])
    func nextSlotIsTheNextEvenMinute(now: String, expected: String) {
        let date = Self.utc(now)
        let slot = SharingState.nextSlot(after: date)
        #expect(Self.clock(slot) == expected)
        #expect(slot > date)
    }

    @MainActor
    @Test func campusOutlineContainsBuildingsButNotTheLake() {
        let campus = CampusCatalog.madison
        let library = campus.area(withID: "college-library")!.coordinate
        #expect(SharingState.contains(campus.boundary, library))
        #expect(!SharingState.contains(campus.boundary, Coordinate(43.10, -89.42)))
    }

    @Test func queueSurvivesASaveAndKeepsOnlyTheNewest() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = PendingLocationQueue(fileURL: url)
        let points = (0..<(PendingLocationQueue.capacity + 5)).map {
            LocationPoint(lat: 43, lng: -89, timestamp: Date(timeIntervalSince1970: Double($0) * 120), deviceID: "ios-test")
        }

        queue.save(points)
        let loaded = queue.load()

        #expect(loaded.count == PendingLocationQueue.capacity)
        #expect(loaded.first == points[5])
        #expect(loaded.last == points.last)

        queue.save([])
        #expect(queue.load().isEmpty)
    }

    @Test func pointEncodesAsTheBackendExpects() throws {
        let point = LocationPoint(lat: 43.0768, lng: -89.4013, timestamp: Date(timeIntervalSince1970: 1_800_000_000), deviceID: "ios-abc")
        let json = try JSONSerialization.jsonObject(with: LocationAPI.encoder.encode(point)) as? [String: Any]

        #expect(json?["device_id"] as? String == "ios-abc")
        #expect(json?["lat"] as? Double == 43.0768)
        #expect((json?["timestamp"] as? String)?.hasPrefix("2027-01-15T08:00:00") == true)
        // No building: the key is left out, which every server version accepts.
        #expect(json?["building"] == nil)

        var inBuilding = point
        inBuilding.building = "Morgridge Hall (College of Computing & AI)"
        let tagged = try JSONSerialization.jsonObject(with: LocationAPI.encoder.encode(inBuilding)) as? [String: Any]
        #expect(tagged?["building"] as? String == "Morgridge Hall (College of Computing & AI)")
    }

    @Test func queuedPointsFromBeforeBuildingsStillLoad() throws {
        let old = #"{"lat":43.07,"lng":-89.4,"timestamp":"2026-11-15T05:10:00Z","device_id":"ios-a"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let point = try decoder.decode(LocationPoint.self, from: Data(old.utf8))
        #expect(point.building == nil)
    }

    /// Real readings from inside Morgridge Hall that the database stored with no building.
    @Test func locatorFindsMorgridgeHallFromRealPings() throws {
        let locator = try #require(BuildingLocator.forCampus("uw-madison"))
        let hall = "Morgridge Hall (College of Computing & AI)"
        for (lat, lng) in [(43.073091, -89.406866), (43.073141, -89.407074), (43.073145, -89.407038), (43.072922, -89.407105)] {
            #expect(locator.building(at: Coordinate(lat, lng)) == hall)
        }
        // ~10 m outside the north and east walls: GPS slack still counts it.
        #expect(locator.building(at: Coordinate(43.07328, -89.40690)) == hall)
        #expect(locator.building(at: Coordinate(43.07302, -89.40597)) == hall)
        // ~40 m away, the lake, and off campus: nothing (or not the hall).
        #expect(locator.building(at: Coordinate(43.07355, -89.40690)) != hall)
        #expect(locator.building(at: Coordinate(43.0900, -89.4000)) == nil)
        #expect(locator.building(at: Coordinate(48.8584, 2.2945)) == nil)
        #expect(locator.buildings.count == 20)
    }

    @Test func developerDayOverrideParsesAsUTCMidnight() {
        #expect(AppConfig.parseDay("2026-01-01") == AppConfig.defaultHistoryDay)
        #expect(AppConfig.parseDay(" 2026-01-02 ") == AppConfig.defaultHistoryDay.addingTimeInterval(86_400))
        #expect(AppConfig.parseDay("Jan 1") == nil)
    }

    // MARK: - Helpers

    private static func utc(_ time: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "2026-11-14T\(time)Z")!
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
