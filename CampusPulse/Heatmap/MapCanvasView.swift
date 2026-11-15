import MapKit
import UIKit

/// The campus map and the heat layer, drawn by the app in one view that moves with MapKit's camera.
///
/// MapKit draws overlays in tiles and shows its grey-blue loading grid wherever a tile isn't
/// ready yet, which flashes while zooming. This view sits above MapKit's own map and below the
/// markers, and always has something to show:
/// - the land color everywhere,
/// - one low-detail picture of the whole area (a single texture that just scales with the camera),
/// - sharp tiles for the current zoom on top, with the previous zoom's tiles kept until the new
///   ones are all in.
/// MapKit still handles gestures, the camera limits and the markers.
final class MapCanvasView: UIView {
    private struct TileKey: Hashable {
        let z: Int, x: Int, y: Int
    }

    private weak var mapView: MKMapView?
    private let tiles: BasemapTiles?
    /// Layer geometry is in map points relative to this origin, which keeps the numbers small
    /// enough for Core Animation's single-precision math.
    private let origin: MKMapPoint
    private let overviewRect: MKMapRect

    private let world = CALayer()
    private let overviewLayer = CALayer()
    private let tileContainer = CALayer()
    /// Heat field image, set by `HeatmapAnimator`.
    let heatLayer = CALayer()

    private var shown: [TileKey: CALayer] = [:]
    private var loading: Set<TileKey> = []
    private var currentZoom = 0
    private var style: UIUserInterfaceStyle
    private var displayScale: CGFloat = 2
    private var displayLink: CADisplayLink?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// - Parameters:
    ///   - overviewRect: Area covered by the low-detail picture: everything the camera can show.
    ///   - heatBounds: Area the heat image stretches over.
    init(mapView: MKMapView, tiles: BasemapTiles?, overviewRect: MKMapRect, heatBounds: MKMapRect) {
        self.mapView = mapView
        self.tiles = tiles
        self.overviewRect = overviewRect
        self.origin = overviewRect.origin
        self.style = mapView.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        super.init(frame: mapView.bounds)
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = BasemapPalette.land
        accessibilityElementsHidden = true

        for layer in [world, overviewLayer, tileContainer, heatLayer] {
            layer.anchorPoint = .zero
            layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "opacity": NSNull()]
        }
        world.position = .zero
        world.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        layer.addSublayer(world)
        world.addSublayer(overviewLayer)
        world.addSublayer(tileContainer)
        world.addSublayer(heatLayer)
        overviewLayer.frame = worldRect(overviewRect)
        overviewLayer.magnificationFilter = .linear
        heatLayer.frame = worldRect(heatBounds)
        heatLayer.magnificationFilter = .linear

