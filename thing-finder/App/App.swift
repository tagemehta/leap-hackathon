// MARK: - App Entry
import SwiftUI

@main
struct ThingFinderApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView(description: "laptop", searchMode: .objectFinder, targetClasses: ["laptop"])
    }
  }
}

struct MainTabView: View {
  var body: some View {
    TabView {
      NavigationStack {
        InputView()
      }
      .tabItem {
        Label("Find", systemImage: "magnifyingglass")
      }

      NavigationStack {
        SettingsView(settings: Settings())
      }
      .tabItem {
        Label("Settings", systemImage: "gear")
      }
    }
  }
}
