import SwiftUI
import UIKit

// MARK: - Palette configuration

/// Night Edition palette options. Change `ThemeConfig.dark` to swap.
enum DarkPalette: String, CaseIterable {
    case nightEdition, darkroom, inkOnSlate
}

enum ThemeConfig {
    static var dark: DarkPalette = .nightEdition
}

/// An sRGB hex value with alpha.
struct Hex {
    let value: UInt32
    var alpha: Double = 1

    init(_ value: UInt32, alpha: Double = 1) {
        self.value = value
        self.alpha = alpha
    }

    var uiColor: UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension UIColor {
    /// Resolves to `light` or the active dark palette's value per trait collection.
    static func adaptive(_ light: Hex, dark: @escaping (DarkPalette) -> Hex) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark(ThemeConfig.dark).uiColor : light.uiColor
        }
    }
}

extension Color {
    /// Adaptive color from light/dark hex values.
    init(light: UInt32, dark: UInt32, darkAlpha: Double = 1, lightAlpha: Double = 1) {
        self.init(uiColor: .adaptive(Hex(light, alpha: lightAlpha), dark: { _ in Hex(dark, alpha: darkAlpha) }))
    }

    /// Adaptive color whose dark value depends on the selected `DarkPalette`.
    init(light: Hex, dark: @escaping (DarkPalette) -> Hex) {
        self.init(uiColor: .adaptive(light, dark: dark))
    }
}

/// Dark values for one token across the three palettes (A · Night Edition, B · Darkroom, C · Ink on Slate).
private func night(_ a: Hex, _ b: Hex, _ c: Hex) -> (DarkPalette) -> Hex {
    { palette in
        switch palette {
        case .nightEdition: a
        case .darkroom: b
        case .inkOnSlate: c
        }
    }
}

