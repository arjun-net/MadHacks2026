import QuartzCore
import UIKit

/// Drives smooth transitions between heat grids (cross-fading density as data updates)
/// and fades the whole layer in and out when it's toggled.
@MainActor
final class HeatmapAnimator: NSObject {
    /// The canvas's heat layer; the image stretches over the campus heat bounds.
    private weak var layer: CALayer?
    private var displayLink: CADisplayLink?

    private var fromGrid: HeatmapGrid?
    private var toGrid: HeatmapGrid?
    private(set) var currentGrid: HeatmapGrid?
    private var transitionStart: CFTimeInterval = 0
    private let transitionDuration: CFTimeInterval = 1.2

    private var currentAlpha: CGFloat = 1
    private var targetAlpha: CGFloat = 1
    /// Which heat ramp to color with; follows the map's appearance.
    private var style: UIUserInterfaceStyle = .light

    func attach(_ layer: CALayer) {
        self.layer = layer
        show(currentGrid?.makeImage(style: style))
        setOpacity(currentAlpha)
    }

    private func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    private func setOpacity(_ alpha: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = Float(alpha)
        CATransaction.commit()
    }

    /// Re-colors the current heat field when the appearance changes.
    func setStyle(_ newStyle: UIUserInterfaceStyle) {
        let resolved: UIUserInterfaceStyle = newStyle == .dark ? .dark : .light
        guard resolved != style else { return }
        style = resolved
        show(currentGrid?.makeImage(style: style))
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

        if let from = fromGrid, let to = toGrid {
            let progress = min(1, (CACurrentMediaTime() - transitionStart) / transitionDuration)
            let eased = progress < 0.5
                ? 4 * progress * progress * progress
                : 1 - pow(-2 * progress + 2, 3) / 2
            let grid = from.blended(with: to, fraction: Float(eased))
            currentGrid = grid
            // Cheaper frames mid-transition; full detail once it settles.
            show(grid.makeImage(scale: progress >= 1 ? 2 : 1, style: style))
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
            setOpacity(currentAlpha)
            needsMoreFrames = needsMoreFrames || currentAlpha != targetAlpha
        }

        if !needsMoreFrames { stop() }
    }
}
