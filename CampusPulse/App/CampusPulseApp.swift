import SwiftUI

@main
struct CampusPulseApp: App {
    @State private var container = AppContainer.live()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .preferredColorScheme(.dark)
                .tint(Theme.Colors.accent)
        }
    }
}