        loadOverview()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        displayLink?.invalidate()
        queue.cancelAllOperations()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sync()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scale = window?.screen.scale, scale != displayScale {
            displayScale = scale
            resetTiles()
        }
        sync()
    }

    // MARK: Camera tracking

    /// Follow the camera every frame while it moves.
    func cameraWillMove() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func cameraDidStop() {
        displayLink?.invalidate()
        displayLink = nil
        sync()
    }

    @objc private func step() { sync() }

    /// Lines the canvas up with MapKit's current camera and puts the right tiles on screen.
    func sync() {
        guard let mapView, bounds.width > 0 else { return }
        // Where two map points land on screen gives scale and offset (the map never rotates or tilts).
        let span = 100_000.0
        let a = mapView.convert(origin.coordinate, toPointTo: self)
        let b = mapView.convert(MKMapPoint(x: origin.x + span, y: origin.y + span).coordinate, toPointTo: self)
        let sx = (b.x - a.x) / span
        let sy = (b.y - a.y) / span
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        world.setAffineTransform(CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: a.x, ty: a.y))
        updateTiles(visible: MKMapRect(
            x: origin.x - a.x / sx, y: origin.y - a.y / sy,
            width: bounds.width / sx, height: bounds.height / sy
        ), pointsPerMapPoint: sx)
        CATransaction.commit()
    }

    // MARK: Appearance

    func setStyle(_ newStyle: UIUserInterfaceStyle) {
        let resolved: UIUserInterfaceStyle = newStyle == .dark ? .dark : .light
        guard resolved != style else { return }
        style = resolved
        overviewLayer.contents = nil
        loadOverview()
        resetTiles()
        sync()
    }

    private func loadOverview() {
        guard let tiles else { return }
        let style = self.style
        let rect = overviewRect
        queue.addOperation { [weak self] in
            let image = tiles.overview(of: rect, style: style)
            DispatchQueue.main.async {
                guard let self, self.style == style else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.overviewLayer.contents = image
                CATransaction.commit()
            }
        }
    }

    // MARK: Tiles

    private func resetTiles() {
        shown.values.forEach { $0.removeFromSuperlayer() }
        shown.removeAll()
        loading.removeAll()
    }

    private func updateTiles(visible: MKMapRect, pointsPerMapPoint: Double) {
        guard let tiles else { return }
        // Tiles shown between 0.8x and 1.6x their drawn size: sharp, and not too many of them.
        let ideal = log2(MKMapSize.world.width * pointsPerMapPoint / BasemapTiles.tileSize)
        let z = min(20, max(8, Int((ideal + 0.7).rounded(.down))))
        currentZoom = z

        let tileWidth = BasemapTiles.tileWidth(z: z)
        let area = visible.insetBy(dx: -tileWidth * 0.25, dy: -tileWidth * 0.25)
        let maxIndex = Int(pow(2, Double(z))) - 1
        let xs = max(0, Int(area.minX / tileWidth))...min(maxIndex, Int(area.maxX / tileWidth))
        let ys = max(0, Int(area.minY / tileWidth))...min(maxIndex, Int(area.maxY / tileWidth))
        var wanted = Set<TileKey>()
        for x in xs { for y in ys { wanted.insert(TileKey(z: z, x: x, y: y)) } }

        for key in wanted where shown[key] == nil {
            if let image = tiles.cachedImage(z: key.z, x: key.x, y: key.y, scale: displayScale, style: style) {
                show(image, for: key)
            } else {
                load(key)
            }
        }
        prune(wanted: wanted, visible: area)
    }

    private func load(_ key: TileKey) {
        guard let tiles, !loading.contains(key) else { return }
        loading.insert(key)
        let style = self.style
        let scale = displayScale
        queue.addOperation { [weak self] in
            let image = tiles.image(z: key.z, x: key.x, y: key.y, scale: scale, style: style)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(key)
                guard let image, self.style == style, self.displayScale == scale,
                      key.z == self.currentZoom, self.shown[key] == nil else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.show(image, for: key)
                CATransaction.commit()
                self.sync()
            }
        }
    }

    private func show(_ image: CGImage, for key: TileKey) {
        let tileWidth = BasemapTiles.tileWidth(z: key.z)
        // A hair of overlap so neighbouring tiles never leave a seam.
        let overlap = tileWidth / 512
        let rect = MKMapRect(x: Double(key.x) * tileWidth, y: Double(key.y) * tileWidth, width: tileWidth, height: tileWidth)
            .insetBy(dx: -overlap, dy: -overlap)
        let layer = CALayer()
        layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "zPosition": NSNull()]
        layer.contents = image
        layer.frame = worldRect(rect)
        // Sharper (closer) zoom levels sit on top of coarser ones.
        layer.zPosition = CGFloat(key.z)
        tileContainer.addSublayer(layer)
        shown[key] = layer
    }

    /// Drops tiles that are off screen, and other zoom levels once the current one covers the screen.
    private func prune(wanted: Set<TileKey>, visible: MKMapRect) {
        let complete = wanted.allSatisfy { shown[$0] != nil }
        for (key, layer) in shown where !wanted.contains(key) {
            let tileWidth = BasemapTiles.tileWidth(z: key.z)
            let rect = MKMapRect(x: Double(key.x) * tileWidth, y: Double(key.y) * tileWidth, width: tileWidth, height: tileWidth)
            if complete || !rect.intersects(visible) || shown.count > 400 {
                layer.removeFromSuperlayer()
                shown[key] = nil
            }
        }
    }

    private func worldRect(_ rect: MKMapRect) -> CGRect {
        CGRect(x: rect.minX - origin.x, y: rect.minY - origin.y, width: rect.width, height: rect.height)
    }
}

extension MKMapView {
    /// Puts the canvas above MapKit's own map and below the markers.
    func installCanvas(_ canvas: MapCanvasView) {
        let content = subviews.first { String(describing: type(of: $0)).contains("MapContentView") } ?? self
        canvas.frame = content.bounds
        if let markers = content.subviews.first(where: { String(describing: type(of: $0)).contains("AnnotationContainer") }) {
            content.insertSubview(canvas, belowSubview: markers)
        } else if let map = content.subviews.first {
            content.insertSubview(canvas, aboveSubview: map)
        } else {
            content.addSubview(canvas)
        }
        (self as? LayoutAwareMapView)?.canvas = canvas
    }
}
