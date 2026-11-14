import MapKit
import SwiftUI

/// Small, static slice of the campus basemap centered on one area, with its heat glow.
/// Tapping it (via the enclosing button) opens the full map.
struct MapPreviewCard: View {
    let campus: Campus
    let activity: AreaActivity
    /// Meters of map shown across the card's width.
    var spanMeters: Double = 520

    private var basemap: Basemap? { Basemap.forCampus(campus) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            mapLayer
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 8) {
                Image(systemName: "map.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Show on map")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Gradients.glassStroke, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }

    private var mapLayer: some View {
        Canvas { context, size in
            let center = MKMapPoint(activity.area.coordinate.clCoordinate)
            let pointsPerMeter = MKMapPointsPerMeterAtLatitude(activity.area.coordinate.latitude)
            let scale = size.width / (spanMeters * pointsPerMeter)
            let visible = MKMapRect(
                x: center.x - size.width / 2 / scale,
                y: center.y - size.height / 2 / scale,
                width: size.width / scale,
                height: size.height / scale
            )
            // Map points → view points.
            let transform = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -center.x, y: -center.y)

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(BasemapRenderer.Palette.land)))

            if let basemap {
                func path(_ features: [Basemap.Feature]) -> Path {
                    var combined = Path()
                    for feature in features where feature.bounds.intersects(visible) {
                        combined.addPath(Path(feature.path), transform: transform)
                    }
                    return combined
                }
                let fill = FillStyle(eoFill: true)
                context.fill(path(basemap.green), with: .color(Color(BasemapRenderer.Palette.green)), style: fill)
                context.fill(path(basemap.water), with: .color(Color(BasemapRenderer.Palette.water)), style: fill)
                context.fill(path(basemap.buildings), with: .color(Color(BasemapRenderer.Palette.building)), style: fill)

                let roads: [(Basemap.RoadClass, UIColor, Double)] = [
                    (.path, BasemapRenderer.Palette.path, 2),
                    (.minor, BasemapRenderer.Palette.minor, 8),
                    (.major, BasemapRenderer.Palette.major, 14),
                ]
                for (roadClass, color, meters) in roads {
                    context.stroke(
                        path(basemap.roads[roadClass] ?? []),
                        with: .color(Color(color)),
                        style: StrokeStyle(lineWidth: max(0.8, meters * pointsPerMeter * scale), lineCap: .round, lineJoin: .round)
                    )
                }
            }

            // Heat glow sized to the area's footprint, then a pin at its center.
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            let glowRadius = max(28, activity.area.radiusMeters * 1.3 * pointsPerMeter * scale)
            let color = activity.level.color
            context.fill(
                Path(ellipseIn: CGRect(x: mid.x - glowRadius, y: mid.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(0.75), color.opacity(0.25), color.opacity(0)]),
                    center: mid, startRadius: 0, endRadius: glowRadius
                )
            )
            context.fill(Path(ellipseIn: CGRect(x: mid.x - 7, y: mid.y - 7, width: 14, height: 14)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: mid.x - 4.5, y: mid.y - 4.5, width: 9, height: 9)), with: .color(activity.level.color))
        }
        .allowsHitTesting(false)
    }
}
