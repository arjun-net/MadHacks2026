import MapKit
import UIKit

/// A minimal, app-drawn campus map (water, green space, buildings, streets) that replaces
/// Apple's map imagery. Geometry is bundled per campus (from OpenStreetMap), so nothing
/// is fetched at runtime.
final class Basemap: @unchecked Sendable {
    struct Feature {
        let path: CGPath
        let bounds: MKMapRect
    }

    enum RoadClass: CaseIterable {
        case path, minor, major
    }

    let water: [Feature]
    let green: [Feature]
    let buildings: [Feature]
    let roads: [RoadClass: [Feature]]
    /// Map points per meter around the campus, for sizing streets in real-world units.
    let pointsPerMeter: Double

    private init(water: [Feature], green: [Feature], buildings: [Feature], roads: [RoadClass: [Feature]], pointsPerMeter: Double) {
        self.water = water
        self.green = green
        self.buildings = buildings
        self.roads = roads
        self.pointsPerMeter = pointsPerMeter
    }

    // MARK: Loading

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Basemap] = [:]

    /// Basemap for a campus, or nil when none is bundled (the app then falls back to Apple Maps).
    static func forCampus(_ campus: Campus) -> Basemap? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[campus.id] { return cached }
        guard let url = Bundle.main.url(forResource: "basemap-\(campus.id)", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let basemap = parse(data, latitude: campus.center.latitude)
        else { return nil }
        cache[campus.id] = basemap
        return basemap
    }

    private static func parse(_ data: Data, latitude: Double) -> Basemap? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        /// Flat `[lat, lon, lat, lon, ...]` → map points.
        func points(_ any: Any) -> [MKMapPoint] {
            guard let flat = any as? [Double], flat.count >= 4 else { return [] }
            return stride(from: 0, to: flat.count - 1, by: 2).map {
                MKMapPoint(CLLocationCoordinate2D(latitude: flat[$0], longitude: flat[$0 + 1]))
            }
        }

        func feature(rings: [[MKMapPoint]], closed: Bool) -> Feature? {
            let path = CGMutablePath()
            var bounds = MKMapRect.null
            for ring in rings where ring.count >= 2 {
                path.addLines(between: ring.map { CGPoint(x: $0.x, y: $0.y) })
                if closed { path.closeSubpath() }
                for point in ring {
                    bounds = bounds.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
                }
            }
            return bounds.isNull ? nil : Feature(path: path, bounds: bounds)
        }

        func polygons(_ key: String) -> [Feature] {
            (root[key] as? [[Any]] ?? []).compactMap { feature(rings: $0.map(points), closed: true) }
        }

        let roadData = root["roads"] as? [String: [Any]] ?? [:]
        func lines(_ key: String) -> [Feature] {
            (roadData[key] ?? []).compactMap { feature(rings: [points($0)], closed: false) }
        }

        return Basemap(
            water: polygons("water"),
            green: polygons("green"),
            buildings: polygons("buildings"),
            roads: [.path: lines("path"), .minor: lines("minor"), .major: lines("major")],
            pointsPerMeter: MKMapPointsPerMeterAtLatitude(latitude)
        )
    }
}

/// World-spanning overlay that tells MapKit to skip its own map imagery and labels.
final class BasemapOverlay: NSObject, MKOverlay {
    let basemap: Basemap
    let boundingMapRect = MKMapRect.world
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let canReplaceMapContent = true

    init(basemap: Basemap) {
        self.basemap = basemap
    }
}

final class BasemapRenderer: MKOverlayRenderer {
    enum Palette {
        static let land = UIColor(white: 0.055, alpha: 1)
        static let green = UIColor(white: 0.075, alpha: 1)
        static let water = UIColor(white: 0.0, alpha: 1)
        static let waterEdge = UIColor(white: 0.16, alpha: 1)
        static let building = UIColor(white: 0.11, alpha: 1)
        static let path = UIColor(white: 0.13, alpha: 1)
        static let minor = UIColor(white: 0.17, alpha: 1)
        static let major = UIColor(white: 0.24, alpha: 1)
    }

    private let basemap: Basemap

    init(overlay: BasemapOverlay) {
        basemap = overlay.basemap
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        // Overlay origin is the world origin, so renderer coordinates equal map points.
        let screenPoint = 1 / zoomScale
        let meter = basemap.pointsPerMeter
        let margin = 40 * screenPoint
        let visible = mapRect.insetBy(dx: -margin, dy: -margin)

        context.setFillColor(Palette.land.cgColor)
        context.fill(rect(for: mapRect))

        func addVisible(_ features: [Basemap.Feature]) -> Bool {
            var added = false
            for feature in features where feature.bounds.intersects(visible) {
                context.addPath(feature.path)
                added = true
            }
            return added
        }

        if addVisible(basemap.green) {
            context.setFillColor(Palette.green.cgColor)
            context.fillPath(using: .evenOdd)
        }
        if addVisible(basemap.water) {
            context.setFillColor(Palette.water.cgColor)
            context.setStrokeColor(Palette.waterEdge.cgColor)
            context.setLineWidth(1.5 * screenPoint)
            context.drawPath(using: .eoFillStroke)
        }
        // Skip buildings when zoomed far out, where they'd only be noise.
        if zoomScale > 0.004, addVisible(basemap.buildings) {
            context.setFillColor(Palette.building.cgColor)
            context.fillPath(using: .evenOdd)
        }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        let roadStyles: [(Basemap.RoadClass, UIColor, minPoints: Double, meters: Double)] = [
            (.path, Palette.path, 0.6, 2),
            (.minor, Palette.minor, 1.2, 8),
            (.major, Palette.major, 2.0, 14),
        ]
        for (roadClass, color, minPoints, meters) in roadStyles {
            guard addVisible(basemap.roads[roadClass] ?? []) else { continue }
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(max(minPoints * screenPoint, meters * meter))
            context.strokePath()
        }
    }
}
