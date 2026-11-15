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

/// Adaptive map colors: a printed-street-map look on cream (Day) and a warm dark
/// variant tuned to the Night Edition palettes.
enum BasemapPalette {
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

/// The campus basemap served to MapKit as tiles that replace Apple's map entirely.
///
/// A tile overlay with `canReplaceMapContent` stops MapKit from loading its own imagery,
/// so Apple's map (blue water, its labels) never shows through while tiles are drawing.
/// While zooming, MapKit keeps showing the previous zoom level's tiles until new ones are ready.
final class BasemapTileOverlay: MKTileOverlay, @unchecked Sendable {
    let basemap: Basemap
    private let lock = NSLock()
    private var _style: UIUserInterfaceStyle

    init(basemap: Basemap, style: UIUserInterfaceStyle) {
        self.basemap = basemap
        self._style = style == .dark ? .dark : .light
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 1
        maximumZ = 22
    }

    /// Appearance to draw in. Tiles load on background threads, so it's lock-guarded.
    /// After changing it, call `reloadData()` on the renderer to redraw.
    var style: UIUserInterfaceStyle {
        get { lock.withLock { _style } }
        set { lock.withLock { _style = newValue == .dark ? .dark : .light } }
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let tileWidth = MKMapSize.world.width / pow(2, Double(path.z))
        let mapRect = MKMapRect(x: Double(path.x) * tileWidth, y: Double(path.y) * tileWidth, width: tileWidth, height: tileWidth)
        let points = tileSize.width
        let zoomScale = points / tileWidth

        let format = UIGraphicsImageRendererFormat()
        format.scale = path.contentScaleFactor
        format.opaque = true
        let style = self.style
        let data = UIGraphicsImageRenderer(size: tileSize, format: format).pngData { context in
            let cg = context.cgContext
            // Draw in map points: scale tile points to map points and move the tile's origin to 0,0.
            cg.scaleBy(x: zoomScale, y: zoomScale)
            cg.translateBy(x: -mapRect.origin.x, y: -mapRect.origin.y)
            BasemapPainter.draw(basemap, in: mapRect, zoomScale: zoomScale, style: style, context: cg)
        }
        result(data, nil)
    }
}

/// Draws the basemap for a map rect into a context whose coordinates are map points.
enum BasemapPainter {
    static func draw(_ basemap: Basemap, in mapRect: MKMapRect, zoomScale: Double, style: UIUserInterfaceStyle, context: CGContext) {
        let traits = UITraitCollection(userInterfaceStyle: style)
        func cg(_ color: UIColor) -> CGColor { color.resolvedColor(with: traits).cgColor }
        let screenPoint = 1 / zoomScale
        let meter = basemap.pointsPerMeter
        let margin = 40 * screenPoint
        let visible = mapRect.insetBy(dx: -margin, dy: -margin)

        context.setFillColor(cg(BasemapPalette.land))
        context.fill(CGRect(x: mapRect.origin.x, y: mapRect.origin.y, width: mapRect.size.width, height: mapRect.size.height))

        func addVisible(_ features: [Basemap.Feature]) -> Bool {
            var added = false
            for feature in features where feature.bounds.intersects(visible) {
                context.addPath(feature.path)
                added = true
            }
            return added
        }

        if addVisible(basemap.green) {
            context.setFillColor(cg(BasemapPalette.green))
            context.fillPath(using: .evenOdd)
        }
        if addVisible(basemap.water) {
            context.setFillColor(cg(BasemapPalette.water))
            context.setStrokeColor(cg(BasemapPalette.waterEdge))
            context.setLineWidth(1.5 * screenPoint)
            context.drawPath(using: .eoFillStroke)
        }
        // Skip buildings when zoomed far out, where they'd only be noise.
        if zoomScale > 0.004, addVisible(basemap.buildings) {
            context.setFillColor(cg(BasemapPalette.building))
            context.fillPath(using: .evenOdd)
        }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        let roadStyles: [(Basemap.RoadClass, UIColor, minPoints: Double, meters: Double)] = [
            (.path, BasemapPalette.path, 0.6, 2),
            (.minor, BasemapPalette.minor, 1.2, 8),
            (.major, BasemapPalette.major, 2.0, 14),
        ]
        for (roadClass, color, minPoints, meters) in roadStyles {
            // Footpaths are hairlines when zoomed far out; skipping them keeps zoomed-out tiles quick.
            if roadClass == .path, zoomScale < 0.006 { continue }
            guard addVisible(basemap.roads[roadClass] ?? []) else { continue }
            context.setStrokeColor(cg(color))
            context.setLineWidth(max(minPoints * screenPoint, meters * meter))
            context.strokePath()
        }
    }
}
