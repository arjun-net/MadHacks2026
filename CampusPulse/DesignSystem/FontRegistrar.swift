import CoreText
import Foundation
import os
import UIKit

enum FontRegistrar {
    private static let log = Logger(subsystem: "CampusPulse", category: "Fonts")

    /// Registers every bundled .ttf/.otf once. Call before any view renders.
    /// Synchronized groups flatten resources into the bundle root, hence `subdirectory: nil`.
    static func registerAll() {
        let urls = ["ttf", "otf"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                log.error("Font registration failed for \(url.lastPathComponent): \(String(describing: error?.takeRetainedValue()))")
            }
        }
        #if DEBUG
        for family in ["Big Shoulders Display", "Atkinson Hyperlegible"] {
            log.debug("\(family): \(UIFont.fontNames(forFamilyName: family))")
        }
        #endif
    }

    /// Navigation titles: the signage face for large titles, Atkinson for inline ones.
    static func styleNavigationBars() {
        let ink = UIColor(Theme.Colors.ink)
        let appearance = UINavigationBar.appearance()
        if let large = UIFont(name: FontName.display, size: 40) {
            appearance.largeTitleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large),
                .foregroundColor: ink,
                .kern: 0.4,
            ]
        }
        if let inline = UIFont(name: FontName.textBold, size: 16) {
            appearance.titleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline),
                .foregroundColor: ink,
            ]
        }
    }
}
