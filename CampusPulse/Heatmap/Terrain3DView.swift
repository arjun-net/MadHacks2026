import CoreLocation
import MapKit
import Metal
import SceneKit
import SwiftUI
import UIKit

/// The 3D campus: the map laid out as tilted ground, with the heat field raised into one
/// continuous, lit surface, so busy places stand up as red mountains. Place markers float on
/// their peaks and stay tappable.
///
/// Drag to move, pinch to zoom, twist to turn. The tilt is fixed.
struct Campus3DMapView: UIViewRepresentable {
    let campus: Campus
    let snapshot: CampusSnapshot?
    let isHeatmapVisible: Bool
    let selectedAreaID: String?
    let recenterToken: Int
    /// Space covered by floating chrome, so campus is framed in the open middle.
    var contentInsets = UIEdgeInsets(top: 190, left: 14, bottom: 140, right: 14)
    var onSelectArea: (String?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(recenterToken: recenterToken) }

    func makeUIView(context: Context) -> Terrain3DView {
        let view = Terrain3DView(campus: campus)
        view.contentInsets = contentInsets
        update(view)
        return view
    }

    func updateUIView(_ view: Terrain3DView, context: Context) {
        update(view)
        if context.coordinator.recenterToken != recenterToken {
            context.coordinator.recenterToken = recenterToken
            view.recenter(animated: true)
        }
    }

    private func update(_ view: Terrain3DView) {
        view.onSelectArea = onSelectArea
        if let snapshot, snapshot.campusID == campus.id { view.apply(snapshot) }
        view.setHeatVisible(isHeatmapVisible)
        view.setSelectedArea(selectedAreaID)
    }

    static func dismantleUIView(_ view: Terrain3DView, coordinator: Coordinator) {
        view.stop()
    }

    final class Coordinator {
        var recenterToken: Int
        init(recenterToken: Int) { self.recenterToken = recenterToken }
    }
}

final class Terrain3DView: UIView, CLLocationManagerDelegate, UIGestureRecognizerDelegate {
    let campus: Campus
    var onSelectArea: (String?) -> Void = { _ in }
    var contentInsets = UIEdgeInsets(top: 190, left: 14, bottom: 140, right: 14) {
        didSet { setNeedsLayout() }
    }

    // MARK: Scene

    /// The scene is drawn by us, once per screen refresh, in the same update that moves the
    /// markers; SceneKit's own view draws on a separate schedule, so peaks and markers drifted
    /// a frame apart while moving.
    private let sceneView = MetalLayerView()
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var renderer = SCNRenderer(device: device, options: nil)
    private lazy var commandQueue = device?.makeCommandQueue()
    private var colorTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private static let sampleCount = 4
    private var needsRender = true
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    /// Fixed lens; the projection is rebuilt from it to shift campus below the masthead.
    private let lens: SCNCamera = {
        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 5
        camera.zFar = 60_000
        return camera
    }()
    private let nearGround = SCNNode()
    private let farGround = SCNNode()
    private let terrain = SCNNode()
    private let overlay = PassthroughView()
    private var markers: [String: AreaAnnotationView] = [:]
    private var levels: [String: ActivityLevel] = [:]
    private let userDot = UserDotView()

    // MARK: Geography (scene units are meters: x east, z south, y up)

    private let origin: MKMapPoint
    private let pointsPerMeter: Double
    private let heatBounds: MKMapRect
    /// Where the camera may look: the same limits as the flat map.
    private let cameraLimits: MKMapRect
    private let nearRect: MKMapRect
    private let farRect: MKMapRect
    /// Peak height for the busiest spot.
    private let maxHeight: Float

    // MARK: State

    private var style: UIUserInterfaceStyle = .light
    private var tiles: BasemapTiles?
    private var grid: HeatmapGrid?
    private var snapshotDate: Date?
    private var gridTask: Task<Void, Never>?
    private var selectedAreaID: String?
    private var heatVisible = true
    /// 0 = flat, 1 = full height. Animates so mountains rise and sink.
    private var heightScale: Float = 0
    private var heightTarget: Float = 1
    private var hasFramedCampus = false
    /// Camera distance when campus is framed; mountains are drawn full height there.
    private var referenceDistance: Float = 3000

