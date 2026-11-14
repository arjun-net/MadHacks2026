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

/// Frosted pill label for a campus building: activity dot, category glyph and short name.
final class AreaAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "AreaAnnotationView"

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let dot = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private let stack = UIStackView()

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

        blur.clipsToBounds = true
        blur.layer.cornerCurve = .continuous
        blur.layer.borderWidth = 1
        addSubview(blur)

        dot.layer.cornerRadius = 3.5
        dot.layer.shadowOpacity = 0.9
        dot.layer.shadowRadius = 4
        dot.layer.shadowOffset = .zero
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])

        icon.contentMode = .scaleAspectFit
        icon.tintColor = UIColor.white.withAlphaComponent(0.75)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.addArrangedSubview(dot)
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        addSubview(stack)
    }

    func configure(area: CampusArea, level: ActivityLevel?, highlighted: Bool) {
        label.text = area.shortName
        icon.image = UIImage(
            systemName: area.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        )

        let color = level.map { UIColor($0.color) } ?? UIColor.white.withAlphaComponent(0.4)
        dot.backgroundColor = color
        dot.layer.shadowColor = color.cgColor
        blur.layer.borderColor = (highlighted ? color : UIColor.white.withAlphaComponent(0.14)).cgColor
        blur.layer.borderWidth = highlighted ? 1.5 : 1

        displayPriority = highlighted
            ? .required
            : MKFeatureDisplayPriority(rawValue: 600 + Float(area.popularity) * 350)
        zPriority = highlighted ? .max : MKAnnotationViewZPriority(rawValue: Float(area.popularity) * 100)

        let fitting = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let size = CGSize(width: ceil(fitting.width) + 20, height: 28)
        frame.size = size
        setNeedsLayout()

        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
            self.transform = highlighted ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        blur.layer.cornerRadius = bounds.height / 2
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
