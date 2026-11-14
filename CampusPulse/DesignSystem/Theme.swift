import SwiftUI

enum Theme {
    enum Colors {
        static let background = Color(red: 0.02, green: 0.02, blue: 0.02)
        static let elevated = Color(red: 0.075, green: 0.075, blue: 0.075)
        static let surface = Color.white.opacity(0.06)
        static let surfaceStrong = Color.white.opacity(0.10)
        static let stroke = Color.white.opacity(0.10)

        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.64)
        static let textTertiary = Color.white.opacity(0.42)

        /// Badger red (#C5050C) family.
        static let badgerRed = Color(red: 0.773, green: 0.020, blue: 0.047)
        static let accent = Color(red: 0.90, green: 0.10, blue: 0.13)
        static let accentSecondary = Color(red: 0.55, green: 0.0, blue: 0.03)
        static let live = Color(red: 1.0, green: 0.23, blue: 0.23)
        static let warning = Color(white: 0.86)
        static let danger = Color(red: 1.0, green: 0.30, blue: 0.30)
        /// Neutral tile color for secondary icons.
        static let graphite = Color(white: 0.30)
    }

    enum Gradients {
        static let accent = LinearGradient(
            colors: [Colors.accent, Colors.accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        static let glassStroke = LinearGradient(
            colors: [.white.opacity(0.26), .white.opacity(0.06), .white.opacity(0.02)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        static let live = LinearGradient(
            colors: [Colors.live, Colors.badgerRed],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
        static let xxl: CGFloat = 40
    }

    enum Radius {
        static let sm: CGFloat = 12
        static let md: CGFloat = 18
        static let lg: CGFloat = 24
        static let xl: CGFloat = 30
    }

    enum Motion {
        static let snappy = Animation.spring(response: 0.38, dampingFraction: 0.82)
        static let smooth = Animation.spring(response: 0.55, dampingFraction: 0.86)
        static let gentle = Animation.easeInOut(duration: 0.35)
    }

    /// Height reserved at the bottom of every screen for the floating tab bar.
    static let tabBarClearance: CGFloat = 76
}

// MARK: - Typography
//
// Editorial, quiet type: New York (serif) for hero display moments, SF Pro for
// everything else. Headlines run tight (negative tracking), labels run wide.
// No rounded faces — they read as generic/toy-like.

extension Font {
    // Display — serif, light-ish weight, set tight.
    static let cpLargeTitle = Font.system(size: 36, weight: .medium, design: .serif)
    static let cpTitle = Font.system(size: 26, weight: .medium, design: .serif)

    // Sans hierarchy.
    static let cpTitle3 = Font.system(size: 19, weight: .semibold)
    static let cpHeadline = Font.system(size: 16, weight: .semibold)
    static let cpBody = Font.system(size: 15, weight: .regular)
    static let cpSubheadline = Font.system(size: 14, weight: .medium)
    static let cpCaption = Font.system(size: 12.5, weight: .regular)
    static let cpMicro = Font.system(size: 10.5, weight: .semibold)

    // Numbers — sans, tabular, slightly heavy so they anchor a card.
    static let cpMetric = Font.system(size: 32, weight: .semibold).monospacedDigit()
    static let cpMetricSmall = Font.system(size: 22, weight: .semibold).monospacedDigit()
}

/// Font + tracking pairs. Use `.typeStyle(.title)` so tracking stays consistent.
enum TypeStyle {
    case largeTitle, title, title3, headline, body, subheadline, caption, micro, metric, metricSmall

    var font: Font {
        switch self {
        case .largeTitle: .cpLargeTitle
        case .title: .cpTitle
        case .title3: .cpTitle3
        case .headline: .cpHeadline
        case .body: .cpBody
        case .subheadline: .cpSubheadline
        case .caption: .cpCaption
        case .micro: .cpMicro
        case .metric: .cpMetric
        case .metricSmall: .cpMetricSmall
        }
    }

    var tracking: CGFloat {
        switch self {
        case .largeTitle: -0.9
        case .title: -0.5
        case .title3: -0.35
        case .headline: -0.25
        case .body: -0.1
        case .subheadline: -0.1
        case .caption: 0
        case .micro: 1.4
        case .metric: -1.0
        case .metricSmall: -0.5
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .body, .subheadline: 3
        case .caption: 2
        default: 0
        }
    }
}

extension View {
    func typeStyle(_ style: TypeStyle) -> some View {
        self
            .font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }
}
