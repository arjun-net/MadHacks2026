import SwiftUI

/// A section header over its content on the area detail screen.
struct DetailSection<Content: View>: View {
    let title: String
    let trailing: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, trailing: trailing)
            content
        }
    }
}