private func night(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> (DarkPalette) -> Hex {
    night(Hex(a), Hex(b), Hex(c))
}

// MARK: - Theme

enum Theme {
    enum Colors {
        // Paper
        static let background = Color(light: Hex(0xF6F1E7), dark: night(0x16130F, 0x140A0A, 0x121417))
        static let paper = Color(light: Hex(0xFFFDF8), dark: night(0x1F1B16, 0x1E1010, 0x1B1E22))
        static let elevated = paper
        static let surface = Color(light: Hex(0xF3ECDF), dark: night(0x2A251F, 0x2A1717, 0x252930))
        static let surfaceStrong = Color(light: Hex(0xEFE6D6), dark: night(0x332D26, 0x351D1D, 0x2E333B))
        static let mapScrim = background

        // Ink
        static let ink = Color(light: Hex(0x1F1B16), dark: night(0xF3ECDF, 0xF5E6E3, 0xE9ECEF))
        static let stroke = ink
        static let rule = Color(light: Hex(0xDDD2BE), dark: night(0x3A332B, 0x3F2626, 0x343A42))

        // Lines. Surfaces separate by fill and shadow; outlines stay quiet so screens don't read as a grid of boxes.
        /// Card and panel outlines.
        static let border = Color(light: Hex(0xE4DACA), dark: night(0x2E2822, 0x301C1C, 0x2B2F35))
        /// Edges of interactive controls (chips, switches, segmented pickers, small buttons).
        static let borderStrong = Color(light: Hex(0xC4B7A1), dark: night(0x4A4137, 0x4E3030, 0x464D56))
        /// Section and masthead rules: ink in Day for the newspaper feel, softened in Night.
        static let sectionRule = Color(light: Hex(0x1F1B16), dark: night(0x5A5045, 0x5E3B39, 0x535A64))
        /// Selected chip, segment and tab: ink in Day, press red in Night (a cream block glares on dark).
        static let selectionFill = Color(light: Hex(0x1F1B16), dark: night(0x9B0000, 0xC5050C, 0xA80F14))
        static let onSelection = Color(light: Hex(0xFFFDF8), dark: night(0xFFFDF8, 0xFFFFFF, 0xFFFFFF))

        static let textPrimary = ink
        static let textSecondary = Color(light: Hex(0x5E554A), dark: night(0xBDB2A2, 0xC9AFAB, 0xAEB5BE))
        static let textTertiary = Color(light: Hex(0x6E6357), dark: night(0xA39886, 0xB0928D, 0x949CA6))

        // press red. `accent` is for text and icons; `accentFill` for filled buttons and badges.
        static let accent = Color(light: Hex(0x9B0000), dark: night(0xE0605A, 0xFF6B66, 0xE8605C))
        static let accentFill = Color(light: Hex(0x9B0000), dark: night(0x9B0000, 0xC5050C, 0xA80F14))
        static let onAccent = Color(light: Hex(0xFFFDF8), dark: night(0xFFFDF8, 0xFFFFFF, 0xFFFFFF))
        static let live = accent

        // Status
        static let positive = Color(light: Hex(0x2E6B3F), dark: night(0x6FBF83, 0x7CC48F, 0x6FBF83))
        static let warning = Color(light: Hex(0x8A4B12), dark: night(0xE2A45A, 0xE8AE62, 0xE2A45A))
        static let danger = Color(light: Hex(0xA33A1C), dark: night(0xF08A6B, 0xFF9A80, 0xF08A6B))
        /// Activity-level text colors that hold contrast on paper.
        static let brick = danger
        static let rust = warning
        /// Neutral icon color (kept for existing call sites).
        static let graphite = textSecondary

        // Shadows
        static let softShadow = Color(
            light: Hex(0x503C1E, alpha: 0.10),
            dark: night(Hex(0x000000, alpha: 0.4), Hex(0x000000, alpha: 0.5), Hex(0x000000, alpha: 0.45))
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
        static let sm: CGFloat = 5
        static let md: CGFloat = 5
        static let lg: CGFloat = 5
        static let xl: CGFloat = 7
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let sectionRule: CGFloat = 2
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
// Set like campus wayfinding rather than a newspaper:
// - Big Shoulders Display, a condensed grotesque drawn for Chicago's civic signage, for the
//   campus name, titles, section headings and the big numbers. Only at 18 pt and up; it's a
//   display face.
// - Atkinson Hyperlegible, drawn by the Braille Institute for telling letters apart at a glance,
//   for everything you read: text, rows, labels, buttons.
// Labels are sentence case and untracked; headings do the shouting, in size, not capitals.

enum FontName {
    static let display = "BigShouldersDisplay-Black"
    static let displayHeavy = "BigShouldersDisplay-ExtraBold"
    static let displayBold = "BigShouldersDisplay-Bold"
    static let text = "AtkinsonHyperlegible-Regular"
    static let textBold = "AtkinsonHyperlegible-Bold"
    static let textItalic = "AtkinsonHyperlegible-Italic"
}

extension Font {
    // Display (Big Shoulders Display): a 1.25 step scale, 20 → 42.
    static let cpMasthead = Font.custom(FontName.display, size: 42, relativeTo: .largeTitle)
    static let cpLargeTitle = Font.custom(FontName.display, size: 40, relativeTo: .largeTitle)
    static let cpTitle = Font.custom(FontName.displayHeavy, size: 31, relativeTo: .title)
    static let cpTitle3 = Font.custom(FontName.displayHeavy, size: 24, relativeTo: .title3)
    static let cpSection = Font.custom(FontName.displayHeavy, size: 21, relativeTo: .title3)
    static let cpRank = Font.custom(FontName.display, size: 30, relativeTo: .title2)
    static let cpMetric = Font.custom(FontName.displayHeavy, size: 44, relativeTo: .title).monospacedDigit()
    static let cpMetricSmall = Font.custom(FontName.displayHeavy, size: 30, relativeTo: .title3).monospacedDigit()

    // Text (Atkinson Hyperlegible): regular and bold only, 11 → 16.
    static let cpHeadline = Font.custom(FontName.textBold, size: 16, relativeTo: .headline)
    static let cpRowTitle = Font.custom(FontName.textBold, size: 15, relativeTo: .body)
    static let cpBody = Font.custom(FontName.text, size: 15, relativeTo: .body)
    static let cpSubheadline = Font.custom(FontName.text, size: 14, relativeTo: .subheadline)
    static let cpCaption = Font.custom(FontName.text, size: 12.5, relativeTo: .caption)
    static let cpMicro = Font.custom(FontName.textBold, size: 12, relativeTo: .caption)
    static let cpBadge = Font.custom(FontName.textBold, size: 11, relativeTo: .caption2)
    static let cpTab = Font.custom(FontName.textBold, size: 11, relativeTo: .caption2)
    static let cpButton = Font.custom(FontName.textBold, size: 14, relativeTo: .callout)
}

/// Font + tracking pairs. Use `.typeStyle(.title)` so tracking stays consistent.
enum TypeStyle {
    case masthead, largeTitle, title, title3, section, rank, headline, rowTitle, body, subheadline, caption
    case micro, badge, tab, button, metric, metricSmall

    var font: Font {
        switch self {
        case .masthead: .cpMasthead
        case .largeTitle: .cpLargeTitle
        case .title: .cpTitle
        case .title3: .cpTitle3
        case .section: .cpSection
        case .rank: .cpRank
        case .headline: .cpHeadline
        case .rowTitle: .cpRowTitle
        case .body: .cpBody
        case .subheadline: .cpSubheadline
        case .caption: .cpCaption
        case .micro: .cpMicro
        case .badge: .cpBadge
        case .tab: .cpTab
        case .button: .cpButton
        case .metric: .cpMetric
        case .metricSmall: .cpMetricSmall
        }
    }

    /// The condensed display face opens up a touch as it gets big; text stays as drawn.
    var tracking: CGFloat {
        switch self {
        case .masthead, .largeTitle: 0.4
        case .metric: 0.3
        case .title, .title3, .section, .rank, .metricSmall: 0.2
        default: 0
        }
    }

    /// Nothing is forced into capitals any more.
    var isUppercase: Bool { false }

    var lineSpacing: CGFloat {
        switch self {
        case .body: 5
        case .subheadline: 4
        case .caption: 3
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
            .textCase(style.isUppercase ? .uppercase : nil)
    }
}
