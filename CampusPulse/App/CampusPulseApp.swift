import SwiftUI

@main
struct CampusPulseApp: App {
    @State private var container = AppContainer.live()

    init() {
        FontRegistrar.registerAll()
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .preferredColorScheme(container.preferences.appearance.colorScheme)
                .tint(Theme.Colors.accent)
        }
    }
}
