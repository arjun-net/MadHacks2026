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
        // The bundled Libre Franklin statics report their family as "Libre Franklin Thin".
        for family in ["Playfair Display", "Libre Franklin Thin"] {
            log.debug("\(family): \(UIFont.fontNames(forFamilyName: family))")
        }
        #endif
    }
}
