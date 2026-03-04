import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case transcript = "Transcript"
    case questions = "Questions"
    case settings = "Settings"
    case activity = "Activity"

    var id: String { rawValue }
}

struct SidebarView: View {
    @Binding var selection: SidebarSection

    var body: some View {
        List(SidebarSection.allCases, selection: $selection) { section in
            Text(section.rawValue)
                .font(.headline)
                .tag(section)
        }
        .listStyle(.sidebar)
    }
}
