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

/// Map-style place label: a glowing marker in the area's activity color with its category
/// glyph, and a haloed name plus small-caps activity caption beside it (no background box).
/// The marker sits exactly on the area's coordinate.
final class AreaAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "AreaAnnotationView"

    private enum Metrics {
        static let marker: CGFloat = 22
        static let markerHighlighted: CGFloat = 28
        static let ring: CGFloat = 40
        static let gap: CGFloat = 6
        static let backingPadding = UIEdgeInsets(top: 3, left: 7, bottom: 3, right: 8)
    }

    private let ring = CAShapeLayer()
    private let marker = UIView()
    private let glyph = UIImageView()
    private let backing = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let nameLabel = UILabel()
    private let captionLabel = UILabel()

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

        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 1.5
        layer.addSublayer(ring)

        backing.clipsToBounds = true
        backing.layer.cornerCurve = .continuous
        backing.layer.cornerRadius = 9
        backing.layer.borderWidth = 0.5
        backing.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        addSubview(backing)

        marker.layer.borderColor = UIColor.black.withAlphaComponent(0.55).cgColor
        marker.layer.shadowOffset = .zero
        marker.layer.shadowRadius = 7
        marker.layer.shadowOpacity = 0.85
        addSubview(marker)

        glyph.contentMode = .center
        glyph.tintColor = .white
        marker.addSubview(glyph)

        for label in [nameLabel, captionLabel] {
            // Dark halo keeps text legible over bright heat without a background box.
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOffset = .zero
            label.layer.shadowRadius = 2.5
            label.layer.shadowOpacity = 0.95
            addSubview(label)
        }
    }

    func configure(area: CampusArea, level: ActivityLevel?, highlighted: Bool) {
        isHighlightedArea = highlighted
        let color = level.map { UIColor($0.color) } ?? UIColor(white: 0.45, alpha: 1)

        nameLabel.attributedText = NSAttributedString(string: area.shortName, attributes: [
            .font: UIFont.systemFont(ofSize: highlighted ? 13 : 12, weight: .semibold),
            .foregroundColor: UIColor.white,
            .kern: 0.15,
        ])
        captionLabel.attributedText = NSAttributedString(string: (level?.title ?? area.category.title).uppercased(), attributes: [
            .font: UIFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: level == nil ? UIColor.white.withAlphaComponent(0.55) : color,
            .kern: 1.1,
        ])

        glyph.image = UIImage(
            systemName: area.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: highlighted ? 12 : 10, weight: .bold)
        )
        marker.backgroundColor = color
        marker.layer.shadowColor = color.cgColor
        marker.layer.borderWidth = highlighted ? 2 : 1.5
        marker.layer.borderColor = (highlighted ? UIColor.white : UIColor.black.withAlphaComponent(0.55)).cgColor

        ring.strokeColor = color.withAlphaComponent(0.55).cgColor
        ring.isHidden = !highlighted
        backing.isHidden = !highlighted

        displayPriority = highlighted
            ? .required
            : MKFeatureDisplayPriority(rawValue: 600 + Float(area.popularity) * 350)
        zPriority = highlighted ? .max : MKAnnotationViewZPriority(rawValue: Float(area.popularity) * 100)

        layoutContent()

        if highlighted {
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.6
            pulse.toValue = 1
            pulse.duration = 0.45
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(pulse, forKey: "pulse")
        }
    }

    /// Sizes the view and offsets it so the marker's center lands on the coordinate.
    private func layoutContent() {
        let markerSize = isHighlightedArea ? Metrics.markerHighlighted : Metrics.marker
        nameLabel.sizeToFit()
        captionLabel.sizeToFit()
        let textWidth = max(nameLabel.bounds.width, captionLabel.bounds.width)
        let textHeight = nameLabel.bounds.height + captionLabel.bounds.height - 1
        let side = isHighlightedArea ? Metrics.ring : markerSize
        let height = max(side, textHeight + Metrics.backingPadding.top + Metrics.backingPadding.bottom)
        let markerCenterX = side / 2
        let textX = side / 2 + markerSize / 2 + Metrics.gap + (isHighlightedArea ? Metrics.backingPadding.left : 0)
        let width = textX + textWidth + Metrics.backingPadding.right

        frame.size = CGSize(width: ceil(width), height: ceil(height))
        centerOffset = CGPoint(x: frame.width / 2 - markerCenterX, y: 0)

        let midY = frame.height / 2
        marker.frame = CGRect(x: markerCenterX - markerSize / 2, y: midY - markerSize / 2, width: markerSize, height: markerSize)
        marker.layer.cornerRadius = markerSize / 2
        glyph.frame = marker.bounds

        let ringRect = CGRect(x: markerCenterX - Metrics.ring / 2, y: midY - Metrics.ring / 2, width: Metrics.ring, height: Metrics.ring)
        ring.frame = ringRect
        ring.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: ringRect.size).insetBy(dx: 1, dy: 1)).cgPath

        let textTop = midY - textHeight / 2
        nameLabel.frame.origin = CGPoint(x: textX, y: textTop)
        captionLabel.frame.origin = CGPoint(x: textX, y: nameLabel.frame.maxY - 1)

        backing.frame = CGRect(
            x: textX - Metrics.backingPadding.left,
            y: textTop - Metrics.backingPadding.top,
            width: textWidth + Metrics.backingPadding.left + Metrics.backingPadding.right,
            height: textHeight + Metrics.backingPadding.top + Metrics.backingPadding.bottom
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ring.removeAllAnimations()
    }
}
