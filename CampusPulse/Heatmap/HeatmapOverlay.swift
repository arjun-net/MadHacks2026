import MapKit
import QuartzCore

/// Map overlay spanning the campus heatmap bounds.
final class HeatmapOverlay: NSObject, MKOverlay {
    let boundingMapRect: MKMapRect

    init(bounds: MKMapRect) {
        self.boundingMapRect = bounds
    }

    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }
}

/// Draws a pre-rendered heat image stretched over the overlay. MapKit calls `draw` on
/// background threads, so the image is guarded by a lock.
final class HeatmapOverlayRenderer: MKOverlayRenderer {
    private let lock = NSLock()
    private var _image: CGImage?

    var image: CGImage? {
        get { lock.withLock { _image } }
        set { lock.withLock { _image = newValue } }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let image else { return }
        let rect = self.rect(for: overlay.boundingMapRect)
        context.saveGState()
        context.interpolationQuality = .high
        // Map coordinates grow downward; flip so image row 0 lands at the top (north).
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

/// Drives smooth transitions between heat grids (cross-fading density as data updates)
/// and fades the whole layer in and out when it's toggled.
@MainActor
final class HeatmapAnimator: NSObject {
    private weak var renderer: HeatmapOverlayRenderer?
    private var displayLink: CADisplayLink?

    private var fromGrid: HeatmapGrid?
    private var toGrid: HeatmapGrid?
    private(set) var currentGrid: HeatmapGrid?
    private var transitionStart: CFTimeInterval = 0
    private let transitionDuration: CFTimeInterval = 1.2

    private var currentAlpha: CGFloat = 1
    private var targetAlpha: CGFloat = 1

    func attach(_ renderer: HeatmapOverlayRenderer) {
        self.renderer = renderer
        renderer.alpha = currentAlpha
        renderer.image = currentGrid?.makeImage()
        renderer.setNeedsDisplay()
    }

    func reset() {
        stop()
        fromGrid = nil
        toGrid = nil
        currentGrid = nil
    }

    func transition(to grid: HeatmapGrid) {
        if let currentGrid, currentGrid.width == grid.width, currentGrid.height == grid.height {
            fromGrid = currentGrid
        } else {
            fromGrid = .empty(width: grid.width, height: grid.height)
        }
        toGrid = grid
        transitionStart = CACurrentMediaTime()
        startIfNeeded()
    }

    func setVisible(_ visible: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard target != targetAlpha else { return }
        targetAlpha = target
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        var needsMoreFrames = false
        var needsRedraw = false

        if let from = fromGrid, let to = toGrid {
            let progress = min(1, (CACurrentMediaTime() - transitionStart) / transitionDuration)
            let eased = progress < 0.5
                ? 4 * progress * progress * progress
                : 1 - pow(-2 * progress + 2, 3) / 2
            let grid = from.blended(with: to, fraction: Float(eased))
            currentGrid = grid
            // Cheaper frames mid-transition; full detail once it settles.
            renderer?.image = grid.makeImage(scale: progress >= 1 ? 2 : 1)
            needsRedraw = true
            if progress >= 1 {
                fromGrid = nil
                toGrid = nil
            } else {
                needsMoreFrames = true
            }
        }

        if currentAlpha != targetAlpha {
            let delta = targetAlpha - currentAlpha
            currentAlpha = abs(delta) < 0.02 ? targetAlpha : currentAlpha + delta * 0.2
            renderer?.alpha = currentAlpha
            needsRedraw = true
            needsMoreFrames = needsMoreFrames || currentAlpha != targetAlpha
        }

        if needsRedraw { renderer?.setNeedsDisplay() }
        if !needsMoreFrames { stop() }
    }
}