    // MARK: Camera

    private struct CameraState {
        var target: SIMD2<Float>
        var distance: Float
        var heading: Float
    }

    private var camera = CameraState(target: .zero, distance: 3000, heading: 0)
    /// Angle from straight down.
    private let pitch: Float = 54 * .pi / 180
    private let distanceRange: ClosedRange<Float> = 300...6500
    private var velocity = SIMD2<Float>.zero
    private var cameraAnimation: (from: CameraState, to: CameraState, start: CFTimeInterval, duration: CFTimeInterval)?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var lastPanLocation: CGPoint?
    private var lastPinchLocation: CGPoint?

    private let locationManager = CLLocationManager()
    private var userLocation: CLLocationCoordinate2D?

    init(campus: Campus) {
        self.campus = campus
        let focus = campus.focusRect
        origin = MKMapPoint(x: focus.midX, y: focus.midY)
        pointsPerMeter = MKMapPointsPerMeterAtLatitude(campus.center.latitude)
        heatBounds = campus.heatmapBounds
        let limits = campus.boundaryRect.union(focus).insetBy(dx: -focus.width, dy: -focus.height * 1.5)
        cameraLimits = limits
        nearRect = limits.insetBy(dx: -limits.width * 0.1, dy: -limits.height * 0.1)
        farRect = limits.insetBy(dx: -limits.width * 0.5, dy: -limits.height * 0.5)
        maxHeight = Float(heatBounds.width / pointsPerMeter * 0.17)
        super.init(frame: .zero)
        style = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        setUpScene()
        setUpMarkers()
        setUpGestures()
        loadBasemap()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Terrain3DView, _: UITraitCollection) in
            view.styleDidChange()
        }
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        gridTask?.cancel()
        locationManager.stopUpdatingLocation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
            locationManager.stopUpdatingLocation()
        } else {
            startLocationIfAllowed()
            setNeedsRender()
        }
    }

    // MARK: Setup

    private func setUpScene() {
        backgroundColor = BasemapPalette.land
        let metalLayer = sceneView.metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = true
        // Show each frame in the same screen update as the marker positions.
        metalLayer.presentsWithTransaction = true
        sceneView.isOpaque = true
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(sceneView)
        renderer.scene = scene

        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(overlay)

        cameraNode.camera = SCNCamera()
        scene.rootNode.addChildNode(cameraNode)
        renderer.pointOfView = cameraNode

        for (node, rect, order) in [(farGround, farRect, -20), (nearGround, nearRect, -10)] {
            let plane = SCNPlane(width: CGFloat(rect.width / pointsPerMeter), height: CGFloat(rect.height / pointsPerMeter))
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = BasemapPalette.land.resolvedColor(with: traitCollection)
            material.diffuse.mipFilter = .linear
            material.diffuse.maxAnisotropy = 16
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            plane.materials = [material]
            node.geometry = plane
            // SCNPlane stands in x/y; lay it flat with the image's top edge to the north.
            node.eulerAngles.x = -.pi / 2
            node.position = scenePoint(MKMapPoint(x: rect.midX, y: rect.midY))
            node.renderingOrder = order
            scene.rootNode.addChildNode(node)
        }

        terrain.castsShadow = false
        scene.rootNode.addChildNode(terrain)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1350
        // Low from the south-west: slopes facing the camera catch light, the far sides fall into shade.
        sun.eulerAngles = SCNVector3(-0.55, -0.9, 0)
        scene.rootNode.addChildNode(sun)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 230
        scene.rootNode.addChildNode(fill)

        applySceneColors()
    }

    private func setUpMarkers() {
        for area in campus.areas {
            let view = AreaAnnotationView(annotation: nil, reuseIdentifier: nil)
            view.configure(area: area, level: nil, highlighted: false)
            view.isUserInteractionEnabled = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(markerTapped(_:)))
            view.addGestureRecognizer(tap)
            view.accessibilityIdentifier = area.id
            overlay.addSubview(view)
            markers[area.id] = view
        }
        userDot.isHidden = true
        overlay.addSubview(userDot)
    }

    private func setUpGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        for gesture in [pan, pinch, rotate] as [UIGestureRecognizer] {
            gesture.delegate = self
            sceneView.addGestureRecognizer(gesture)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        sceneView.metalLayer.contentsScale = scale
        sceneView.metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        updateProjection()
        if !hasFramedCampus {
            hasFramedCampus = true
            camera = framedCampus()
            referenceDistance = camera.distance
        }
        applyCamera()
    }

    /// The lens, shifted down so the point the camera looks at sits in the middle of the open
    /// area between the masthead and the bottom chrome.
    private func updateProjection() {
        var projection = lens.projectionTransform(withViewportSize: bounds.size)
        let shift = Float(-(contentInsets.top - contentInsets.bottom) / bounds.height)
        projection.m32 += shift * projection.m34
        projection.m42 += shift * projection.m44
        cameraNode.camera?.projectionTransform = projection
    }

    // MARK: Data in

    func apply(_ snapshot: CampusSnapshot) {
        guard snapshot.generatedAt != snapshotDate else { return }
        snapshotDate = snapshot.generatedAt
        for activity in snapshot.areas { levels[activity.id] = activity.level }
        refreshMarkers()

        let cells = snapshot.cells
        let bounds = heatBounds
        let origin = origin
        let pointsPerMeter = pointsPerMeter
        let maxHeight = maxHeight
        gridTask?.cancel()
        gridTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { () -> (HeatmapGrid, SCNGeometry) in
                let grid = HeatmapGrid.render(cells: cells, in: bounds, width: 260)
                let geometry = Self.terrainGeometry(grid: grid, bounds: bounds, origin: origin, pointsPerMeter: pointsPerMeter, maxHeight: maxHeight)
                return (grid, geometry)
            }.value
            guard !Task.isCancelled, let self else { return }
            let firstTime = self.grid == nil
            self.grid = built.0
            built.1.materials = [self.terrainMaterial()]
            self.terrain.geometry = built.1
            if firstTime {
                // Mountains rise in when the 3D view first appears.
                self.heightScale = 0
                self.terrain.scale = SCNVector3(1, 0.001, 1)
                self.startTicking()
            }
            self.applyCamera()
        }
    }

    func setHeatVisible(_ visible: Bool) {
        guard visible != heatVisible else { return }
        heatVisible = visible
        heightTarget = visible ? 1 : 0
        startTicking()
    }

    func setSelectedArea(_ id: String?) {
        guard id != selectedAreaID else { return }
        selectedAreaID = id
        refreshMarkers()
        if let id, let area = campus.area(withID: id) {
            let point = scenePoint(MKMapPoint(area.coordinate.clCoordinate))
            var to = camera
            to.target = SIMD2(point.x, point.z)
            to.distance = 1500
            animateCamera(to: to)
        }
    }

    func recenter(animated: Bool) {
        let to = framedCampus()
        if animated { animateCamera(to: to) } else { camera = to; applyCamera() }
    }

    private func refreshMarkers() {
        for area in campus.areas {
            markers[area.id]?.configure(area: area, level: levels[area.id], highlighted: area.id == selectedAreaID)
        }
        updateOverlay()
    }

    @objc private func markerTapped(_ gesture: UITapGestureRecognizer) {
        guard let id = gesture.view?.accessibilityIdentifier else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSelectArea(id)
    }

    // MARK: Basemap textures

    private func loadBasemap() {
        let campus = campus
        Task { [weak self] in
            let basemap = await Task.detached(priority: .userInitiated) { Basemap.forCampus(campus) }.value
            guard let self, let basemap else { return }
            self.tiles = BasemapTiles(basemap: basemap, campusID: campus.id, style: self.style)
            self.loadGroundTextures()
        }
    }

    private func loadGroundTextures() {
        guard let tiles else { return }
        let style = style
        let near = nearRect, far = farRect
        Task { [weak self] in
            let images = await Task.detached(priority: .userInitiated) {
                (tiles.overview(of: far, style: style), tiles.overview(of: near, style: style, longSide: 4096))
            }.value
            guard let self, self.style == style else { return }
            self.farGround.geometry?.firstMaterial?.diffuse.contents = images.0
            self.nearGround.geometry?.firstMaterial?.diffuse.contents = images.1
            self.setNeedsRender()
        }
    }

    private func styleDidChange() {
        let resolved: UIUserInterfaceStyle = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        guard resolved != style else { return }
        style = resolved
        tiles?.style = resolved
        applySceneColors()
        terrain.geometry?.materials = [terrainMaterial()]
        loadGroundTextures()
        setNeedsRender()
    }

    private func applySceneColors() {
        let land = BasemapPalette.land.resolvedColor(with: traitCollection)
        backgroundColor = land
        scene.background.contents = land
        scene.fogColor = land
        // Until the map pictures load, the ground is plain land color.
        for node in [nearGround, farGround] where node.geometry?.firstMaterial?.diffuse.contents is UIColor {
            node.geometry?.firstMaterial?.diffuse.contents = land
        }
    }

    // MARK: Terrain

    /// Color and opacity by height: the flat base fades into the map, flanks warm up, peaks go deep red.
    private func terrainMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = Self.rampImage(style: style)
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.diffuse.magnificationFilter = .linear
        if style == .dark {
            // A faint glow so peaks read against the night map.
            material.emission.contents = Self.rampImage(style: style, glow: true)
            material.emission.wrapS = .clamp
            material.emission.wrapT = .clamp
        }
        material.blendMode = .alpha
        material.isDoubleSided = true
        return material
    }

    private static func rampStops(style: UIUserInterfaceStyle) -> [HeatPalette.Stop] {
        style == .dark
            ? [
                .init(location: 0.00, hex: 0x6A2414),
                .init(location: 0.30, hex: 0xB3361F),
                .init(location: 0.60, hex: 0xE04A2C),
                .init(location: 0.85, hex: 0xF0563A),
                .init(location: 1.00, hex: 0xFF7A55),
            ]
            : [
                .init(location: 0.00, hex: 0xEDB46E),
                .init(location: 0.30, hex: 0xE07A3E),
                .init(location: 0.60, hex: 0xC8321F),
                .init(location: 0.85, hex: 0x9E0A0A),
                .init(location: 1.00, hex: 0x6E0008),
            ]
    }

    private static func rampImage(style: UIUserInterfaceStyle, glow: Bool = false) -> CGImage? {
        let stops = rampStops(style: style)
        let width = 256
        var pixels = [UInt8](repeating: 0, count: width * 4)
        for i in 0..<width {
            let t = Double(i) / Double(width - 1)
            let upper = stops.firstIndex { $0.location >= t } ?? stops.count - 1
            let lower = max(0, upper - 1)
            let a = stops[lower], b = stops[upper]
            let f = b.location > a.location ? (t - a.location) / (b.location - a.location) : 0
            let rgb = (a.red + (b.red - a.red) * f, a.green + (b.green - a.green) * f, a.blue + (b.blue - a.blue) * f)
            // Invisible at zero, solid from about a fifth of the way up.
            let edge = min(1, max(0, (t - 0.015) / 0.2))
            var alpha = edge * edge * (3 - 2 * edge) * (style == .dark ? 0.97 : 0.94)
            var gain = 1.0
            if glow { gain = 0.06 + 0.16 * t; alpha = 1 }
            pixels[i * 4 + 0] = UInt8(min(255, rgb.0 * gain * alpha * 255))
            pixels[i * 4 + 1] = UInt8(min(255, rgb.1 * gain * alpha * 255))
            pixels[i * 4 + 2] = UInt8(min(255, rgb.2 * gain * alpha * 255))
            pixels[i * 4 + 3] = UInt8(alpha * 255)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    nonisolated private static func shapedHeight(_ value: Float, maxHeight: Float) -> Float {
        maxHeight * pow(max(0, value), 1.35)
    }

    /// A height field over the heat bounds: one vertex per grid sample, lit with real normals.
    /// The texture coordinate carries the density, which picks the color from the ramp.
    nonisolated private static func terrainGeometry(grid: HeatmapGrid, bounds: MKMapRect, origin: MKMapPoint, pointsPerMeter: Double, maxHeight: Float) -> SCNGeometry {
        let cols = grid.width, rows = grid.height
        let x0 = Float((bounds.minX - origin.x) / pointsPerMeter)
        let z0 = Float((bounds.minY - origin.y) / pointsPerMeter)
        let dx = Float(bounds.width / pointsPerMeter) / Float(cols - 1)
        let dz = Float(bounds.height / pointsPerMeter) / Float(rows - 1)
        func value(_ x: Int, _ y: Int) -> Float {
            grid.values[min(rows - 1, max(0, y)) * cols + min(cols - 1, max(0, x))]
        }
        func height(_ x: Int, _ y: Int) -> Float { shapedHeight(value(x, y), maxHeight: maxHeight) }

        var positions = [SIMD3<Float>](), normals = [SIMD3<Float>](), uvs = [SIMD2<Float>]()
        positions.reserveCapacity(cols * rows)
        normals.reserveCapacity(cols * rows)
        uvs.reserveCapacity(cols * rows)
        for y in 0..<rows {
            for x in 0..<cols {
                let v = value(x, y)
                // Lifted a hair so the flat base never fights the ground.
                positions.append(SIMD3(x0 + Float(x) * dx, height(x, y) + 0.6, z0 + Float(y) * dz))
                let n = SIMD3<Float>((height(x - 1, y) - height(x + 1, y)) / (2 * dx), 1, (height(x, y - 1) - height(x, y + 1)) / (2 * dz))
                normals.append(simd_normalize(n))
                uvs.append(SIMD2(min(1, v), 0.5))
            }
        }

        var indices = [UInt32]()
        indices.reserveCapacity((cols - 1) * (rows - 1) * 6)
        for y in 0..<(rows - 1) {
            for x in 0..<(cols - 1) {
                let i = UInt32(y * cols + x)
                // Skip flat, empty quads entirely.
                if max(value(x, y), value(x + 1, y), value(x, y + 1), value(x + 1, y + 1)) < 0.012 { continue }
                let below = i + UInt32(cols)
                indices += [i, below, i + 1, i + 1, below, below + 1]
            }
        }

        func source<T>(_ array: [T], semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
            let data = array.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(
                data: data, semantic: semantic, vectorCount: array.count, usesFloatComponents: true,
                componentsPerVector: components, bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0, dataStride: MemoryLayout<T>.stride
            )
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(
            sources: [
                source(positions, semantic: .vertex, components: 3),
                source(normals, semantic: .normal, components: 3),
                source(uvs, semantic: .texcoord, components: 2),
            ],
            elements: [element]
        )
    }

    /// Height of the heat surface at a map point, as currently drawn.
    private func surfaceHeight(at point: MKMapPoint) -> Float {
        guard let grid, heatBounds.contains(point) else { return 0 }
        let fx = (point.x - heatBounds.minX) / heatBounds.width * Double(grid.width - 1)
        let fy = (point.y - heatBounds.minY) / heatBounds.height * Double(grid.height - 1)
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, grid.width - 1), y1 = min(y0 + 1, grid.height - 1)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        func v(_ x: Int, _ y: Int) -> Float { grid.values[y * grid.width + x] }
        let top = v(x0, y0) + (v(x1, y0) - v(x0, y0)) * tx
        let bottom = v(x0, y1) + (v(x1, y1) - v(x0, y1)) * tx
        return Self.shapedHeight(top + (bottom - top) * ty, maxHeight: maxHeight) * verticalScale
    }

    private var easedHeightScale: Float { heightScale * heightScale * (3 - 2 * heightScale) }

    /// Mountains shrink as you zoom in, so a peak never fills the screen, and grow a little
    /// zoomed out so they still read from afar.
    private var zoomHeightFactor: Float {
        min(1.15, max(0.45, camera.distance / referenceDistance))
    }

    private var verticalScale: Float { easedHeightScale * zoomHeightFactor }

    // MARK: Camera

    private func scenePoint(_ point: MKMapPoint, height: Float = 0) -> SCNVector3 {
        SCNVector3(Float((point.x - origin.x) / pointsPerMeter), height, Float((point.y - origin.y) / pointsPerMeter))
    }

    /// Campus filling the open part of the screen, facing north.
    private func framedCampus() -> CameraState {
        let focus = campus.focusRect
        let widthMeters = Float(focus.width / pointsPerMeter)
        let aspect = Float(max(bounds.width, 1) / max(bounds.height, 1))
        let halfWidthTan = aspect * tan(Float(lens.fieldOfView) * .pi / 360)
        let distance = widthMeters / (2 * halfWidthTan) * 1.25
        let center = scenePoint(MKMapPoint(x: focus.midX, y: focus.midY))
        return CameraState(target: SIMD2(center.x, center.z), distance: min(distanceRange.upperBound, max(distanceRange.lowerBound, distance)), heading: 0)
    }

    private func clamped(_ state: CameraState) -> CameraState {
        var state = state
        let minX = Float((cameraLimits.minX - origin.x) / pointsPerMeter), maxX = Float((cameraLimits.maxX - origin.x) / pointsPerMeter)
        let minZ = Float((cameraLimits.minY - origin.y) / pointsPerMeter), maxZ = Float((cameraLimits.maxY - origin.y) / pointsPerMeter)
        state.target.x = min(maxX, max(minX, state.target.x))
        state.target.y = min(maxZ, max(minZ, state.target.y))
        state.distance = min(distanceRange.upperBound, max(distanceRange.lowerBound, state.distance))
        return state
    }

    private func applyCamera() {
        camera = clamped(camera)
        let horizontal = camera.distance * sin(pitch)
        // Heading 0 looks north (-z); the camera sits south of its target.
        let offset = SIMD3<Float>(sin(camera.heading) * horizontal, camera.distance * cos(pitch), cos(camera.heading) * horizontal)
        let target = SCNVector3(camera.target.x, 0, camera.target.y)
        cameraNode.position = SCNVector3(target.x + offset.x, offset.y, target.z + offset.z)
        cameraNode.look(at: target, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        terrain.scale = SCNVector3(1, max(0.001, verticalScale), 1)
        // Shown while heat is on or the mountains are still sinking away.
        terrain.isHidden = grid == nil || !(heatVisible || heightScale > 0.02)
        scene.fogStartDistance = CGFloat(camera.distance * 1.1)
        scene.fogEndDistance = CGFloat(camera.distance * 3.2)
        setNeedsRender()
    }

    /// Draws on the next screen refresh (at most once per refresh, however many touches arrive).
    private func setNeedsRender() {
        needsRender = true
        startTicking()
    }

    /// False when the frame couldn't be drawn yet (no drawable available), so it's tried again.
    @discardableResult
    private func renderFrame() -> Bool {
        // Nothing to draw into until there's a size; layout asks for a frame once there is.
        guard let device, let commandQueue, bounds.width > 0, bounds.height > 0 else { return true }
        let metalLayer = sceneView.metalLayer
        guard metalLayer.drawableSize.width > 0, let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        let width = drawable.texture.width, height = drawable.texture.height
        if colorTexture?.width != width || colorTexture?.height != height {
            let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: metalLayer.pixelFormat, width: width, height: height, mipmapped: false)
            color.textureType = .type2DMultisample
            color.sampleCount = Self.sampleCount
            color.usage = .renderTarget
            color.storageMode = .private
            colorTexture = device.makeTexture(descriptor: color)
            let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: width, height: height, mipmapped: false)
            depth.textureType = .type2DMultisample
            depth.sampleCount = Self.sampleCount
            depth.usage = .renderTarget
            depth.storageMode = .private
            depthTexture = device.makeTexture(descriptor: depth)
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].resolveTexture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = depthTexture
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare

        renderer.render(atTime: CACurrentMediaTime(), viewport: CGRect(x: 0, y: 0, width: width, height: height), commandBuffer: commandBuffer, passDescriptor: pass)
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
        return true
    }

    // MARK: Projection (done here rather than by SceneKit, so it matches the frame being drawn)

    private var viewProjection: simd_float4x4 {
        simd_float4x4(cameraNode.camera?.projectionTransform ?? SCNMatrix4Identity) * cameraNode.simdWorldTransform.inverse
    }

    /// Screen position of a scene point and its distance from the camera, or nil behind it.
    private func project(_ point: SCNVector3, using matrix: simd_float4x4) -> (point: CGPoint, depth: Float)? {
        let clip = matrix * SIMD4<Float>(point.x, point.y, point.z, 1)
        guard clip.w > 1 else { return nil }
        let x = clip.x / clip.w, y = clip.y / clip.w
        return (CGPoint(x: CGFloat(x + 1) / 2 * bounds.width, y: CGFloat(1 - y) / 2 * bounds.height), clip.w)
    }

    /// Where a screen point lands on the ground, or nil above the horizon.
    private func groundPoint(_ point: CGPoint) -> SIMD2<Float>? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let x = Float(point.x / bounds.width) * 2 - 1
        let y = 1 - Float(point.y / bounds.height) * 2
        // Any depth inside the view works: it's just a second point on the ray through the pixel.
        let q = viewProjection.inverse * SIMD4<Float>(x, y, 0.5, 1)
        let eye = cameraNode.simdWorldPosition
        let direction = SIMD3<Float>(q.x, q.y, q.z) / q.w - eye
        guard direction.y < -1e-5 else { return nil }
        let t = -eye.y / direction.y
        return SIMD2(eye.x + direction.x * t, eye.z + direction.z * t)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: sceneView)
        switch gesture.state {
        case .began:
            cameraAnimation = nil
            velocity = .zero
            lastPanLocation = location
        case .changed:
            if let last = lastPanLocation, let from = groundPoint(last), let to = groundPoint(location) {
                camera.target += from - to
                applyCamera()
            }
            lastPanLocation = location
        case .ended:
            // Keep gliding in the direction of the flick.
            let v = gesture.velocity(in: sceneView)
            let ahead = CGPoint(x: location.x - v.x * 0.05, y: location.y - v.y * 0.05)
            if let a = groundPoint(location), let b = groundPoint(ahead) {
                // A short, quick glide: stops in about a third of a second.
                velocity = (b - a) / 0.05 * 0.6
                startTicking()
            }
            lastPanLocation = nil
        default:
            lastPanLocation = nil
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .began else { return }
        cameraAnimation = nil
        velocity = .zero
        let location = gesture.location(in: sceneView)
        let before = groundPoint(location)
        camera.distance /= Float(gesture.scale)
        gesture.scale = 1
        applyCamera()
        // Zoom toward the fingers: keep the ground under them in place.
        if let before, let after = groundPoint(location) {
            camera.target += before - after
            applyCamera()
        }
    }

    @objc private func handleRotate(_ gesture: UIRotationGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .began else { return }
        cameraAnimation = nil
        // A clockwise twist (positive rotation) turns the map clockwise, following the fingers.
        camera.heading += Float(gesture.rotation)
        gesture.rotation = 0
        applyCamera()
    }

    private func animateCamera(to state: CameraState, duration: CFTimeInterval = 0.4) {
        velocity = .zero
        var to = clamped(state)
        // Turn the short way round.
        let turn = remainder(to.heading - camera.heading, 2 * .pi)
        to.heading = camera.heading + turn
        cameraAnimation = (camera, to, CACurrentMediaTime(), duration)
        startTicking()
    }

    // MARK: Frame loop (camera glide, animations, rising mountains)

    private func startTicking() {
        guard displayLink == nil, window != nil else {
            if window == nil { heightScale = heightTarget }
            return
        }
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, now - lastTick))
        lastTick = now
        var active = false

        if let animation = cameraAnimation {
            let t = min(1, (now - animation.start) / animation.duration)
            let e = Float(1 - pow(1 - t, 3))
            camera.target = animation.from.target + (animation.to.target - animation.from.target) * e
            camera.distance = animation.from.distance * pow(animation.to.distance / animation.from.distance, e)
            camera.heading = animation.from.heading + (animation.to.heading - animation.from.heading) * e
            if t >= 1 { cameraAnimation = nil } else { active = true }
        } else if simd_length(velocity) > 8 {
            camera.target += velocity * dt
            velocity *= exp(-9 * dt)
            active = true
        }

        if heightScale != heightTarget {
            let step = dt / 0.5
            heightScale = heightTarget > heightScale ? min(heightTarget, heightScale + step) : max(heightTarget, heightScale - step)
            active = active || heightScale != heightTarget
        }

        if active || needsRender {
            applyCamera()
            let drawn = renderFrame()
            updateOverlay()
            needsRender = !drawn
        }
        if !active && !needsRender {
            link.invalidate()
            displayLink = nil
        }
    }

    // MARK: Markers

    /// Puts each marker on top of its mountain. Busier and selected places win when labels overlap.
    private func updateOverlay() {
        guard bounds.width > 0 else { return }
        let lift: Float = heatVisible ? 1 : 0
        let order = campus.areas.sorted {
            if ($0.id == selectedAreaID) != ($1.id == selectedAreaID) { return $0.id == selectedAreaID }
            return $0.popularity > $1.popularity
        }
        let matrix = viewProjection
        var placed: [CGRect] = []
        for area in order {
            guard let view = markers[area.id] else { continue }
            let mapPoint = MKMapPoint(area.coordinate.clCoordinate)
            let projected = project(scenePoint(mapPoint, height: surfaceHeight(at: mapPoint) * lift + 4), using: matrix)
            guard let projected else { view.isHidden = true; continue }
            // Whole points, so markers don't shimmer between pixels while moving.
            let center = CGPoint(x: projected.point.x + view.centerOffset.x, y: projected.point.y + view.centerOffset.y)
            let scale = window?.screen.scale ?? 3
            view.center = CGPoint(x: (center.x * scale).rounded() / scale, y: (center.y * scale).rounded() / scale)
            let visible = bounds.insetBy(dx: -80, dy: -80).contains(view.center)
            let frame = view.frame.insetBy(dx: 6, dy: 3)
            let selected = area.id == selectedAreaID
            let collides = !selected && placed.contains { $0.intersects(frame) }
            view.isHidden = !visible || collides
            if !view.isHidden { placed.append(frame) }
            view.layer.zPosition = (selected ? 20_000 : 10_000) - CGFloat(projected.depth)
        }

        if let userLocation {
            let mapPoint = MKMapPoint(userLocation)
            if let projected = project(scenePoint(mapPoint, height: 2), using: matrix) {
                userDot.center = projected.point
                userDot.isHidden = false
            } else {
                userDot.isHidden = true
            }
            userDot.layer.zPosition = 5_000
        } else {
            userDot.isHidden = true
        }
    }

    // MARK: Your location

    private func startLocationIfAllowed() {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: locationManager.startUpdatingLocation()
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if window != nil { startLocationIfAllowed() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        userLocation = location.coordinate
        updateOverlay()
    }
}

/// Lets touches through to the 3D view except on the markers.
private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// The blue "you are here" dot, matching the flat map's.
private final class UserDotView: UIView {
    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        backgroundColor = .systemBlue
        layer.cornerRadius = 9
        layer.borderWidth = 3
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A view backed by a Metal layer that the 3D scene is drawn into.
final class MetalLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    // swiftlint:disable:next force_cast
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}
