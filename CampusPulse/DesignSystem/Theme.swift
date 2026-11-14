import SwiftUI

enum Theme {
    enum Colors {
        static let background = Color(red: 0.027, green: 0.031, blue: 0.051)
        static let elevated = Color(red: 0.067, green: 0.075, blue: 0.11)
        static let surface = Color.white.opacity(0.06)
        static let surfaceStrong = Color.white.opacity(0.10)
        static let stroke = Color.white.opacity(0.10)

        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.64)
        static let textTertiary = Color.white.opacity(0.42)

        static let accent = Color(red: 0.43, green: 0.56, blue: 1.0)
        static let accentSecondary = Color(red: 0.74, green: 0.43, blue: 1.0)
        static let live = Color(red: 0.27, green: 0.96, blue: 0.62)
        static let warning = Color(red: 1.0, green: 0.72, blue: 0.25)
        static let danger = Color(red: 1.0, green: 0.36, blue: 0.40)
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
            colors: [Colors.live, Color(red: 0.2, green: 0.75, blue: 1.0)],
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

extension Font {
    static let cpLargeTitle = Font.system(size: 34, weight: .bold, design: .rounded)
    static let cpTitle = Font.system(size: 22, weight: .bold, design: .rounded)
    static let cpTitle3 = Font.system(size: 19, weight: .semibold, design: .rounded)
    static let cpHeadline = Font.system(size: 16, weight: .semibold, design: .rounded)
    static let cpBody = Font.system(size: 15, weight: .regular)
    static let cpSubheadline = Font.system(size: 14, weight: .medium)
    static let cpCaption = Font.system(size: 12, weight: .medium)
    static let cpMicro = Font.system(size: 10.5, weight: .bold, design: .rounded)
    static let cpMetric = Font.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()
    static let cpMetricSmall = Font.system(size: 20, weight: .bold, design: .rounded).monospacedDigit()
}
