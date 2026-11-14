import CoreLocation
import MapKit

/// Lightweight coordinate used by the models and the map.
struct Coordinate: Hashable, Codable, Sendable {
    var latitude: Double
    var longitude: Double

    init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(coordinate.latitude, coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private static let metersPerDegreeLatitude = 111_320.0

    private var metersPerDegreeLongitude: Double {
        Self.metersPerDegreeLatitude * cos(latitude * .pi / 180)
    }

    func offset(eastMeters: Double, northMeters: Double) -> Coordinate {
        Coordinate(
            latitude + northMeters / Self.metersPerDegreeLatitude,
            longitude + eastMeters / metersPerDegreeLongitude
        )
    }

    /// Approximate ground distance; accurate enough at campus scale.
    func distance(to other: Coordinate) -> Double {
        let dy = (other.latitude - latitude) * Self.metersPerDegreeLatitude
        let dx = (other.longitude - longitude) * metersPerDegreeLongitude
        return (dx * dx + dy * dy).squareRoot()
    }
}
