import FocusStackCore
import SwiftUI

@main struct FocusStackApp: App {
    @State private var state = AppState()
    var body: some Scene {
        WindowGroup("FocusStack Native") { ContentView(state: state).frame(minWidth: 760,minHeight: 640) }
    }
}
