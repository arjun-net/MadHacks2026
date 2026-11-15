import MapKit
import SwiftUI

/// MKMapView bridge. MapKit handles gestures, the camera and the markers; the map itself and
/// the heat layer are drawn by `MapCanvasView`, which SwiftUI's `Map` couldn't host.
struct CampusMapView: UIViewRepresentable {
    let campus: Campus
    let snapshot: CampusSnapshot?
    let isHeatmapVisible: Bool
    let selectedAreaID: String?
    let recenterToken: Int
    /// Space covered by floating chrome, so recentering frames campus in the visible area.
    /// Room for the masthead above and the legend and tab bar below.
    var contentInsets = UIEdgeInsets(top: 190, left: 14, bottom: 140, right: 14)
    var onSelectArea: (String?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = LayoutAwareMapView()
        mapView.onFirstLayout = { [weak coordinator = context.coordinator, weak mapView] in
            guard let coordinator, let mapView else { return }
            coordinator.recenter(mapView, animated: false)
        }
        mapView.delegate = context.coordinator

        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        mapView.preferredConfiguration = configuration

        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.register(AreaAnnotationView.self, forAnnotationViewWithReuseIdentifier: AreaAnnotationView.reuseIdentifier)

        context.coordinator.configure(mapView, for: campus)
        context.coordinator.animator.setStyle(mapView.traitCollection.userInterfaceStyle)
        // Re-color the heat overlay and labels live when the appearance changes.
        mapView.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak coordinator = context.coordinator] (view: MKMapView, _: UITraitCollection) in
            coordinator?.animator.setStyle(view.traitCollection.userInterfaceStyle)
            coordinator?.setBasemapStyle(view.traitCollection.userInterfaceStyle, scale: view.traitCollection.displayScale)
            coordinator?.refreshAnnotationStyles(in: view)
        }
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if coordinator.campusID != campus.id {
            coordinator.configure(mapView, for: campus)
        }
        if let snapshot, snapshot.generatedAt != coordinator.snapshotDate, snapshot.campusID == campus.id {
            coordinator.apply(snapshot, to: mapView)
        }
        coordinator.animator.setVisible(isHeatmapVisible)

        if coordinator.selectedAreaID != selectedAreaID {
            coordinator.selectedAreaID = selectedAreaID
            coordinator.refreshAnnotationStyles(in: mapView)
            if let id = selectedAreaID, let area = campus.area(withID: id) {
                coordinator.focus(on: area, in: mapView)
            }
        }
        if coordinator.recenterToken != recenterToken {
            coordinator.recenterToken = recenterToken
            coordinator.recenter(mapView, animated: true)
        }
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.animator.reset()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: CampusMapView
        let animator = HeatmapAnimator()

        var campusID: String?
        var snapshotDate: Date?
        var selectedAreaID: String?
        var recenterToken: Int

        private var heatBounds: MKMapRect?
        private var basemapTiles: BasemapTiles?
        private var canvas: MapCanvasView?
        private var prefetchJobs: [(area: MKMapRect, zooms: ClosedRange<Int>)] = []
        private var annotations: [String: AreaAnnotation] = [:]
        private var gridTask: Task<Void, Never>?

        init(parent: CampusMapView) {
            self.parent = parent
            self.recenterToken = parent.recenterToken
        }

        func configure(_ mapView: MKMapView, for campus: Campus) {
            campusID = campus.id
            snapshotDate = nil
            selectedAreaID = nil
            gridTask?.cancel()
            animator.reset()

            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(mapView.annotations.filter { $0 is AreaAnnotation })

            let campusRect = campus.boundaryRect
            let focusArea = campus.focusRect
            let boundary = campusRect.union(focusArea).insetBy(dx: -focusArea.width, dy: -focusArea.height * 1.5)
            // The camera center stays inside `boundary`, so zoomed out the screen can show well beyond it.
            let reachable = boundary.insetBy(dx: -boundary.width * 0.5, dy: -boundary.height * 0.5)

            basemapTiles = Basemap.forCampus(campus).map {
                BasemapTiles(basemap: $0, campusID: campus.id, style: mapView.traitCollection.userInterfaceStyle)
            }
            heatBounds = campus.heatmapBounds
            canvas?.removeFromSuperview()
            let canvas = MapCanvasView(mapView: mapView, tiles: basemapTiles, overviewRect: reachable, heatBounds: campus.heatmapBounds)
            mapView.installCanvas(canvas)
            self.canvas = canvas
            animator.attach(canvas.heatLayer)

            annotations = Dictionary(uniqueKeysWithValues: campus.areas.map { ($0.id, AreaAnnotation(area: $0)) })
            mapView.addAnnotations(Array(annotations.values))

            // Keep the camera on campus: limited panning and zoom-out.
            mapView.setCameraBoundary(MKMapView.CameraBoundary(mapRect: boundary), animated: false)
            // Draw ahead of time what the camera can reach; zoomed in, people stay around
            // campus. Wider areas at coarse zooms keep the count near 1,000 tiles.
            prefetchJobs = [
                (reachable, 12...15),
                (boundary, 16...16),
                (focusArea.insetBy(dx: -focusArea.width * 0.5, dy: -focusArea.height * 0.5), 17...17),
                // Street level around the buildings; closer zooms enlarge these while drawing.
                (focusArea, 18...18),
            ]
            prefetchBasemap(scale: mapView.traitCollection.displayScale)
            mapView.setCameraZoomRange(
                MKMapView.CameraZoomRange(minCenterCoordinateDistance: 250, maxCenterCoordinateDistance: 20_000),
                animated: false
            )
            mapView.region = campus.region
            if mapView.bounds.width > 0 {
                recenter(mapView, animated: false)
            }
        }

        func apply(_ snapshot: CampusSnapshot, to mapView: MKMapView) {
            snapshotDate = snapshot.generatedAt
            for activity in snapshot.areas {
                annotations[activity.id]?.level = activity.level
            }
            refreshAnnotationStyles(in: mapView)

            guard let bounds = heatBounds else { return }
            let cells = snapshot.cells
            gridTask?.cancel()
            gridTask = Task { [weak self] in
                let grid = await Task.detached(priority: .userInitiated) {
                    HeatmapGrid.render(cells: cells, in: bounds)
                }.value
                guard !Task.isCancelled, let self else { return }
                self.animator.transition(to: grid)
            }
        }

        func refreshAnnotationStyles(in mapView: MKMapView) {
            for annotation in annotations.values {
                guard let view = mapView.view(for: annotation) as? AreaAnnotationView else { continue }
                view.configure(area: annotation.area, level: annotation.level, highlighted: annotation.area.id == selectedAreaID)
            }
        }

        func recenter(_ mapView: MKMapView, animated: Bool) {
            mapView.setVisibleMapRect(parent.campus.focusRect, edgePadding: parent.contentInsets, animated: animated)
        }

        func focus(on area: CampusArea, in mapView: MKMapView) {
            let center = MKMapPoint(area.coordinate.clCoordinate)
            let span = MKMapPointsPerMeterAtLatitude(area.coordinate.latitude) * 420
            let rect = MKMapRect(x: center.x - span / 2, y: center.y - span / 2, width: span, height: span)
            var insets = parent.contentInsets
            insets.bottom = max(insets.bottom, 330)
            mapView.setVisibleMapRect(rect, edgePadding: insets, animated: true)
        }

        /// Redraws the basemap in the new appearance.
        func setBasemapStyle(_ style: UIUserInterfaceStyle, scale: CGFloat) {
            canvas?.setStyle(style)
            guard let basemapTiles, basemapTiles.style != (style == .dark ? .dark : .light) else { return }
            basemapTiles.style = style
            prefetchBasemap(scale: scale)
        }

        /// Zoom levels from fully zoomed out (~20 km camera) to a building's block; closer
        /// tiles draw on demand while MapKit shows these scaled up.
        private func prefetchBasemap(scale: CGFloat) {
            guard let basemapTiles, !prefetchJobs.isEmpty else { return }
            basemapTiles.prefetch(prefetchJobs, scale: max(scale, 1))
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            canvas?.cameraWillMove()
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            canvas?.sync()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            canvas?.cameraDidStop()
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? AreaAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: AreaAnnotationView.reuseIdentifier,
                for: annotation
            ) as? AreaAnnotationView
            view?.configure(area: annotation.area, level: annotation.level, highlighted: annotation.area.id == selectedAreaID)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? AreaAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            parent.onSelectArea(annotation.area.id)
        }
    }
}

/// Reports its first real layout so the initial camera can account for the floating chrome,
/// and keeps the canvas sized to the map (MapKit doesn't resize views added inside it).
final class LayoutAwareMapView: MKMapView {
    var onFirstLayout: (() -> Void)?
    weak var canvas: MapCanvasView?

    override func layoutSubviews() {
        super.layoutSubviews()
        if let canvas, let host = canvas.superview, canvas.frame != host.bounds {
            canvas.frame = host.bounds
        }
        guard bounds.width > 0, let callback = onFirstLayout else { return }
        onFirstLayout = nil
        callback()
    }
}
