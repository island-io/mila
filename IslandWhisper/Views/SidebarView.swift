import SwiftUI

enum SidebarSelection: Hashable {
    case home
    case queue
    case category(HistoryCategory)
    case recording(Recording.ID)
}

struct SidebarView: View {
    @Binding var selection: SidebarSelection?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    Label("Home", systemImage: "house")
                        .tag(SidebarSelection.home)
                    Label("Queue", systemImage: "list.bullet.rectangle")
                        .tag(SidebarSelection.queue)
                }

                Section("History") {
                    ForEach(HistoryCategory.allCases) { cat in
                        Label(cat.displayName, systemImage: cat.sfSymbol)
                            .tag(SidebarSelection.category(cat))
                    }
                }
            }
            .listStyle(.sidebar)

            Spacer(minLength: 0)
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    } else {
        return String(format: "%d:%02d", m, s)
    }
}
