import MapKit
import UIKit

/// A group of places too close together to show one by one at this zoom: a stack of two
/// ink discs with the count, the busiest member's ring around it, and the best-known name
/// underneath ("Memorial Union +3"). Tapping it zooms in so the group splits apart.
final class ClusterAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "ClusterAnnotationView"
    static let clusteringIdentifier = "campus-area"

    private static let markerSize: CGFloat = 32
    /// The second disc peeking out behind, so it reads as a pile of places.
    private static let stackOffset: CGFloat = 4
    private static let labelGap: CGFloat = 3
    private static let maxLabelWidth: CGFloat = 124
    private static let ringInset: CGFloat = 3.5
    private static let ringWidth: CGFloat = 3

    private let ringTrack = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let backDisc = UIView()
    private let marker = UIView()
    private let countLabel = UILabel()
    private let label = UILabel()

    /// Most popular first.
    private(set) var members: [CampusArea] = []
    private var level: ActivityLevel?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        canShowCallout = false
        collisionMode = .circle
        displayPriority = .required
        zPriority = .defaultSelected
        backgroundColor = .clear

        for disc in [backDisc, marker] {
            disc.layer.borderWidth = 1.5
            disc.layer.shadowOffset = CGSize(width: 0, height: 1)
            disc.layer.shadowRadius = 2
            addSubview(disc)
        }
        for layer in [ringTrack, ring] {
            layer.fillColor = nil
            layer.lineWidth = Self.ringWidth
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }

        countLabel.textAlignment = .center
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = 0.7
        marker.addSubview(countLabel)

        label.numberOfLines = 2
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.layer.shadowOffset = .zero
        label.layer.shadowRadius = 1.6
        label.layer.shadowOpacity = 1
        label.layer.shouldRasterize = true
        addSubview(label)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Zooms in to show these places"

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ClusterAnnotationView, _: UITraitCollection) in
            view.applyColors()
        }
    }

    /// `levels` looks up each member's current busyness.
    func configure(members: [CampusArea], levels: (String) -> ActivityLevel?) {
        self.members = members.sorted { $0.popularity > $1.popularity }
        level = self.members.compactMap { levels($0.id) }.max()
        applyColors()
        accessibilityLabel = "\(members.count) places: " + self.members.map(\.shortName).joined(separator: ", ")
        layoutContent()
    }

    private func layoutContent() {
        let size = Self.markerSize
        let margin = Self.ringInset + Self.ringWidth / 2
        let outer = size + margin * 2 + Self.stackOffset
        let text = label.sizeThatFits(CGSize(width: Self.maxLabelWidth, height: .greatestFiniteMagnitude))
        let labelSize = CGSize(width: min(ceil(text.width), Self.maxLabelWidth), height: ceil(text.height))
        let width = max(outer, labelSize.width) + 4
        let height = outer + Self.labelGap + labelSize.height
        let markerFrame = CGRect(x: (width - size) / 2 - Self.stackOffset / 2, y: margin + Self.stackOffset, width: size, height: size)

        frame.size = CGSize(width: width, height: height)
        backDisc.frame = markerFrame.offsetBy(dx: Self.stackOffset, dy: -Self.stackOffset)
        marker.frame = markerFrame
        for disc in [backDisc, marker] {
            disc.layer.cornerRadius = size / 2
            disc.layer.shadowPath = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).cgPath
        }
        countLabel.frame = marker.bounds.insetBy(dx: 4, dy: 0)
        label.frame = CGRect(x: (width - labelSize.width) / 2, y: outer + Self.labelGap, width: labelSize.width, height: labelSize.height)

        let ringPath = UIBezierPath(
            arcCenter: CGPoint(x: markerFrame.midX, y: markerFrame.midY),
            radius: size / 2 + Self.ringInset, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true
        ).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringTrack.path = ringPath
        ring.path = ringPath
        ring.strokeEnd = level.map { CGFloat($0.rawValue + 1) / CGFloat(ActivityLevel.allCases.count) } ?? 0
        ringTrack.isHidden = level == nil
        CATransaction.commit()

        // Anchor the front disc's center on the group's coordinate.
        centerOffset = CGPoint(x: width / 2 - markerFrame.midX, y: height / 2 - markerFrame.midY)
    }

    private func applyColors() {
        let traits = traitCollection
        let ink = UIColor(Theme.Colors.ink).resolvedColor(with: traits)
        let paper = UIColor(Theme.Colors.paper).resolvedColor(with: traits)
        let shadow = UIColor(Theme.Colors.softShadow).resolvedColor(with: traits).cgColor

        marker.backgroundColor = ink
        backDisc.backgroundColor = ink.withAlphaComponent(0.55)
        for disc in [backDisc, marker] {
            disc.layer.borderColor = paper.cgColor
            disc.layer.shadowColor = shadow
            disc.layer.shadowOpacity = 1
        }
        ringTrack.strokeColor = paper.withAlphaComponent(0.85).cgColor
        ring.strokeColor = UIColor(level?.textColor ?? Theme.Colors.textTertiary).resolvedColor(with: traits).cgColor

        let countFont = UIFont(name: FontName.sansBold, size: 14) ?? .systemFont(ofSize: 14, weight: .bold)
        countLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: countFont, maximumPointSize: 17)
        countLabel.textColor = paper
        countLabel.text = "\(members.count)"

        let font = UIFont(name: FontName.sansSemi, size: 11) ?? .systemFont(ofSize: 11, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineHeightMultiple = 0.92
        let name = members.first.map { members.count > 1 ? "\($0.shortName) +\(members.count - 1)" : $0.shortName } ?? ""
        label.attributedText = NSAttributedString(string: name, attributes: [
            .font: UIFontMetrics(forTextStyle: .caption1).scaledFont(for: font, maximumPointSize: 15),
            .foregroundColor: ink,
            .paragraphStyle: paragraph,
        ])
        label.layer.shadowColor = paper.cgColor
        label.layer.rasterizationScale = max(traits.displayScale, 2)
    }
}
