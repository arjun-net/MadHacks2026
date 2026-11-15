import QuartzCore
import UIKit

/// Shows heat grids on the canvas's heat layer: cross-fades to each new grid as data updates,
/// and fades the layer in and out when it's toggled.
///
/// The image is colored on a background thread and the fades run on the GPU (Core Animation),
/// so an update never costs the main thread more than swapping one image. Blending grids and
/// coloring them on the main thread every frame used to stall zooming and taps for over a
/// second on each update.
@MainActor
final class HeatmapAnimator: NSObject {
    /// The canvas's heat layer; the image stretches over the campus heat bounds.
    private weak var layer: CALayer?

    private(set) var currentGrid: HeatmapGrid?
    private let transitionDuration: CFTimeInterval = 1.2
    private let visibilityDuration: CFTimeInterval = 0.25

    private var isVisible = true
    /// Which heat ramp to color with; follows the map's appearance.
    private var style: UIUserInterfaceStyle = .light
    /// Bumped per image request, so a slow, older image never replaces a newer one.
    private var generation = 0

    func attach(_ layer: CALayer) {
        self.layer = layer
        layer.opacity = isVisible ? 1 : 0
        if let currentGrid { render(currentGrid, fade: false) }
    }

    /// Re-colors the current heat field when the appearance changes.
    func setStyle(_ newStyle: UIUserInterfaceStyle) {
        let resolved: UIUserInterfaceStyle = newStyle == .dark ? .dark : .light
        guard resolved != style else { return }
        style = resolved
        if let currentGrid { render(currentGrid, fade: false) }
    }

    func reset() {
        generation += 1
        currentGrid = nil
        layer?.removeAllAnimations()
        layer?.contents = nil
    }

    func transition(to grid: HeatmapGrid) {
        currentGrid = grid
        render(grid, fade: true)
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible, let layer else {
            isVisible = visible
            return
        }
        isVisible = visible
        let from = layer.presentation()?.opacity ?? layer.opacity
        let to: Float = visible ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = visibilityDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = to
        layer.add(fade, forKey: "visibility")
    }

    /// Colors `grid` off the main thread, then shows it (cross-fading from the old image).
    private func render(_ grid: HeatmapGrid, fade: Bool) {
        generation += 1
        let requested = generation
        let style = style
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { grid.makeImage(scale: 2, style: style) }.value
            guard let self, requested == self.generation, let layer = self.layer else { return }
            CATransaction.begin()
            if fade, layer.contents != nil {
                let crossfade = CATransition()
                crossfade.type = .fade
                crossfade.duration = self.transitionDuration
                crossfade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(crossfade, forKey: "contents")
            } else {
                CATransaction.setDisableActions(true)
            }
            layer.contents = image
            CATransaction.commit()
        }
    }
}
