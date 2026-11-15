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

/// Square newsprint tag for a campus building: level dot, category glyph and short name in
/// tracked caps. Selected tags invert (ink fill, paper text) and get a hard offset shadow.
final class AreaAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "AreaAnnotationView"

    private let plate = UIView()
    private let dot = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private let stack = UIStackView()

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

        plate.layer.cornerRadius = Theme.Radius.sm
        plate.layer.cornerCurve = .continuous
        plate.layer.borderWidth = Theme.Stroke.hairline
        plate.layer.shadowRadius = 0
        plate.layer.shadowOffset = CGSize(width: 3, height: 3)
        addSubview(plate)

        dot.layer.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])

        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.addArrangedSubview(dot)
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        plate.addSubview(stack)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: AreaAnnotationView, _: UITraitCollection) in
            view.applyColors()
        }
    }

    func configure(area: CampusArea, level: ActivityLevel?, highlighted: Bool) {
        self.area = area
        self.level = level
        isHighlightedArea = highlighted

        icon.image = UIImage(
            systemName: area.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        )
        applyColors()

        displayPriority = highlighted
            ? .required
            : MKFeatureDisplayPriority(rawValue: 600 + Float(area.popularity) * 350)
        zPriority = highlighted ? .max : MKAnnotationViewZPriority(rawValue: Float(area.popularity) * 100)

        let fitting = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        frame.size = CGSize(width: ceil(fitting.width) + 18, height: 26)
        setNeedsLayout()

        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
            self.transform = highlighted ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
        }
    }

    /// Resolves every color for the current appearance (layer colors don't adapt on their own).
    private func applyColors() {
        guard let area else { return }
        let traits = traitCollection
        let ink = UIColor(Theme.Colors.ink).resolvedColor(with: traits)
        let paper = UIColor(Theme.Colors.paper).resolvedColor(with: traits)
        let secondary = UIColor(Theme.Colors.textSecondary).resolvedColor(with: traits)
        let highlighted = isHighlightedArea

        label.attributedText = NSAttributedString(string: area.shortName.uppercased(), attributes: [
            .font: UIFont(name: FontName.sansHeavy, size: 10) ?? .systemFont(ofSize: 10, weight: .heavy),
            .foregroundColor: highlighted ? paper : ink,
            .kern: 1.2,
        ])
        icon.tintColor = highlighted ? paper.withAlphaComponent(0.8) : secondary
        dot.backgroundColor = level.map { UIColor($0.color).resolvedColor(with: traits) } ?? secondary.withAlphaComponent(0.5)
        dot.layer.borderWidth = 0.5
        dot.layer.borderColor = ink.withAlphaComponent(0.35).cgColor

        // Unselected labels let the map and heat show through; the selected one stays solid.
        plate.backgroundColor = highlighted ? ink : paper.withAlphaComponent(0.4)
        plate.layer.borderColor = highlighted ? ink.cgColor : ink.withAlphaComponent(0.2).cgColor
        plate.layer.shadowColor = UIColor(Theme.Colors.hardShadow).resolvedColor(with: traits).cgColor
        plate.layer.shadowOpacity = highlighted ? 1 : 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        plate.frame = bounds
        plate.layer.shadowPath = UIBezierPath(roundedRect: plate.bounds, cornerRadius: Theme.Radius.sm).cgPath
        let fitting = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        stack.frame = CGRect(
            x: (bounds.width - fitting.width) / 2,
            y: (bounds.height - fitting.height) / 2,
            width: fitting.width,
            height: fitting.height
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        transform = .identity
    }
}
