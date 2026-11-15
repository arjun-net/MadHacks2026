import MapKit
import SwiftUI
import UIKit

final class AreaAnnotation: NSObject, MKAnnotation {
    let area: CampusArea
    var level: ActivityLevel?

    init(area: CampusArea) {
        self.area = area
    }

    var coordinate: CLLocationCoordinate2D { area.coordinate.clCoordinate }
}

/// Cartographic place label: a round ink marker with the category glyph sits on the building,
/// with the name centered underneath in a paper halo. The selected place turns red and grows.
/// A ring around the marker fills by busyness (one fifth per level), so you can read how busy
/// a place is without the heat layer.
final class AreaAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "AreaAnnotationView"

    private static let markerSize: CGFloat = 22
    private static let selectedMarkerSize: CGFloat = 30
    private static let labelGap: CGFloat = 3
    private static let maxLabelWidth: CGFloat = 112
    /// Space between the marker edge and the middle of the busyness ring.
    private static let ringInset: CGFloat = 3.5
    private static let ringWidth: CGFloat = 2.5

    private let ringTrack = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let marker = UIView()
    private let icon = UIImageView()
    private let label = UILabel()

    private var area: CampusArea?
    private var level: ActivityLevel?
    private var isHighlightedArea = false

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        canShowCallout = false
        collisionMode = .rectangle
        backgroundColor = .clear

        for layer in [ringTrack, ring] {
            layer.fillColor = nil
            layer.lineWidth = Self.ringWidth
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }

        marker.layer.borderWidth = 1.5
        marker.layer.shadowOffset = CGSize(width: 0, height: 1)
        marker.layer.shadowRadius = 2
        addSubview(marker)

        icon.contentMode = .center
        marker.addSubview(icon)

        label.numberOfLines = 2
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        // Soft paper halo keeps the name legible over streets and heat.
        label.layer.shadowOffset = .zero
        label.layer.shadowRadius = 1.6
        label.layer.shadowOpacity = 1
        // A text-shaped shadow is drawn offscreen; cache it so moving markers don't redraw it every frame.
        label.layer.shouldRasterize = true
        addSubview(label)

        isAccessibilityElement = true
        accessibilityTraits = .button

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: AreaAnnotationView, _: UITraitCollection) in
            view.applyColors()
        }
    }

    /// `groupable` false keeps the marker out of group markers (an opened group's places).
    func configure(area: CampusArea, level: ActivityLevel?, highlighted: Bool, groupable: Bool = true) {
        // Data refreshes reconfigure every marker; skip the ones that haven't changed, since a
        // relayout animates and touching the grouping settings makes MapKit regroup the map.
        let groupID = highlighted || !groupable ? nil : ClusterAnnotationView.clusteringIdentifier
        if self.area?.id == area.id, self.level == level, isHighlightedArea == highlighted, clusteringIdentifier == groupID {
            return
        }
        self.area = area
        self.level = level
        isHighlightedArea = highlighted

        icon.image = UIImage(
            systemName: area.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: highlighted ? 13 : 10, weight: .semibold)
        )
        applyColors()

        // Nothing is dropped when markers overlap: they merge into a group marker instead
        // (the selected place stays on its own).
        displayPriority = .required
        clusteringIdentifier = groupID
        zPriority = highlighted ? .max : MKAnnotationViewZPriority(rawValue: Float(area.popularity) * 100)
        accessibilityLabel = [area.name, level?.title].compactMap { $0 }.joined(separator: ", ")

        layoutContent()
    }

    /// Sizes the view around the marker and name, and anchors the marker's center on the building.
    private func layoutContent() {
        let size = isHighlightedArea ? Self.selectedMarkerSize : Self.markerSize
        let margin = Self.ringInset + Self.ringWidth / 2
        let outer = size + margin * 2
        let text = label.sizeThatFits(CGSize(width: Self.maxLabelWidth, height: .greatestFiniteMagnitude))
        let labelSize = CGSize(width: min(ceil(text.width), Self.maxLabelWidth), height: ceil(text.height))
        let width = max(outer, labelSize.width) + 4
        let height = outer + Self.labelGap + labelSize.height
        let markerFrame = CGRect(x: (width - size) / 2, y: margin, width: size, height: size)

        // Starts at 12 o'clock and runs clockwise.
        let radius = size / 2 + Self.ringInset
        let ringPath = UIBezierPath(
            arcCenter: CGPoint(x: markerFrame.midX, y: markerFrame.midY),
            radius: radius, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true
        ).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringTrack.path = ringPath
        ring.path = ringPath
        CATransaction.commit()
        ring.strokeEnd = level.map { CGFloat($0.rawValue + 1) / CGFloat(ActivityLevel.allCases.count) } ?? 0
        ringTrack.isHidden = level == nil

        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0) {
            self.frame.size = CGSize(width: width, height: height)
            self.marker.frame = markerFrame
            self.marker.layer.cornerRadius = size / 2
            self.marker.layer.shadowPath = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).cgPath
            self.icon.frame = self.marker.bounds
            self.label.frame = CGRect(x: (width - labelSize.width) / 2, y: outer + Self.labelGap, width: labelSize.width, height: labelSize.height)
        }
        // MapKit centers the view on the coordinate; shift so the marker's center sits there instead.
        centerOffset = CGPoint(x: 0, y: height / 2 - markerFrame.midY)
    }

    /// Resolves every color for the current appearance (layer colors don't adapt on their own).
    private func applyColors() {
        guard let area else { return }
        let traits = traitCollection
        let ink = UIColor(Theme.Colors.ink).resolvedColor(with: traits)
        let paper = UIColor(Theme.Colors.paper).resolvedColor(with: traits)
        let accentFill = UIColor(Theme.Colors.accentFill).resolvedColor(with: traits)
        let onAccent = UIColor(Theme.Colors.onAccent).resolvedColor(with: traits)
        let highlighted = isHighlightedArea

        marker.backgroundColor = highlighted ? accentFill : ink
        marker.layer.borderColor = paper.cgColor
        marker.layer.shadowColor = UIColor(Theme.Colors.softShadow).resolvedColor(with: traits).cgColor
        marker.layer.shadowOpacity = 1
        icon.tintColor = highlighted ? onAccent : paper

        // Level colors chosen for contrast on paper; the track is a faint full circle behind.
        ringTrack.strokeColor = paper.withAlphaComponent(0.85).cgColor
        ring.strokeColor = UIColor(level?.textColor ?? Theme.Colors.textTertiary).resolvedColor(with: traits).cgColor

        let font = UIFont(name: highlighted ? FontName.sansBold : FontName.sansSemi, size: highlighted ? 12 : 11)
            ?? .systemFont(ofSize: 11, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineHeightMultiple = 0.92
        label.attributedText = NSAttributedString(string: area.shortName, attributes: [
            .font: UIFontMetrics(forTextStyle: .caption1).scaledFont(for: font, maximumPointSize: 15),
            .foregroundColor: ink,
            .paragraphStyle: paragraph,
        ])
        label.layer.shadowColor = paper.cgColor
        label.layer.rasterizationScale = max(traits.displayScale, 2)
    }

    /// Grows the marker in from a dot, for places appearing out of an opened group.
    func popIn(delay: TimeInterval = 0) {
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        UIView.animate(withDuration: 0.5, delay: delay, usingSpringWithDamping: 0.72, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        area = nil
        layer.removeAllAnimations()
        alpha = 1
        transform = .identity
    }
}
