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
    /// Adaptive map colors: a printed-street-map look on cream (Day) and a warm dark
    /// variant tuned to the Night Edition palettes.
    enum Palette {
        private static func color(_ light: UInt32, _ a: UInt32, _ b: UInt32, _ c: UInt32) -> UIColor {
            .adaptive(Hex(light)) { palette in
                switch palette {
                case .nightEdition: Hex(a)
                case .darkroom: Hex(b)
                case .inkOnSlate: Hex(c)
                }
            }
        }

        static let land = color(0xEFE8DA, 0x1A1612, 0x170D0D, 0x16191C)
        static let green = color(0xE2E1C8, 0x1E1C16, 0x1A1210, 0x181D1C)
        static let water = color(0xC5D1CF, 0x0D0B09, 0x0D0606, 0x0C0E10)
        static let waterEdge = color(0x9DAFAC, 0x3A332B, 0x3F2626, 0x343A42)
        static let building = color(0xE0D5C1, 0x25201A, 0x231414, 0x20242A)
        static let path = color(0xE6DCC9, 0x29241E, 0x261717, 0x23272D)
        static let minor = color(0xFBF7EF, 0x332D26, 0x311E1E, 0x2C3138)
        static let major = color(0xFFFDF8, 0x433B32, 0x422828, 0x3A4048)
    }

    private let basemap: Basemap
    private let lock = NSLock()
    private var _style: UIUserInterfaceStyle = .light

    /// Appearance to draw in. MapKit draws on background threads, so it's lock-guarded.
    var style: UIUserInterfaceStyle {
        get { lock.withLock { _style } }
        set {
            lock.withLock { _style = newValue == .dark ? .dark : .light }
            setNeedsDisplay()
        }
    }

    init(overlay: BasemapOverlay) {
        basemap = overlay.basemap
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        // Overlay origin is the world origin, so renderer coordinates equal map points.
        let traits = UITraitCollection(userInterfaceStyle: style)
        func cg(_ color: UIColor) -> CGColor { color.resolvedColor(with: traits).cgColor }
        let screenPoint = 1 / zoomScale
        let meter = basemap.pointsPerMeter
        let margin = 40 * screenPoint
        let visible = mapRect.insetBy(dx: -margin, dy: -margin)

        context.setFillColor(cg(Palette.land))
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
            context.setFillColor(cg(Palette.green))
            context.fillPath(using: .evenOdd)
        }
        if addVisible(basemap.water) {
            context.setFillColor(cg(Palette.water))
            context.setStrokeColor(cg(Palette.waterEdge))
            context.setLineWidth(1.5 * screenPoint)
            context.drawPath(using: .eoFillStroke)
        }
        // Skip buildings when zoomed far out, where they'd only be noise.
        if zoomScale > 0.004, addVisible(basemap.buildings) {
            context.setFillColor(cg(Palette.building))
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
            context.setStrokeColor(cg(color))
            context.setLineWidth(max(minPoints * screenPoint, meters * meter))
            context.strokePath()
        }
    }
}
