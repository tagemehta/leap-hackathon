// MARK: - App Entry
import SwiftUI

@main
struct ThingFinderApp: App {
  var body: some Scene {
    WindowGroup {
      NavigationStack {
        InputView()
      }
    }
  }
}
