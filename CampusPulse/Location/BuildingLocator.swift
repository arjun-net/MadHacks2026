import Foundation
import simd

/// Which campus building a reading is in, sent with each ping as `building`.
///
/// Uses the same file and rules as the server's building grid (`assets/buildings.json` in the
/// backend, bundled here as `buildings-<campus id>.json`), so both agree on the name:
/// - inside an outline: that building (overlapping outlines: the smaller one, then the earlier one);
/// - otherwise the building whose wall is nearest, if within `buffer` meters. Indoor GPS is often
///   off by 10–50 m and tends to land just outside the building someone is in.
///
/// An approximation: a name means "on or near that building's footprint", not "indoors there".
struct BuildingLocator: Sendable {
    struct Building: Sendable {
        /// The `id` from the buildings file (also the campus area id).
        let id: String
        let name: String
        /// Outline in local meters (x east, y north of `origin`).
        let points: [SIMD2<Double>]
        let area: Double
        let minCorner: SIMD2<Double>
        let maxCorner: SIMD2<Double>
    }

    /// Matches the server's `BUILDING_BUFFER_M` default.
    static let defaultBuffer: Double = 15

    let buildings: [Building]
    let buffer: Double
    private let origin: Coordinate
    private let metersPerDegree: SIMD2<Double>

    /// The locator for a campus, or nil when there's no buildings file for it.
    static func forCampus(_ campusID: String) -> BuildingLocator? {
        bundled[campusID]
    }

    /// Every `buildings-<campus id>.json` in the app bundle, read once.
    private static let bundled: [String: BuildingLocator] = {
        var result: [String: BuildingLocator] = [:]
        for url in Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [] {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("buildings-"), let data = try? Data(contentsOf: url),
                  let locator = BuildingLocator(json: data) else { continue }
            result[String(name.dropFirst("buildings-".count))] = locator
        }
        return result
    }()

    private struct File: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String
            let perimeter_polygon: [[Double]]
        }
        let buildings: [Entry]
    }

    init?(json: Data, buffer: Double = BuildingLocator.defaultBuffer) {
        guard let file = try? JSONDecoder().decode(File.self, from: json) else { return nil }
        let rings = file.buildings.map { entry in
            entry.perimeter_polygon.compactMap { $0.count == 2 ? Coordinate($0[0], $0[1]) : nil }
        }
        let all = rings.flatMap { $0 }
        guard !all.isEmpty else { return nil }
        let lat = all.map(\.latitude).reduce(0, +) / Double(all.count)
        let lng = all.map(\.longitude).reduce(0, +) / Double(all.count)
        origin = Coordinate(lat, lng)
        // Meters per degree at campus latitude (WGS-84 series, as on the server).
        let phi = lat * .pi / 180
        metersPerDegree = SIMD2(
            111_412.84 * cos(phi) - 93.5 * cos(3 * phi),
            111_132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi)
        )
        self.buffer = buffer

        var buildings: [Building] = []
        for (entry, ring) in zip(file.buildings, rings) {
            var points: [SIMD2<Double>] = []
            for coordinate in ring {
                let point = SIMD2((coordinate.longitude - lng) * metersPerDegree.x, (coordinate.latitude - lat) * metersPerDegree.y)
                if points.last != point { points.append(point) }
            }
            if points.count > 1, points.first == points.last { points.removeLast() }
            guard points.count >= 3 else { continue }
            var twice = 0.0
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                twice += a.x * b.y - b.x * a.y
            }
            let area = abs(twice) / 2
            guard area >= 1 else { continue }
            let minCorner = points.dropFirst().reduce(points[0]) { simd_min($0, $1) }
            let maxCorner = points.dropFirst().reduce(points[0]) { simd_max($0, $1) }
            buildings.append(Building(id: entry.id, name: entry.name, points: points, area: area, minCorner: minCorner, maxCorner: maxCorner))
        }
        guard !buildings.isEmpty else { return nil }
        self.buildings = buildings
    }

    /// The building at `coordinate`, or nil when it isn't in or near one.
    func building(at coordinate: Coordinate) -> String? {
        match(at: coordinate)?.name
    }

    /// The id of the building at `coordinate` (see `building(at:)`).
    func buildingID(at coordinate: Coordinate) -> String? {
        match(at: coordinate)?.id
    }

    private func match(at coordinate: Coordinate) -> Building? {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }
        let p = SIMD2((coordinate.longitude - origin.longitude) * metersPerDegree.x,
                      (coordinate.latitude - origin.latitude) * metersPerDegree.y)
        var inside: Building?
        var nearest: (building: Building, distance: Double)?
        for building in buildings {
            // Cheap skip for buildings nowhere near.
            if p.x < building.minCorner.x - buffer || p.y < building.minCorner.y - buffer
                || p.x > building.maxCorner.x + buffer || p.y > building.maxCorner.y + buffer { continue }
            if Self.contains(building.points, p) {
                if inside.map({ building.area < $0.area }) ?? true { inside = building }
            } else if inside == nil {
                let distance = Self.edgeDistance(building.points, p)
                if distance <= buffer, nearest.map({ distance < $0.distance }) ?? true {
                    nearest = (building, distance)
                }
            }
        }
        return inside ?? nearest?.building
    }

    /// Even-odd ray casting.
    private static func contains(_ points: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var result = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                result.toggle()
            }
            j = i
        }
        return result
    }

    private static func edgeDistance(_ points: [SIMD2<Double>], _ p: SIMD2<Double>) -> Double {
        var best = Double.greatestFiniteMagnitude
        var j = points.count - 1
        for i in points.indices {
            let a = points[j], d = points[i] - a
            let length2 = simd_dot(d, d)
            let t = length2 > 0 ? min(1, max(0, simd_dot(p - a, d) / length2)) : 0
            best = min(best, simd_length(p - (a + t * d)))
            j = i
        }
        return best
    }
}
