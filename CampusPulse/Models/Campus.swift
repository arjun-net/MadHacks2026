import MapKit

struct Campus: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let shortName: String
    let location: String
    let center: Coordinate
    let latitudeSpan: Double
    let longitudeSpan: Double
    let areas: [CampusArea]
    /// Relative share of students using the app (drives mock data volume).
    let participationScale: Double
    /// Hand-drawn campus outline. When nil, an outline is derived from the campus areas.
    var customBoundary: [Coordinate]? = nil
    /// Whether the backend collects data here yet. Unavailable campuses are listed as "Coming soon".
    var isAvailable = true

    /// Closed outline of campus used to frame, mask and clip the map.
    var boundary: [Coordinate] {
        customBoundary ?? Self.paddedHull(around: areas.map(\.coordinate), paddingMeters: 170)
    }

    /// The part of campus to frame on screen: the tracked buildings plus a margin.
    /// (The outline can include large outlying land, like nature preserves.)
    var focusRect: MKMapRect {
        let rect = areas
            .map { MKMapPoint($0.coordinate.clCoordinate) }
            .reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0))) }
        let margin = MKMapPointsPerMeterAtLatitude(center.latitude) * 140
        return rect.insetBy(dx: -margin, dy: -margin)
    }

    /// Map rect enclosing the campus outline.
    var boundaryRect: MKMapRect {
        boundary
            .map { MKMapPoint($0.clCoordinate) }
            .reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0))) }
    }

    /// Convex hull of the points, pushed outward from its center so buildings sit inside the edge.
    private static func paddedHull(around points: [Coordinate], paddingMeters: Double) -> [Coordinate] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted { ($0.longitude, $0.latitude) < ($1.longitude, $1.latitude) }
        func cross(_ o: Coordinate, _ a: Coordinate, _ b: Coordinate) -> Double {
            (a.longitude - o.longitude) * (b.latitude - o.latitude) - (a.latitude - o.latitude) * (b.longitude - o.longitude)
        }
        var lower: [Coordinate] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [Coordinate] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        let hull = Array(lower.dropLast() + upper.dropLast())
        let centroid = Coordinate(
            hull.map(\.latitude).reduce(0, +) / Double(hull.count),
            hull.map(\.longitude).reduce(0, +) / Double(hull.count)
        )
        return hull.map { point in
            let distance = max(1, centroid.distance(to: point))
            let scale = (distance + paddingMeters) / distance
            return Coordinate(
                centroid.latitude + (point.latitude - centroid.latitude) * scale,
                centroid.longitude + (point.longitude - centroid.longitude) * scale
            )
        }
    }

    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: center.clCoordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
        )
    }

    var mapRect: MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(
            latitude: center.latitude + latitudeSpan / 2,
            longitude: center.longitude - longitudeSpan / 2
        ))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(
            latitude: center.latitude - latitudeSpan / 2,
            longitude: center.longitude + longitudeSpan / 2
        ))
        return MKMapRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }

    /// The area the heatmap covers: the campus plus a margin so blobs never clip at the edge.
    var heatmapBounds: MKMapRect {
        let rect = mapRect
        return rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.25)
    }

    func area(withID id: String) -> CampusArea? {
        areas.first { $0.id == id }
    }
}

struct CampusArea: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let shortName: String
    let category: AreaCategory
    let coordinate: Coordinate
    /// Rough footprint of the area, used for clustering mock students.
    let radiusMeters: Double
    /// 0…1 baseline draw of the area relative to the busiest place on campus.
    let popularity: Double
    var symbolOverride: String? = nil

    var symbol: String { symbolOverride ?? category.symbol }
}

enum AreaCategory: String, Codable, Sendable, CaseIterable {
    case library, union, recreation, dining, academic, housing, athletics, outdoors

    var title: String {
        switch self {
        case .library: "Library"
        case .union: "Student Union"
        case .recreation: "Recreation"
        case .dining: "Dining"
        case .academic: "Academic"
        case .housing: "Residence"
        case .athletics: "Athletics"
        case .outdoors: "Outdoors"
        }
    }

    var symbol: String {
        switch self {
        case .library: "books.vertical.fill"
        case .union: "cup.and.saucer.fill"
        case .recreation: "figure.run"
        case .dining: "fork.knife"
        case .academic: "building.columns.fill"
        case .housing: "bed.double.fill"
        case .athletics: "sportscourt.fill"
        case .outdoors: "tree.fill"
        }
    }

    /// Typical relative demand for this kind of place at a given hour (0…24).
    func demand(atHour hour: Double) -> Double {
        func bump(_ center: Double, _ width: Double, _ amplitude: Double) -> Double {
            var distance = abs(hour - center)
            distance = min(distance, 24 - distance)
            return amplitude * exp(-pow(distance / width, 2))
        }
        let raw: Double
        switch self {
        case .library: raw = 0.22 + bump(15, 3.5, 0.55) + bump(20.5, 2.6, 0.6)
        case .union: raw = 0.28 + bump(12.5, 1.7, 0.6) + bump(19, 2.6, 0.5)
        case .recreation: raw = 0.18 + bump(7.5, 1.3, 0.45) + bump(18, 2.3, 0.72)
        case .dining: raw = 0.14 + bump(8, 1.0, 0.45) + bump(12.3, 1.2, 0.82) + bump(18, 1.4, 0.75)
        case .academic: raw = 0.18 + bump(11, 3.0, 0.72) + bump(15, 2.0, 0.35)
        case .housing: raw = 0.4 + bump(22, 3.0, 0.4)
        case .athletics: raw = 0.12 + bump(16, 2.0, 0.25)
        case .outdoors: raw = 0.2 + bump(13, 3.0, 0.5)
        }
        // Floor keeps the demo map alive at any hour (hackathons run late).
        return min(1, max(0.4, raw))
    }
}
