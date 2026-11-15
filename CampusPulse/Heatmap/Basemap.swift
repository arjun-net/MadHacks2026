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

    /// Grid lookups so drawing a tile only touches the features near it.
    let waterIndex: FeatureIndex
    let greenIndex: FeatureIndex
    let buildingIndex: FeatureIndex
    let roadIndex: [RoadClass: FeatureIndex]

    private init(water: [Feature], green: [Feature], buildings: [Feature], roads: [RoadClass: [Feature]], pointsPerMeter: Double) {
        self.water = water
        self.green = green
        self.buildings = buildings
        self.roads = roads
        self.pointsPerMeter = pointsPerMeter
        let cell = pointsPerMeter * 300
        waterIndex = FeatureIndex(water, cellSize: cell)
        greenIndex = FeatureIndex(green, cellSize: cell)
        buildingIndex = FeatureIndex(buildings, cellSize: cell)
        roadIndex = roads.mapValues { FeatureIndex($0, cellSize: cell) }
    }

    /// Features bucketed into square cells. Features spanning many cells (lakes, big parks)
    /// are kept in a short list that every query includes.
    struct FeatureIndex {
        private let features: [Feature]
        private let cellSize: Double
        private var buckets: [Int64: [Int]] = [:]
        private var large: [Int] = []

        init(_ features: [Feature], cellSize: Double) {
            self.features = features
            self.cellSize = cellSize
            for (index, feature) in features.enumerated() {
                let (x0, y0, x1, y1) = cells(feature.bounds)
                if (x1 - x0 + 1) * (y1 - y0 + 1) > 64 {
                    large.append(index)
                    continue
                }
                for x in x0...x1 { for y in y0...y1 { buckets[key(x, y), default: []].append(index) } }
            }
        }

        /// Every feature whose bounds intersect `rect`, each once.
        func query(_ rect: MKMapRect) -> [Feature] {
            var seen = Set<Int>()
            var result: [Feature] = []
            for index in large where features[index].bounds.intersects(rect) {
                seen.insert(index)
                result.append(features[index])
            }
            let (x0, y0, x1, y1) = cells(rect)
            // A tile far zoomed out covers many cells; scanning everything is cheaper then.
            if (x1 - x0 + 1) * (y1 - y0 + 1) > buckets.count {
                return features.filter { $0.bounds.intersects(rect) }
            }
            for x in x0...x1 {
                for y in y0...y1 {
                    for index in buckets[key(x, y)] ?? [] where !seen.contains(index) {
                        seen.insert(index)
                        if features[index].bounds.intersects(rect) { result.append(features[index]) }
                    }
                }
            }
            return result
        }

        private func cells(_ rect: MKMapRect) -> (Int, Int, Int, Int) {
            (Int((rect.minX / cellSize).rounded(.down)), Int((rect.minY / cellSize).rounded(.down)),
             Int((rect.maxX / cellSize).rounded(.down)), Int((rect.maxY / cellSize).rounded(.down)))
        }

        private func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y))) }
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

/// The campus basemap as 256-point square tiles (the usual web map grid), drawn by the app
/// and shown by `MapCanvasView`.
///
/// Drawing a tile takes milliseconds, so the area around campus is drawn ahead of time
/// (`prefetch`) at every zoom level people use, and tiles are kept in memory and saved to the
/// Caches folder. After the first launch the whole map comes straight from storage.
final class BasemapTiles: @unchecked Sendable {
    static let tileSize: CGFloat = 256

    let basemap: Basemap
    private let lock = NSLock()
    private var _style: UIUserInterfaceStyle
    /// Encoded tiles, as saved on disk.
    private let tiles: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    /// Decoded tiles, ready to put on screen without any work.
    private let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()
    private var prefetchTask: Task<Void, Never>?
    /// Saved tiles for this campus. Bump `version` whenever the drawing or colors change.
    private let directory: URL
    private static let version = 2

