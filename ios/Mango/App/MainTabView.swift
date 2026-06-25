import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { TodayView().mangoDestinations() }
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
            NavigationStack { LibraryView().mangoDestinations() }
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            NavigationStack { JourneyView().mangoDestinations() }
                .tabItem { Label("Journey", systemImage: "map.fill") }
            NavigationStack { ProfileView().mangoDestinations() }
                .tabItem { Label("Profile", systemImage: "person.fill") }
        }
    }
}

#Preview {
    MainTabView()
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