    init(basemap: Basemap, campusID: String, style: UIUserInterfaceStyle) {
        self.basemap = basemap
        self._style = style == .dark ? .dark : .light
        self.directory = URL.cachesDirectory.appending(path: "basemap-tiles/\(campusID)-v\(Self.version)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.removeOldVersions(campusID: campusID, keeping: directory)
    }

    /// Tiles saved by earlier versions are never read again; free the space.
    private static func removeOldVersions(campusID: String, keeping current: URL) {
        let parent = current.deletingLastPathComponent()
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix("\(campusID)-v") && name != current.lastPathComponent {
            try? manager.removeItem(at: parent.appending(path: name))
        }
    }

    /// Appearance to draw in. Tiles load on background threads, so it's lock-guarded.
    var style: UIUserInterfaceStyle {
        get { lock.withLock { _style } }
        set { lock.withLock { _style = newValue == .dark ? .dark : .light } }
    }

    static func tileWidth(z: Int) -> Double {
        MKMapSize.world.width / pow(2, Double(z))
    }

    /// A decoded tile if it's already in memory; never does any work.
    func cachedImage(z: Int, x: Int, y: Int, scale: CGFloat, style: UIUserInterfaceStyle) -> CGImage? {
        images.object(forKey: key(z: z, x: x, y: y, scale: scale, style: style))
    }

    /// A decoded tile: from memory, the saved copy, or drawn now. Call off the main thread.
    func image(z: Int, x: Int, y: Int, scale: CGFloat, style: UIUserInterfaceStyle) -> CGImage? {
        let key = key(z: z, x: x, y: y, scale: scale, style: style)
        if let image = images.object(forKey: key) { return image }
        let data = tileData(z: z, x: x, y: y, scale: scale, style: style)
        guard let image = Self.decode(data) else { return nil }
        images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// One low-detail picture of a whole area, shown under the tiles so the map is never empty.
    /// `longSide` is the picture's longer edge in pixels.
    func overview(of rect: MKMapRect, style: UIUserInterfaceStyle, longSide: CGFloat = 2048) -> CGImage? {
        let name = "overview-\(style == .dark ? "d" : "l")-\(Int(rect.minX))-\(Int(rect.minY))-\(Int(rect.width))"
        let file = directory.appending(path: longSide == 2048 ? "\(name).jpg" : "\(name)-\(Int(longSide)).jpg")
        if let saved = try? Data(contentsOf: file), let image = Self.decode(saved) { return image }

        let zoomScale = longSide / max(rect.width, rect.height)
        let size = CGSize(width: (rect.width * zoomScale).rounded(), height: (rect.height * zoomScale).rounded())
        let data = render(rect, size: size, zoomScale: zoomScale, scale: 1, style: style)
        try? data.write(to: file, options: .atomic)
        return Self.decode(data)
    }

    /// Draws every tile covering each area at its zoom levels in the background, so they're
    /// ready before the map needs them. Restarting (new style) cancels the previous run.
    func prefetch(_ jobs: [(area: MKMapRect, zooms: ClosedRange<Int>)], scale: CGFloat) {
        let style = self.style
        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            for (rect, zooms) in jobs {
                for z in zooms {
                    let tileWidth = Self.tileWidth(z: z)
                    let xs = Int(rect.minX / tileWidth)...Int(rect.maxX / tileWidth)
                    let ys = Int(rect.minY / tileWidth)...Int(rect.maxY / tileWidth)
                    let paths = xs.flatMap { x in ys.map { (x, $0) } }
                    // Draw 16 tiles at a time across all cores, stopping early if cancelled.
                    for chunk in stride(from: 0, to: paths.count, by: 16) {
                        guard !Task.isCancelled, let self else { return }
                        let slice = paths[chunk..<min(chunk + 16, paths.count)]
                        DispatchQueue.concurrentPerform(iterations: slice.count) { i in
                            let (x, y) = slice[slice.startIndex + i]
                            // Already saved: nothing to do (it reads from disk in well under a millisecond).
                            guard !FileManager.default.fileExists(atPath: self.fileURL(z: z, x: x, y: y, scale: scale, style: style).path) else { return }
                            _ = self.tileData(z: z, x: x, y: y, scale: scale, style: style)
                        }
                    }
                }
            }
        }
    }

    private func key(z: Int, x: Int, y: Int, scale: CGFloat, style: UIUserInterfaceStyle) -> NSString {
        "\(style == .dark ? "d" : "l")/\(z)/\(x)/\(y)@\(scale)" as NSString
    }

    private func fileURL(z: Int, x: Int, y: Int, scale: CGFloat, style: UIUserInterfaceStyle) -> URL {
        directory.appending(path: "\(style == .dark ? "d" : "l")-\(z)-\(x)-\(y)@\(Int(scale))x.jpg")
    }

    /// A tile's encoded image: from memory, else from the saved copy, else drawn now (and saved).
    private func tileData(z: Int, x: Int, y: Int, scale: CGFloat, style: UIUserInterfaceStyle) -> Data {
        let key = key(z: z, x: x, y: y, scale: scale, style: style)
        if let cached = tiles.object(forKey: key) { return cached as Data }
        let file = fileURL(z: z, x: x, y: y, scale: scale, style: style)
        if let saved = try? Data(contentsOf: file) {
            tiles.setObject(saved as NSData, forKey: key, cost: saved.count)
            return saved
        }

        let tileWidth = Self.tileWidth(z: z)
        let mapRect = MKMapRect(x: Double(x) * tileWidth, y: Double(y) * tileWidth, width: tileWidth, height: tileWidth)
        let size = CGSize(width: Self.tileSize, height: Self.tileSize)
        let data = render(mapRect, size: size, zoomScale: Self.tileSize / tileWidth, scale: scale, style: style)
        tiles.setObject(data as NSData, forKey: key, cost: data.count)
        try? data.write(to: file, options: .atomic)
        return data
    }

    private func render(_ mapRect: MKMapRect, size: CGSize, zoomScale: Double, scale: CGFloat, style: UIUserInterfaceStyle) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        // JPEG: tiles are opaque, and it encodes and decodes several times faster than PNG.
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.9) { context in
            let cg = context.cgContext
            // Draw in map points: scale points to map points and move the rect's origin to 0,0.
            cg.scaleBy(x: zoomScale, y: zoomScale)
            cg.translateBy(x: -mapRect.origin.x, y: -mapRect.origin.y)
            BasemapPainter.draw(basemap, in: mapRect, zoomScale: zoomScale, style: style, context: cg)
        }
    }

    /// Decodes now, so putting the image on screen later costs nothing.
    private static func decode(_ data: Data) -> CGImage? {
        UIImage(data: data)?.preparingForDisplay()?.cgImage
    }

    deinit { prefetchTask?.cancel() }
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

        func addVisible(_ index: Basemap.FeatureIndex?) -> Bool {
            guard let index else { return false }
            let features = index.query(visible)
            for feature in features { context.addPath(feature.path) }
            return !features.isEmpty
        }

        if addVisible(basemap.greenIndex) {
            context.setFillColor(cg(BasemapPalette.green))
            context.fillPath(using: .evenOdd)
        }
        if addVisible(basemap.waterIndex) {
            context.setFillColor(cg(BasemapPalette.water))
            context.setStrokeColor(cg(BasemapPalette.waterEdge))
            context.setLineWidth(1.5 * screenPoint)
            context.drawPath(using: .eoFillStroke)
        }
        // Skip buildings when zoomed far out, where they'd only be noise.
        if zoomScale > 0.004, addVisible(basemap.buildingIndex) {
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
            guard addVisible(basemap.roadIndex[roadClass]) else { continue }
            context.setStrokeColor(cg(color))
            context.setLineWidth(max(minPoints * screenPoint, meters * meter))
            context.strokePath()
        }
    }
}
